require "net/http"
require "uri"
require "json"
require "concurrent/atomic/atomic_fixnum"

# Runs SPARQL queries against query.wikidata.org and turns the rows into
# Image / ImageSetItem records. The AI returns a *pattern* (WHERE-clause
# body) plus a `fetch_strategy`; this service wraps both ways and runs
# per-type fan-out for performance.
#
# == Strategies
#
# `exhaustive` — fetch every matching item via a P31/P279* subclass walk.
# Right for narrow queries (country-bounded, FILTER-narrowed, specific
# class). Equivalent to the rake's per-type sequential pattern.
#
# `random_sample` — wrap each per-type lookup with `SERVICE bd:sample`
# inside Blazegraph. Capped at HARD_CAP random items per type. Right for
# broad worldwide queries ("rivers worldwide") where the subclass walk
# would time out WDQS's 60s limit.
#
# Random_sample loses two things vs exhaustive:
#   - the P279* subclass walk (bd:sample only takes one inner triple)
#   - the ability to FILTER inside the inner block (so FILTER patterns
#     auto-override back to exhaustive)
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
  READ_TIMEOUT = 90

  HARD_CAP = 10_000

  EXHAUSTIVE    = "exhaustive".freeze
  RANDOM_SAMPLE = "random_sample".freeze
  STRATEGIES    = [ EXHAUSTIVE, RANDOM_SAMPLE ].freeze

  MAX_RETRIES = 3

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
  # For random_sample, returns the SUM of per-type bd:sample row counts
  # — a lower bound on the true count, capped at HARD_CAP per type.
  # When a per-type result hits the cap, callers can read "≥ cap" from
  # the result_count comparison.
  def self.count(pattern:, fetch_strategy: EXHAUSTIVE, on_progress: nil)
    strategy = effective_strategy(pattern, fetch_strategy)
    types    = extract_types(pattern)

    if types.empty?
      rows = run_query(build_count_sparql(pattern))
      return rows.first&.dig("c", "value").to_i
    end

    results = parallel_per_type(types, on_progress: on_progress) do |qid|
      sparql = build_per_type_sparql(
        pattern: pattern, qid: qid, strategy: strategy,
        limit: HARD_CAP, count_only: true, with_label: false
      )
      rows = run_query(sparql)
      rows.first&.dig("c", "value").to_i
    end
    results.compact.sum
  end

  # Returns up to `limit` rows for the preview thumbnails. NOT a guaranteed
  # random sample for exhaustive strategy (LIMIT gives alphabetical order
  # since WDQS doesn't push LIMIT into the walk). For random_sample,
  # bd:sample really does return random rows.
  def self.sample(pattern:, image_source: "wikidata_p18", limit: 30, fetch_strategy: EXHAUSTIVE, on_progress: nil)
    strategy = effective_strategy(pattern, fetch_strategy)
    types    = extract_types(pattern)

    rows = if types.empty?
      run_query(wrap_with_limit(pattern, limit: limit, with_label: true))
    else
      # For random_sample, oversample inside bd:sample to compensate for
      # outer-filter losses (only ~15-20% of random items have
      # coord+image+article — empirically: bd:sample 5000 → ~840
      # surviving). Without this multiplier, a 30-row preview from 14
      # types ends up with 5 visible rows after filtering.
      base_per_type = (limit.to_f / types.size).ceil + 2
      per_type_limit = strategy == RANDOM_SAMPLE ? base_per_type * 20 : base_per_type
      results = parallel_per_type(types, on_progress: on_progress) do |qid|
        sparql = build_per_type_sparql(
          pattern: pattern, qid: qid, strategy: strategy,
          limit: per_type_limit, with_label: true
        )
        run_query(sparql)
      end
      results.compact.flatten
    end

    rows = normalize_rows(rows)
    WikipediaImageFetcher.refresh_images!(rows: rows) if image_source == "wikipedia_pageimages"
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
  #   "looking_up_images"  — Wikipedia pageimages batch (pageimages mode only)
  #   "inserting"          — INSERT phase (progress = rows inserted / total)
  def self.import!(image_set:, pattern:, image_source: "wikidata_p18", fetch_strategy: EXHAUSTIVE)
    strategy = effective_strategy(pattern, fetch_strategy)
    types    = extract_types(pattern)

    image_set.update_columns(
      import_state:    "fetching",
      import_progress: 0,
      import_total:    types.size
    )

    rows = if types.empty?
      # AI dropped P31 entirely (e.g. V5-style "height > 200" pattern).
      # Single query path; no per-type fan-out possible.
      run_query(wrap_with_limit(pattern, limit: HARD_CAP, with_label: true))
    else
      progress_cb = lambda do |done, total, _qid|
        image_set.update_columns(import_progress: done, import_total: total)
      end
      results = parallel_per_type(types, on_progress: progress_cb) do |qid|
        sparql = build_per_type_sparql(
          pattern: pattern, qid: qid, strategy: strategy,
          limit: HARD_CAP, with_label: true
        )
        run_query(sparql)
      end
      results.compact.flatten
    end

    rows = normalize_rows(rows)

    if image_source == "wikipedia_pageimages"
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
    end

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

  # === Strategy + pattern-shape helpers ===

  # bd:sample's inner block only accepts a single direct triple — no
  # FILTER, no VALUES, no multi-triple. If the AI requested random_sample
  # but the pattern has FILTER, the bd:sample wrapping would silently
  # drop the filter and import the wrong items. Override to exhaustive.
  #
  # Also override if we can't extract any type Q-ID (nothing to sample).
  def self.effective_strategy(pattern, requested)
    return EXHAUSTIVE unless STRATEGIES.include?(requested)
    return EXHAUSTIVE unless requested == RANDOM_SAMPLE
    if pattern_has_filter?(pattern)
      Rails.logger.warn "[wdqs] random_sample requested but pattern has FILTER; overriding to exhaustive" if defined?(Rails)
      return EXHAUSTIVE
    end
    if extract_types(pattern).empty?
      Rails.logger.warn "[wdqs] random_sample requested but no extractable type Q-ID; overriding to exhaustive" if defined?(Rails)
      return EXHAUSTIVE
    end
    # Multi-P31 outside a VALUES block: extract_single_type only sees the
    # first match and strip_type_triple only strips the first. The second
    # un-stripped triple would silently filter our random_sample results.
    if extract_union_types(pattern).nil? && multiple_p31_triples?(pattern)
      Rails.logger.warn "[wdqs] random_sample requested but multiple P31 triples present (not in VALUES); overriding to exhaustive" if defined?(Rails)
      return EXHAUSTIVE
    end
    RANDOM_SAMPLE
  end

  def self.pattern_has_filter?(pattern)
    pattern.match?(/\bFILTER\s*\(/i)
  end

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

  # Defense against a multi-P31 pattern slipping past `extract_single_type`
  # (which only catches the first match). For random_sample, we strip ONLY
  # the matched P31 and wrap with bd:sample — if a SECOND P31 triple
  # constrains the outer query, the sample silently returns items that
  # don't match the user's full intent. Cheaper to refuse and fall back
  # to exhaustive than to ship wrong results.
  def self.multiple_p31_triples?(pattern)
    pattern.scan(/wdt:P31(?:\/wdt:P279\*)?\s+wd:Q\d+/).size > 1
  end

  # Removes the AI's `?item wdt:P31[/wdt:P279*] wd:Qxxx` triple from a
  # pattern, leaving the rest. Handles both `;` (continues subject) and
  # `.` (ends statement) delimiters. When `;`, replace with `?item` so
  # subsequent predicates re-bind correctly.
  def self.strip_type_triple(pattern, qid)
    # (?<![A-Za-z0-9_]) makes ?item a real variable boundary — without
    # it, `?subitem wdt:P31 ...` would partial-match because plain
    # `\?item` matches anywhere `?item` appears as a substring.
    re = /(?<![A-Za-z0-9_])\?item\s+wdt:P31(?:\/wdt:P279\*)?\s+wd:#{qid}\s*([.;])/
    pattern.sub(re) do
      Regexp.last_match(1) == ";" ? "?item" : ""
    end
  end

  # === SPARQL builders ===

  # Strategy-aware per-type SPARQL builder. Used by count/sample/import
  # for both exhaustive (subclass walk) and random_sample (bd:sample)
  # paths. Centralizing here means changes to the query shape (e.g. label
  # service, image/article trailer) flow through both strategies.
  def self.build_per_type_sparql(pattern:, qid:, strategy:, limit:, count_only: false, with_label: true)
    stripped     = pattern.sub(/VALUES\s+\?type\s*\{[^}]+\}\s*\.?\s*/m, "")
    # Word-boundary regex: plain `gsub("?type", ...)` would also replace
    # the prefix of `?typeOfThing` or similar, silently corrupting the
    # triple. The (?!\w) lookahead bounds after-the-name.
    with_qid_in  = stripped.gsub(/\?type(?!\w)/, "wd:#{qid}")

    case strategy
    when RANDOM_SAMPLE
      extras = strip_type_triple(with_qid_in, qid)
      build_random_sample_sparql(qid: qid, extras: extras, limit: limit,
                                  count_only: count_only, with_label: with_label)
    else # EXHAUSTIVE
      if count_only
        build_count_sparql(with_qid_in)
      else
        wrap_with_limit(with_qid_in, limit: limit, with_label: with_label)
      end
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

  def self.build_random_sample_sparql(qid:, extras:, limit:, count_only:, with_label:)
    if count_only
      return <<~SPARQL
        SELECT (COUNT(*) AS ?c) WHERE {
          SERVICE bd:sample {
            ?item wdt:P31 wd:#{qid} .
            bd:serviceParam bd:sample.limit #{limit.to_i} .
            bd:serviceParam bd:sample.sampleType "RANDOM" .
          }
          #{extras}
          #{image_or_article_block}
        }
      SPARQL
    end

    inner = <<~INNER
      SELECT DISTINCT ?item ?image ?coord ?article WHERE {
        SERVICE bd:sample {
          ?item wdt:P31 wd:#{qid} .
          bd:serviceParam bd:sample.limit #{limit.to_i} .
          bd:serviceParam bd:sample.sampleType "RANDOM" .
        }
        #{extras}
        #{image_or_article_block}
      }
    INNER
    wrap_with_label(inner, with_label: with_label)
  end

  # Standard exhaustive wrapper. Per the WDQS optimization docs, we
  # apply the label service AFTER an inner subquery with LIMIT — this
  # way labels are only fetched for the N surviving rows, not for every
  # intermediate join. Empirically: rivers LIMIT 100 with label INSIDE
  # = 504 timeout; same query with label OUTSIDE in subquery = 22s, 100
  # rows. Universal win, no downside.
  def self.wrap_with_limit(pattern, limit:, with_label: true)
    inner = <<~INNER
      SELECT DISTINCT ?item ?image ?coord ?article WHERE {
        #{pattern}
        #{image_or_article_block}
      } LIMIT #{limit.to_i}
    INNER
    wrap_with_label(inner, with_label: with_label)
  end

  # Optionally wraps an inner SPARQL block in an outer query that adds
  # SERVICE wikibase:label. Caller decides whether to opt in (count
  # queries don't need labels). Centralized so both wrap_with_limit and
  # build_random_sample_sparql use the identical outer shape.
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
  # (succeeded OR failed) with (done, total, qid).
  def self.parallel_per_type(types, on_progress: nil)
    done = Concurrent::AtomicFixnum.new(0)
    threads = types.map do |qid|
      Thread.new do
        result =
          begin
            yield(qid)
          rescue Error => e
            Rails.logger.warn "[wdqs per-type] qid=#{qid} #{e.class}: #{e.message.slice(0, 200)}" if defined?(Rails)
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
  def self.run_query(sparql)
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
          Net::HTTP.start(ENDPOINT.hostname, ENDPOINT.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
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
