require "net/http"
require "uri"
require "json"

# Runs SPARQL queries against query.wikidata.org and turns the rows into
# Image / ImageSetItem records. The AI returns a *pattern* (WHERE-clause
# body); this service wraps the pattern three ways:
#
#   count!    — `SELECT (COUNT(*) AS ?c) WHERE { <pattern> }`
#   sample!   — random 30-row preview (uses bd:sample for large categories)
#   import!   — full fetch, optionally with bd:sample for large categories,
#               then insert into an ImageSet (image_set_items)
#
# All three reuse the wrapper helpers so the AI's pattern is the only
# AI-controlled string anywhere in the codebase that reaches an external
# service. The endpoint is hardcoded (read-only); there's no SSRF.
class WikidataImporter
  ENDPOINT = URI("https://query.wikidata.org/sparql").freeze
  USER_AGENT = "landscape-guessr/ai-image-sets (https://github.com/NU-CS-Software-Studio-Spring-26/project-landscape_guessr) Ruby/#{RUBY_VERSION}".freeze

  # WDQS hard timeout is 60s. Our read_timeout is 90s to swallow a bit of
  # network jitter without a connection-reset on the application side.
  READ_TIMEOUT = 90

  # Server-side safety net. If the AI returns a pattern with no sample
  # and no apparent limit on result size, this caps the import. AI is
  # instructed to use bd:sample for huge categories; this catches the
  # case where it forgets.
  HARD_CAP = 10_000

  # Non-photo filename patterns lifted from db/seeds.rb. Wikidata
  # occasionally records a satellite image or schematic as P18. No \b
  # word boundaries — Ruby's \b treats `_` as a word char, so \bMODIS\b
  # fails to match "MODIS_satellite.jpg". The seeder learned this the
  # hard way; do not re-add \b without testing against real filenames.
  NON_PHOTO_PATTERNS = [
    /ASTER|MODIS|Landsat|LANDSAT|Sentinel|MISR|Messtischblatt/i,
    /_map[._]|location[_\s-]map|relief[_\s-]map|system[_\s-]map/i,
    /topographic|schematic|Harper.?s[_\s-]New/i
  ].freeze

  class Error < StandardError; end
  class TimeoutError < Error; end

  # Returns the total number of items the pattern would match. For
  # patterns built around `VALUES ?type { wd:QA wd:QB ... }` (the
  # AI's idiom for "broad concept spanning multiple Wikidata classes"
  # — nature, transportation, sports, etc.), we run a COUNT per type
  # and sum, because the single-query form hits WDQS's 60s timeout on
  # broad P31/P279* walks. An items-belonging-to-multiple-types case
  # gets counted twice; we accept the small inaccuracy for the
  # ~20-30x speedup. Matches the per-type pattern in db/seeds.rb.
  def self.count(pattern:)
    if (types = extract_union_types(pattern))
      return count_per_type(pattern, types: types)
    end
    rows = run_query(<<~SPARQL)
      SELECT (COUNT(*) AS ?c) WHERE {
        #{pattern}
        #{image_or_article_block}
      }
    SPARQL
    rows.first&.dig("c", "value").to_i
  end

  # If the pattern contains `VALUES ?type { wd:Q... wd:Q... }`, return
  # the QIDs; otherwise nil. The AI is instructed to use this idiom
  # for broad concepts (see UNIVERSAL_PROPERTIES section of system
  # prompt); we detect it here for the count-fan-out optimization.
  def self.extract_union_types(pattern)
    m = pattern.match(/VALUES\s+\?type\s*\{([^}]+)\}/m)
    return nil unless m
    qids = m[1].scan(/wd:(Q\d+)/i).flatten
    qids.empty? ? nil : qids
  end

  # Run a count per type by substituting the VALUES variable. Each
  # per-type count is fast (one P31/P279* walk on a single class), and
  # we sum. Parallelized across threads — Net::HTTP creates a separate
  # connection per call so concurrent queries are safe, and WDQS easily
  # handles 5 parallel reads from one client. Wall time drops from
  # ~N×5s to ~5s for typical broad patterns.
  #
  # Errors on individual types are swallowed — better to under-count
  # than fail the whole preview screen.
  def self.count_per_type(pattern, types:)
    stripped = pattern.sub(/VALUES\s+\?type\s*\{[^}]+\}\s*\.?\s*/m, "")
    threads = types.map do |qid|
      Thread.new do
        one = stripped.gsub("?type", "wd:#{qid}")
        sparql = <<~SPARQL
          SELECT (COUNT(*) AS ?c) WHERE {
            #{one}
            #{image_or_article_block}
          }
        SPARQL
        run_query(sparql).first&.dig("c", "value").to_i
      rescue Error
        0  # partial under-count beats blanket failure
      end
    end
    threads.map(&:value).sum
  end

  # Returns up to `limit` rows (default 30) for preview thumbnails on
  # the form. NOT a random sample (WDQS's bd:sample SERVICE only
  # accepts a single direct triple inside, incompatible with our
  # multi-constraint patterns). LIMIT 30 gives alphabetical ordering.
  #
  # Same per-type fan-out as count(): broad `VALUES ?type { ... }`
  # patterns combined with P31/P279* walks timeout WDQS even at
  # LIMIT 30, because the optimizer can't short-circuit the OPTIONAL
  # + FILTER on image-or-article without evaluating the broad union
  # first. Per-type queries are each fast; we run them in parallel
  # and take the first `limit` rows.
  def self.sample(pattern:, image_source: "wikidata_p18", limit: 30)
    rows = if (types = extract_union_types(pattern))
      sample_per_type(pattern, types: types, limit: limit)
    else
      run_query(wrap_with_limit(pattern, limit: limit, with_label: true))
    end
    rows = normalize_rows(rows)
    if image_source == "wikipedia_pageimages"
      WikipediaImageFetcher.refresh_images!(rows: rows)
    end
    dedupe_by_url(rows.select { |r| r[:url].present? && r[:lat] && r[:lng] }).first(limit)
  end

  # Per-type sample matching the per-type count logic. Each per-type
  # query gets `limit/types.size` rows (rounded up) so the combined
  # result has roughly `limit` items after dedup. Runs in parallel
  # threads — same safety story as count_per_type.
  def self.sample_per_type(pattern, types:, limit:)
    stripped = pattern.sub(/VALUES\s+\?type\s*\{[^}]+\}\s*\.?\s*/m, "")
    per_type_limit = (limit.to_f / types.size).ceil + 2 # +2 buffer for dedup losses
    threads = types.map do |qid|
      Thread.new do
        one = stripped.gsub("?type", "wd:#{qid}")
        run_query(wrap_with_limit(one, limit: per_type_limit, with_label: true))
      rescue Error
        []
      end
    end
    threads.flat_map(&:value)
  end

  # Full import. Wraps the pattern with the OPTIONAL+FILTER trailer and
  # caps at HARD_CAP (10,000).
  #
  # Reports progress through three sub-states so the show-page polling
  # banner can tell the user what's actually happening, instead of
  # sitting on "0 / ?" for 30-90 seconds while the SPARQL + Wikipedia
  # legs finish:
  #   "fetching"           — running the full SPARQL (slow for broad ones)
  #   "looking_up_images"  — Wikipedia pageimages batch (pageimages mode only)
  #   "inserting"          — INSERT phase, where progress/total numbers
  #                          are populated and meaningful
  def self.import!(image_set:, pattern:, image_source: "wikidata_p18")
    image_set.update_columns(import_state: "fetching")
    sparql = wrap_with_limit(pattern, limit: HARD_CAP, with_label: true)
    rows = run_query(sparql)
    rows = normalize_rows(rows)

    if image_source == "wikipedia_pageimages"
      image_set.update_columns(import_state: "looking_up_images")
      WikipediaImageFetcher.refresh_images!(rows: rows)
    end

    # Filter rows the renderer would just drop anyway. Reports an honest
    # import_total before we start inserting so the progress bar isn't
    # off-by-skipped-rows. URL-dedup AFTER pageimages rewrite (the
    # rewrite changes URLs, so dedup must come after).
    keepable = rows.select { |r| r[:url].present? && r[:lat] && r[:lng] && photo_url?(r[:url]) }
    keepable = dedupe_by_url(keepable)

    image_set.update_columns(import_state: "inserting", import_total: keepable.size, import_progress: 0)

    new_links = 0
    inserted = 0
    keepable.each_slice(100) do |slice|
      ImageSetItem.transaction do
        slice.each do |row|
          image = Image.find_or_create_by!(url: row[:url]) do |img|
            img.title     = row[:title].presence || "Untitled"
            img.latitude  = row[:lat]
            img.longitude = row[:lng]
          end

          item = image_set.image_set_items.find_or_initialize_by(image: image)
          if item.new_record?
            item.latitude  = row[:lat]
            item.longitude = row[:lng]
            item.save!
            new_links += 1
          end
        end
      end
      inserted += slice.size
      image_set.update_columns(import_progress: inserted)
    end

    new_links
  end

  # === wrappers ===

  # Plain LIMIT-bounded query. Used when AI says the category isn't huge
  # (uses_random_sample = false). The OPTIONAL+FILTER trailer is added
  # outside the AI's pattern, then bounded by LIMIT.
  def self.wrap_with_limit(pattern, limit:, with_label: true)
    label_service = with_label ? %(SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }) : ""
    <<~SPARQL
      SELECT DISTINCT ?item ?itemLabel ?image ?coord ?article WHERE {
        #{pattern}
        #{image_or_article_block}
        #{label_service}
      } LIMIT #{limit.to_i}
    SPARQL
  end

  # Standard P18-or-Wikipedia-article trailer. Items pass if they have a
  # Wikidata P18 image OR an English Wikipedia article (so we can fall
  # back to the article's lead image via WikipediaImageFetcher).
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

  # === HTTP ===

  # Retries on transient WDQS failures (5xx, connection-level errors).
  # WDQS is fronted by a load balancer that returns 502/503 under load
  # spikes; a single retry-after-backoff typically clears those. Without
  # this, ONE flaky moment kills an import that took the user 90s of AI
  # work to set up.
  #
  # Retry budget: 3 attempts with 1s → 2s backoff. WDQS itself has a 60s
  # internal timeout so the worst-case wall time for the entire retry
  # loop is ~3×90s + 3s = ~273s — bounded.
  MAX_RETRIES = 3

  def self.run_query(sparql)
    attempts = 0
    summary = WikidataQueryLog.summarize_sparql(sparql)

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
            sleep(attempts) # 1s, 2s
            next
          end
          raise TimeoutError, "Wikidata query timed out after #{attempts} attempts: #{e.class}: #{e.message}"
        end

      duration = Time.now - t0

      if response.code.start_with?("5") && attempts < MAX_RETRIES
        # Transient — retry. Don't retry 4xx (our bug, not theirs) or
        # the final 5xx (caller decides what to do with the failure).
        WikidataQueryLog.log(action: :sparql, status: response.code, duration: duration,
                              attempt: attempts, retrying: true, q: summary)
        sleep(attempts) # 1s, 2s
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

  # SPARQL binding -> plain hash. Dedupes by ?item: when an item has
  # multiple P18 values, the query returns one row per (item, image)
  # pair. Without this dedup, "Mount Fuji" would appear in the set twice
  # — once for each of its P18 photos — which looks like a bug to users
  # who asked for "one photo of every X". Keeps the first row per item;
  # that's effectively the alphabetically-first image URL.
  def self.normalize_rows(bindings)
    seen_items = Set.new
    bindings.filter_map do |b|
      iri = b.dig("item", "value")
      next if iri && !seen_items.add?(iri)

      coord = b.dig("coord", "value")
      m = coord && coord.match(/Point\(([-\d.]+)\s+([-\d.]+)\)/)
      lng, lat = m ? [ m[1].to_f, m[2].to_f ] : [ nil, nil ]

      url   = b.dig("image", "value")&.sub(/\Ahttp:/, "https:")
      title = b.dig("itemLabel", "value").presence
      title = nil if title&.match?(/\AQ\d+\z/) # Wikibase falls back to entity id when no label

      {
        item:    iri,
        title:   title || "Untitled",
        url:     url,
        lat:     lat,
        lng:     lng,
        article: b.dig("article", "value") # may be nil; consumed by WikipediaImageFetcher
      }
    end
  end

  # Drops rows with a URL we've already seen. Why URL-dedup *after*
  # item-dedup (in normalize_rows): two different Wikidata items can
  # share an image URL (e.g. one photo featuring two adjacent peaks
  # gets used as P18 for both items). Without this pass, both items
  # render as separate cards in the preview/set with the same picture.
  # Keeps the first row per URL.
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
