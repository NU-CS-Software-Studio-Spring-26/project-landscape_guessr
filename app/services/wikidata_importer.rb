require "net/http"
require "uri"
require "json"
require "securerandom"
require "concurrent/atomic/atomic_fixnum"

# Runs SPARQL queries against query.wikidata.org and turns the rows into
# Image / ImageSetItem records. The AI returns a *pattern* (WHERE-clause
# body); this service handles per-type fan-out + random sampling +
# polygon refinement + Wikipedia image enrichment + bulk insert.
#
# == Random sampling
#
# Every fetched query is randomized via:
#
#   ORDER BY SHA512(CONCAT(STR(RAND()), STR(?item)))
#
# inside a subquery, then LIMIT HARD_CAP outside. This works under any
# filter shape — region bbox, country anchor, FILTER, UNION, subclass
# walk — and returns true random items when the result set exceeds the
# cap (vs. WDQS's alphabetical-first-N bias under plain LIMIT).
#
# We previously had two strategies (`exhaustive` LIMIT vs `bd:sample`).
# bd:sample's inner block only accepts a single direct triple, so it
# silently dropped FILTERs and couldn't combine with SERVICE wikibase:box.
# For country/region queries it returned 20-50× fewer items than the
# SHA512 approach. See `build_random_sparql` for the current shape.
#
# == Cache busting
#
# WDQS caches by query text. A per-call `# nonce: <hex>` comment varies
# the text so each fetch returns a fresh random sample — without it,
# RAND() materializes on the first call and gets cached, so retries
# return identical items. Verified empirically.
#
# == Pattern shape detection
#
# `extract_union_types(pattern)` → array of QIDs from `VALUES ?type {...}`
# `extract_single_type(pattern)` → single QID from `wdt:P31[/wdt:P279*] wd:Qxxx`
# `extract_types(pattern)`       → either of the above, or [] if neither
#
# When types are extractable, per-type fan-out parallelizes the work.
# When not extractable (the AI dropped P31 entirely for a selective
# FILTER query), we fall back to a single-query path.
class WikidataImporter
  ENDPOINT   = URI("https://query.wikidata.org/sparql").freeze
  USER_AGENT = WikimediaUserAgent::STRING
  # Preview-phase timeout. WDQS's own hard ceiling is 60s, so 60s here
  # gives the SPARQL the same budget Blazegraph has — past that and
  # we'd just be re-sending a query Blazegraph already killed.
  # SHA512 ORDER BY on big filtered sets (US-buildings, worldwide-rivers)
  # consistently lands in the 30-55s range; tightening below 60s starts
  # to fail those legitimately.
  READ_TIMEOUT = 60

  # Import-phase timeout. Same WDQS 60s server cap applies, but the
  # client-side budget also covers SSL/HTTP overhead + WDQS queue time
  # under load. 120s here keeps us from dying on retry-able tail
  # latency that's not Blazegraph's fault. The user isn't staring at
  # a spinner during import (it runs as a background job behind the
  # show-page poll), so the extra headroom has no UX cost.
  IMPORT_READ_TIMEOUT = 120

  HARD_CAP = 10_000

  # Two attempts per query (1 retry). WDQS timeouts are almost never
  # transient — when a pattern is too expensive once, a retry hits the
  # same shape and times out again. One retry covers genuine network
  # flap; more just multiplies the wasted wall time.
  MAX_RETRIES = 2

  # Non-photo filename patterns lifted from db/seeds.rb. No \b word
  # boundaries — Ruby's \b treats `_` as a word char, so \bMODIS\b
  # fails to match "MODIS_satellite.jpg". Do not re-add \b without
  # testing against real filenames.
  NON_PHOTO_PATTERNS = [
    /ASTER|MODIS|Landsat|LANDSAT|Sentinel|MISR|Messtischblatt/i,
    /_map[._]|location[_\s-]map|relief[_\s-]map|system[_\s-]map/i,
    /topographic|schematic|Harper.?s[_\s-]New/i
  ].freeze

  class Error < StandardError; end
  class TimeoutError < Error; end

  # === Public API ===

  # Returns the total number of items matching the pattern. Per-type
  # fan-out (parallel threads) when types are extractable; single
  # query otherwise.
  #
  # The count is the size of the FILTERED set (pattern + image-or-article
  # block), pre-cap. For umbrella patterns this is a sum of per-type
  # counts and can over-count items that match multiple P31 classes;
  # callers display this as "up to N matching items" for that reason.
  #
  # Returns nil if EVERY per-type query errored — distinct from 0 (all
  # queries ran successfully, no matches). Callers (pipeline) use the
  # distinction to skip wasteful Pro retry / sample fan-out when WDQS
  # is unable to execute the query shape at all.
  def self.count(pattern:, on_progress: nil, region_filter: nil)
    pattern = with_region_bbox(pattern, region_filter)
    types   = extract_types(pattern)

    if types.empty?
      rows = run_query(build_count_sparql(pattern))
      return rows.first&.dig("c", "value").to_i
    end

    results = parallel_per_type(types, on_progress: on_progress) do |qid|
      sparql = build_per_type_sparql(
        pattern: pattern, qid: qid,
        limit: HARD_CAP, count_only: true, with_label: false
      )
      rows = run_query(sparql)
      rows.first&.dig("c", "value").to_i
    end
    return nil if results.all?(&:nil?)
    results.compact.sum
  end

  # Returns up to `limit` rows for the preview thumbnails. Truly random
  # within the filtered set thanks to the SHA512+RAND ORDER BY inside
  # build_per_type_sparql.
  #
  # We oversample at WDQS because the post-WDQS pipeline drops rows:
  # ~30-50% to polygon refine (region queries only) and ~50% to
  # pageimages enrichment (items with only ?article and no ?image
  # whose pageimages lookup returns nothing). Without oversampling the
  # 30-row preview ends up with ~10-15 visible thumbs.
  PREVIEW_OVERSAMPLE = 3

  def self.sample(pattern:, limit: 30, on_progress: nil, region_filter: nil)
    pattern  = with_region_bbox(pattern, region_filter)
    types    = extract_types(pattern)
    target   = limit * PREVIEW_OVERSAMPLE

    rows = if types.empty?
      sparql = build_random_sparql(pattern: pattern, limit: target, with_label: true)
      run_query(sparql)
    else
      per_type_limit = (target.to_f / types.size).ceil + 2
      results = parallel_per_type(types, on_progress: on_progress) do |qid|
        sparql = build_per_type_sparql(
          pattern: pattern, qid: qid,
          limit: per_type_limit, with_label: true
        )
        run_query(sparql)
      end
      results.compact.flatten
    end

    rows = normalize_rows(rows)
    # Polygon refinement (BEFORE pageimages so we don't waste API calls
    # on items the polygon will drop) — same helper used by import! so
    # the preview matches what would actually get imported.
    rows = refine_rows_to_region_polygon(rows, region_filter) if region_filter
    # Always enrich via Wikipedia pageimages. WikipediaImageFetcher's
    # `next if filename.blank?` preserves any P18 URL we already have
    # when MediaWiki returns no pageimage — so pageimages mode is a
    # strict superset of the old P18-only mode (fresher infobox photo
    # when available, P18 fallback otherwise). No reason to ever skip
    # this step.
    WikipediaImageFetcher.refresh_images!(rows: rows)
    candidates = dedupe_by_url(rows.select { |r| r[:url].present? && r[:lat] && r[:lng] })
    # No server-side existence check. Broken thumbnails (deleted/renamed
    # files on Commons) are handled at render time by hide_broken_image
    # — the wrapper collapses on img.onerror so the preview shows only
    # working thumbs. Validating server-side added a 1-batch API call
    # that's cheap here but for the full import meant 200+ calls per
    # 10k-row set and routinely tripped Commons 429 rate limits.
    candidates.first(limit)
  end

  # Full import. Reports progress through sub-states:
  #   "fetching"           — per-type SPARQL queries (progress = types done / total)
  #   "looking_up_images"  — Wikipedia pageimages batch
  #   "inserting"          — INSERT phase (progress = rows inserted / total)
  def self.import!(image_set:, pattern:, region_filter: nil)
    pattern = with_region_bbox(pattern, region_filter)
    types   = extract_types(pattern)

    image_set.update_columns(
      import_state:    "fetching",
      import_progress: 0,
      import_total:    types.size,
      import_warnings: nil
    )

    rows = if types.empty?
      # AI dropped P31 entirely (e.g. V5-style "height > 200" pattern).
      # Single query path; no per-type fan-out possible.
      sparql = build_random_sparql(pattern: pattern, limit: HARD_CAP, with_label: true)
      run_query(sparql, read_timeout: IMPORT_READ_TIMEOUT)
    else
      progress_cb = lambda do |done, total, _qid|
        image_set.update_columns(import_progress: done, import_total: total)
      end
      # Per-type failures (timeout, 5xx past retries) and cap-hits (the
      # type had >HARD_CAP matching items, so our 10k sample is a strict
      # subset) get surfaced on the show page. Concurrent::Hash because
      # parallel_per_type writes from multiple threads.
      type_failures = Concurrent::Hash.new
      type_caps     = Concurrent::Hash.new
      error_cb = lambda do |qid, exc|
        type_failures[qid] = "#{exc.class.name.split("::").last}: #{exc.message.slice(0, 120)}"
      end
      results = parallel_per_type(types, on_progress: progress_cb, on_error: error_cb) do |qid|
        sparql = build_per_type_sparql(
          pattern: pattern, qid: qid,
          limit: HARD_CAP, with_label: true
        )
        rows = run_query(sparql, read_timeout: IMPORT_READ_TIMEOUT)
        # Returning exactly HARD_CAP rows means ORDER BY ?rand truncated
        # — there were more items than our cap. Note for the user; the
        # set still gets the random 10k subset.
        type_caps[qid] = rows.size if rows.size >= HARD_CAP
        rows
      end
      warnings = {}
      warnings[:failed_types] = type_failures.to_h if type_failures.any?
      warnings[:capped_types] = type_caps.to_h     if type_caps.any?
      # jsonb column: AR auto-serializes the Hash, so no .to_json. Stored
      # as JSON object so callers can read warnings["failed_types"] etc.
      image_set.update_columns(import_warnings: warnings) if warnings.any?
      results.compact.flatten
    end

    rows = normalize_rows(rows)

    # Polygon refinement: WDQS's bbox is a rectangle; the true region
    # polygon is tighter, so bbox-matched items can fall outside the
    # actual region (NH lakes leaking into a "lakes in MA" set, etc).
    # Drop them BEFORE pageimages enrichment so we don't waste API
    # calls on items the polygon will remove.
    rows = refine_rows_to_region_polygon(rows, region_filter) if region_filter

    # Always enrich via Wikipedia pageimages — preserves any P18 URL we
    # already have when MediaWiki returns no pageimage (see sample/
    # WikipediaImageFetcher comments).
    image_set.update_columns(import_state: "looking_up_images", import_progress: 0, import_total: 0)
    WikipediaImageFetcher.refresh_images!(
      rows: rows,
      on_progress: ->(done, total) {
        # Wikipedia phase can be 30-90s for a 9k-item set (sequential
        # 50-batch calls + 0.2s courtesy sleep). Without this counter
        # the banner sits silent and users assume it's hung.
        image_set.update_columns(import_progress: done, import_total: total)
      }
    )

    keepable = rows.select { |r| r[:url].present? && r[:lat] && r[:lng] && photo_url?(r[:url]) }
    keepable = dedupe_by_url(keepable)

    # No Commons existence check here. We used to batch-call the
    # MediaWiki API to confirm every URL existed, but for a 10k import
    # that's 200+ batches and routinely tripped Commons rate limits
    # (HTTP 429) — when rate-limited, the checker passed through
    # everything anyway, giving zero validation. hide_broken_image at
    # render time catches files that 404 (deleted, renamed) without
    # the upstream noise.
    image_set.update_columns(import_state: "inserting", import_total: keepable.size, import_progress: 0)

    insert_rows!(image_set: image_set, rows: keepable)
  end

  # === Pattern-shape helpers ===

  # Returns the Q-IDs from `VALUES ?type { wd:Q... wd:Q... }`, or nil.
  def self.extract_union_types(pattern)
    m = pattern.match(/VALUES\s+\?type\s*\{([^}]+)\}/m)
    return nil unless m
    qids = m[1].scan(/wd:(Q\d+)/i).flatten
    qids.empty? ? nil : qids
  end

  # Returns the single Q-ID from `wdt:P31[/wdt:P279*] wd:Qxxx`, or nil.
  def self.extract_single_type(pattern)
    m = pattern.match(/wdt:P31(?:\/wdt:P279\*)?\s+wd:(Q\d+)/)
    m ? m[1] : nil
  end

  # Returns Q-IDs (always an Array). Handles VALUES patterns (multiple)
  # and single-type patterns (one). Empty when neither pattern shape
  # matches (e.g. AI dropped P31 entirely for a selective FILTER query).
  def self.extract_types(pattern)
    extract_union_types(pattern) || [ extract_single_type(pattern) ].compact
  end

  # === Region BBOX injection ===
  #
  # When the AI emits region_name/region_parent_name/region_admin_level,
  # the pipeline forwards them as a region_filter hash. We resolve to a
  # Region row (exact match — Region.search ranks high-pop countries
  # first, so it can't disambiguate "Massachusetts, United States"), then
  # wrap the AI's pattern with SERVICE wikibase:box using the bbox
  # already seeded from GeoNames. WDQS's native spatial index makes this
  # ~10× faster than BIND+FILTER on coords (1.5s vs 15s in our tests for
  # mountains-in-MA).
  #
  # The AI is told NEVER to compose wdt:P131* itself — that pattern
  # reliably times out WDQS for sub-national regions. The backend takes
  # over geo filtering whenever region_filter is set.

  # Exact AR lookup. Region.search's relevance ranking favours high-
  # population countries (tested: "Massachusetts United States" returns
  # United States first). For our disambiguation use case we need the
  # AI's structured fields → exact match. parent_name is optional; for
  # countries it's typically nil.
  def self.resolve_region_filter(region_filter)
    return nil if region_filter.blank?
    rf = region_filter.transform_keys(&:to_sym) rescue region_filter
    name  = rf[:name].to_s.strip.presence
    level = rf[:admin_level].to_s.strip.presence
    parent_name = rf[:parent_name].to_s.strip.presence
    return nil unless name && level
    scope = Region.where(name: name, admin_level: level)
    scope = scope.where(parent_id: Region.where(name: parent_name).select(:id)) if parent_name
    scope.first
  end

  def self.with_region_bbox(pattern, region_filter)
    region = resolve_region_filter(region_filter)
    return pattern unless region&.min_lat && region.min_lng && region.max_lat && region.max_lng
    # SERVICE wikibase:box uses Blazegraph's native geo-spatial index —
    # constrains ?item to coords inside the rectangle. Two non-obvious
    # gotchas that BOTH have to be right or the query returns 0:
    #
    #   1. SERVICE MUST come BEFORE the AI's class triple. With class
    #      first, WDQS materializes the full subclass set before joining
    #      against the spatial index — fast but returns zero matches
    #      (seems to be a Blazegraph optimizer quirk, verified empirically).
    #
    #   2. SERVICE binds its OWN ?coord variable, NOT the AI's ?coord.
    #      The AI's pattern always includes `wdt:P625 ?coord` (we tell it
    #      to, for output binding). If we use the same variable name, the
    #      two bindings collide — WDQS does an exact-WKT-literal match
    #      between the spatial-index ?coord and the property ?coord, which
    #      basically never succeeds (returns 0). Using ?_box_coord
    #      decouples them.
    #
    # ~10× faster than BIND+FILTER on coords once both are right
    # (measured: 1.8s for lakes-in-MA = 1299 results).
    "SERVICE wikibase:box {\n" \
      "  ?item wdt:P625 ?_box_coord .\n" \
      "  bd:serviceParam wikibase:cornerSouthWest \"Point(#{region.min_lng} #{region.min_lat})\"^^geo:wktLiteral .\n" \
      "  bd:serviceParam wikibase:cornerNorthEast \"Point(#{region.max_lng} #{region.max_lat})\"^^geo:wktLiteral .\n" \
      "}\n#{pattern.strip}"
  end

  # Drops rows whose coordinates fall outside the region's actual
  # polygon (vs. the bbox we used at WDQS). Fetches the polygon from
  # Nominatim if not already cached on the Region row — same lazy-fetch
  # pattern that ImageSet#materialize_filtered_items! uses for the
  # manual map-filter feature. Rate-limited (~1 req/s in Region's
  # nominatim_wait_for_slot!) but cached on the Region row forever
  # after first fetch, so amortized cost is one Nominatim call per
  # region per project lifetime.
  #
  # Used by BOTH sample (so the preview thumbnails match what the
  # import will land) and import! (so the persisted set is polygon-
  # accurate, not bbox-overshooting). Falls back to the bbox-filtered
  # rows if Nominatim is unreachable — degraded accuracy is better
  # than failing the whole flow.
  def self.refine_rows_to_region_polygon(rows, region_filter)
    region = resolve_region_filter(region_filter)
    return rows unless region

    unless region.boundary.present?
      begin
        region.fetch_real_boundary!
      rescue StandardError => e
        Rails.logger.warn "[poly_refine] Nominatim fetch failed for #{region.name}: #{e.class}: #{e.message.slice(0, 200)}"
        return rows
      end
    end

    polygon = region.rgeo_boundary
    return rows unless polygon

    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    kept = rows.select do |r|
      next false unless r[:lat] && r[:lng]
      point = factory.point(r[:lng], r[:lat])
      polygon.contains?(point) rescue false
    end
    Rails.logger.info "[poly_refine] region=#{region.name} bbox_in=#{rows.size} polygon_kept=#{kept.size}"
    kept
  end

  # === SPARQL builders ===

  # Per-type SPARQL: substitutes the type QID into the AI pattern, then
  # wraps with the SHA512 random-sample shape (or COUNT(*) for the count
  # phase). The pattern may be a single-type or VALUES-style umbrella;
  # we strip the VALUES clause and rewrite ?type to wd:Qxxx so per-type
  # fan-out gives us isolated queries.
  def self.build_per_type_sparql(pattern:, qid:, limit:, count_only: false, with_label: true)
    stripped    = pattern.sub(/VALUES\s+\?type\s*\{[^}]+\}\s*\.?\s*/m, "")
    # Word-boundary regex: plain `gsub("?type", ...)` would also replace
    # the prefix of `?typeOfThing` or similar, silently corrupting the
    # triple. The (?!\w) lookahead bounds after-the-name.
    with_qid_in = stripped.gsub(/\?type(?!\w)/, "wd:#{qid}")

    if count_only
      build_count_sparql(with_qid_in)
    else
      build_random_sparql(pattern: with_qid_in, limit: limit, with_label: with_label)
    end
  end

  def self.build_count_sparql(pattern)
    <<~SPARQL
      SELECT (COUNT(*) AS ?c) WHERE {
        #{pattern}
        #{image_or_article_block}
      }
    SPARQL
  end

  # Universal random-sample shape. Returns up to `limit` items drawn
  # uniformly at random from the filtered set — works under any pattern
  # shape (region bbox, country anchor, FILTER, UNION, P279* subclass
  # walk). See header docstring for why we use SHA512 over RAND() and
  # why we add a nonce.
  #
  # Layered so labels resolve AFTER the LIMIT subquery — per the WDQS
  # optimization docs, putting wikibase:label inside the expensive
  # block makes it materialize labels for every intermediate join
  # (rivers LIMIT 100 with label inside = 504 timeout; outside = 22s).
  def self.build_random_sparql(pattern:, limit:, with_label: true)
    inner = <<~INNER
      SELECT DISTINCT ?item ?image ?coord ?article WHERE {
        SELECT DISTINCT ?item ?image ?coord ?article (SHA512(CONCAT(STR(RAND()), STR(?item))) AS ?rand) WHERE {
          #{pattern}
          #{image_or_article_block}
        }
        ORDER BY ?rand
        LIMIT #{limit.to_i}
      }
    INNER
    # Per-call nonce in a leading comment — WDQS caches by query text,
    # so without this the FIRST call materializes RAND() and every
    # subsequent identical call returns the same "random" sample from
    # cache. Verified empirically: no nonce → 947/1000 overlap between
    # two runs of the same query; with nonce → 180/1000 (uniform).
    "# nonce: #{SecureRandom.hex(8)}\n" + wrap_with_label(inner, with_label: with_label)
  end

  # Optionally wraps an inner SPARQL block in an outer query that adds
  # SERVICE wikibase:label. Caller decides whether to opt in (count
  # queries don't need labels).
  def self.wrap_with_label(inner, with_label:)
    return inner unless with_label
    <<~SPARQL
      SELECT ?item ?itemLabel ?image ?coord ?article WHERE {
        { #{inner.strip} }
        SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
      }
    SPARQL
  end

  # Items pass if they have a Wikidata P18 image OR an English Wikipedia
  # article (we fall back to the article's lead image via WikipediaImageFetcher).
  def self.image_or_article_block
    <<~BLOCK
      OPTIONAL { ?item wdt:P18 ?image }
      OPTIONAL {
        ?article schema:about ?item ;
                 schema:isPartOf <https://en.wikipedia.org/> .
      }
      FILTER (BOUND(?image) || BOUND(?article))
    BLOCK
  end

  # === Per-type parallelism ===

  # Runs the block per type in parallel threads, with progress reporting.
  # Returns an array of results (nil for errored types — partial success
  # beats total failure). on_progress is called after EACH type completes
  # (succeeded OR failed) with (done, total, qid). on_error, if given,
  # is called with (qid, exception) for each failure — used by import!
  # to surface per-type warnings to the user.
  def self.parallel_per_type(types, on_progress: nil, on_error: nil)
    done = Concurrent::AtomicFixnum.new(0)
    threads = types.map do |qid|
      Thread.new do
        result =
          begin
            yield(qid)
          rescue Error => e
            Rails.logger.warn "[wdqs per-type] qid=#{qid} #{e.class}: #{e.message.slice(0, 200)}" if defined?(Rails)
            on_error&.call(qid, e)
            nil
          end
        n = done.increment
        begin
          # The progress callback typically writes back to the database
          # (e.g., image_set.update_columns(import_progress:)) — and we're
          # in a worker thread that has no AR connection of its own.
          # Without with_connection, AR either checks one out and never
          # returns it (pool leak) or raises ConnectionTimeoutError once
          # the pool is exhausted. with_connection borrows for the call
          # and returns the connection deterministically.
          ActiveRecord::Base.connection_pool.with_connection do
            on_progress&.call(n, types.size, qid)
          end
        rescue StandardError => e
          Rails.logger.warn "[wdqs per-type progress] #{e.class}: #{e.message}" if defined?(Rails)
        end
        result
      end
    end
    threads.map(&:value)
  end

  # === Row insert (the inserting phase) ===

  # Bulk insert: ~5 queries per batch of 500 instead of 4 queries per row.
  # For a 7k-image import that's ~70 queries vs 28,000 — meaningfully
  # less DB load, much less log noise, ~10× faster wall time.
  #
  # logger.silence wraps the whole thing so dev mode doesn't spam SQL
  # logs for every batch. Production already runs at info level so the
  # silence is mostly a dev quality-of-life win.
  #
  # Dedup strategy: we pre-query existing Images by URL and existing
  # ImageSetItems by image_id, then insert_all only the genuinely new
  # rows. The race-prone case (two concurrent imports of the same URL,
  # or a retry_import that overlaps the original job) is closed by the
  # unique index on images.url (where url IS NOT NULL) + unique_by: :url
  # below — if the race happens, ON CONFLICT DO NOTHING wins and we
  # later RELOAD the now-existing id rather than re-inserting.
  def self.insert_rows!(image_set:, rows:)
    new_links = 0
    inserted  = 0

    ActiveRecord::Base.logger.silence do
      rows.each_slice(500) do |slice|
        ImageSetItem.transaction do
          new_links += insert_slice!(image_set: image_set, slice: slice)
        end
        inserted += slice.size
        image_set.update_columns(import_progress: inserted)
      end
    end

    new_links
  end

  def self.insert_slice!(image_set:, slice:)
    # filter_map: nil URLs make for a useless Image (can't dedupe-by-url,
    # can't render). Upstream `import!` keepable-filter already drops
    # them but defensive — a future caller might not.
    urls = slice.filter_map { |r| r[:url] }
    url_to_image_id = Image.where(url: urls).pluck(:url, :id).to_h

    # 1. Bulk-insert any Image rows whose URL we don't already have.
    new_image_rows = slice.reject { |r| url_to_image_id.key?(r[:url]) }
                          .uniq { |r| r[:url] }
                          .map do |r|
      { url: r[:url], title: r[:title].presence || "Untitled",
        latitude: r[:lat], longitude: r[:lng],
        created_at: Time.current, updated_at: Time.current }
    end

    if new_image_rows.any?
      # unique_by: :url tells Rails to emit ON CONFLICT (url) DO NOTHING
      # — Rails finds the matching partial unique index (url IS NOT NULL)
      # by columns, so a stale schema cache doesn't bite us the way an
      # index-name lookup would (e.g. if a dev server is still up from
      # before the migration ran). Result: a concurrent importer that
      # beat us to a URL doesn't fail us. `returning:` won't include
      # rows skipped by ON CONFLICT, so we re-query missing ids below.
      result = Image.insert_all(new_image_rows, returning: %i[id url], unique_by: :url)
      result.rows.each { |id, url| url_to_image_id[url] = id }

      # ON CONFLICT DO NOTHING means rows that lost a race against a
      # concurrent insert don't appear in `result.rows` — re-fetch their
      # ids here so the subsequent join-table insert can use them.
      still_missing = new_image_rows.map { |r| r[:url] } - url_to_image_id.keys
      unless still_missing.empty?
        Image.where(url: still_missing).pluck(:url, :id).each do |url, id|
          url_to_image_id[url] = id
        end
      end
    end

    # 2. Bulk-insert ImageSetItem rows for images not already linked
    # to this set. Existing index_image_set_items_on_image_set_id_and_image_id
    # is unique, so duplicates also get caught at the DB level if we miss
    # one — but pre-filtering keeps the INSERT clean.
    candidate_image_ids = slice.filter_map { |r| url_to_image_id[r[:url]] }.uniq
    already_linked = image_set.image_set_items
                              .where(image_id: candidate_image_ids)
                              .pluck(:image_id).to_set

    item_rows = slice.filter_map do |r|
      image_id = url_to_image_id[r[:url]]
      next nil unless image_id
      next nil if already_linked.include?(image_id)
      already_linked << image_id  # guard against intra-slice dupes
      { image_set_id: image_set.id, image_id: image_id,
        latitude: r[:lat], longitude: r[:lng],
        created_at: Time.current, updated_at: Time.current }
    end

    if item_rows.any?
      # unique_by on (image_set_id, image_id) means a concurrent
      # importer that beat us to the same (set, image) pair causes
      # ON CONFLICT DO NOTHING instead of aborting the entire 500-row
      # batch with a uniqueness violation. The pre-query above filters
      # most races but a parallel retry_import can interleave.
      ImageSetItem.insert_all(item_rows, unique_by: %i[image_set_id image_id])
      item_rows.size
    else
      0
    end
  end

  # === HTTP ===

  # Retries on transient WDQS failures (5xx, connection-level errors).
  # WDQS is fronted by a load balancer that returns 502/503 under load
  # spikes; a single retry-after-backoff typically clears those.
  #
  # read_timeout: defaults to READ_TIMEOUT (45s — tight for preview UX).
  # Callers running off the request thread (import!) can pass a longer
  # value to ride out WDQS tail-latency variance.
  def self.run_query(sparql, read_timeout: READ_TIMEOUT)
    attempts = 0
    summary  = WikidataQueryLog.summarize_sparql(sparql)

    loop do
      attempts += 1
      t0 = Time.now

      response =
        begin
          req = Net::HTTP::Post.new(ENDPOINT)
          req["Accept"]       = "application/sparql-results+json"
          req["Content-Type"] = "application/x-www-form-urlencoded"
          req["User-Agent"]   = USER_AGENT
          req.body = URI.encode_www_form(query: sparql)
          Net::HTTP.start(ENDPOINT.hostname, ENDPOINT.port, use_ssl: true, read_timeout: read_timeout) do |h|
            h.request(req)
          end
        rescue Net::ReadTimeout, Net::OpenTimeout, EOFError, Errno::ECONNRESET => e
          WikidataQueryLog.log(action: :sparql, status: "timeout", duration: Time.now - t0,
                                attempt: attempts, error: "#{e.class}: #{e.message}", q: summary)
          if attempts < MAX_RETRIES
            sleep(attempts)
            next
          end
          raise TimeoutError, "Wikidata query timed out after #{attempts} attempts: #{e.class}: #{e.message}"
        end

      duration = Time.now - t0

      if response.code.start_with?("5") && attempts < MAX_RETRIES
        WikidataQueryLog.log(action: :sparql, status: response.code, duration: duration,
                              attempt: attempts, retrying: true, q: summary)
        sleep(attempts)
        next
      end

      if response.code != "200"
        WikidataQueryLog.log(action: :sparql, status: response.code, duration: duration,
                              attempt: attempts, error: response.body.to_s.slice(0, 200), q: summary)
        raise Error, "Wikidata returned HTTP #{response.code} after #{attempts} attempts: #{response.body.to_s[0, 300]}"
      end

      bindings = JSON.parse(response.body).dig("results", "bindings") || []
      WikidataQueryLog.log(action: :sparql, status: response.code, duration: duration,
                            attempt: attempts, bindings: bindings.size, q: summary)
      return bindings
    end
  end

  # === Result-shape helpers ===

  # Hosts we trust to serve actual image bytes. P18 always resolves through
  # Commons via Special:FilePath; Wikipedia pageimages return absolute upload
  # URLs (upload.wikimedia.org). Anything else is either an old/wrong P18
  # link (e.g. http://example.org from a vandal-tagged entity) or a Wikidata
  # data error — either way we don't want it in our image set, since the
  # browser will just show a broken-image icon.
  IMAGE_URL_HOSTS = %w[
    commons.wikimedia.org
    upload.wikimedia.org
  ].freeze

  # SPARQL bindings → plain hashes, deduped by ?item.
  #
  # Rows with NO URL at this stage are kept on purpose: for
  # image_source=wikipedia_pageimages the ?image slot is usually empty
  # at SPARQL time and gets populated later by WikipediaImageFetcher.
  # Filtering on nil here would drop the bulk of pageimages-mode rows
  # before they ever reach the fetcher. We only drop rows with a
  # *present-but-untrusted* URL (occasional Wikidata vandal data
  # pointing P18 at example.com, etc).
  def self.normalize_rows(bindings)
    seen_items = Set.new
    bindings.filter_map do |b|
      iri = b.dig("item", "value")
      next if iri && !seen_items.add?(iri)

      coord = b.dig("coord", "value")
      m = coord && coord.match(/Point\(([-\d.]+)\s+([-\d.]+)\)/)
      lng, lat = m ? [ m[1].to_f, m[2].to_f ] : [ nil, nil ]

      url   = b.dig("image", "value")&.sub(/\Ahttp:/, "https:")
      next if url.present? && !trusted_image_url?(url)

      title = b.dig("itemLabel", "value").presence
      title = nil if title&.match?(/\AQ\d+\z/)

      {
        item:    iri,
        title:   title || "Untitled",
        url:     url,
        lat:     lat,
        lng:     lng,
        article: b.dig("article", "value")
      }
    end
  end

  def self.trusted_image_url?(url)
    uri = URI.parse(url)
    uri.scheme == "https" && IMAGE_URL_HOSTS.include?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  # Drops rows with a URL we've already seen. Two different items can share
  # a P18 (e.g. one photo featuring two adjacent peaks).
  def self.dedupe_by_url(rows)
    seen = Set.new
    rows.select { |r| seen.add?(r[:url]) }
  end

  # URL passes the "looks like a photo" sniff test? Drops obvious maps,
  # schematics, satellite imagery that Wikidata sometimes records as P18.
  def self.photo_url?(url)
    return false if url.blank? || url.length > 500
    return false unless url.match?(/\.(jpe?g|png)\z/i)
    decoded = URI.decode_www_form_component(url.split("/").last.to_s)
    !NON_PHOTO_PATTERNS.any? { |p| decoded.match?(p) }
  end
end
