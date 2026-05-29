require "net/http"
require "uri"
require "json"

# Imports image rows from Wikimedia Commons CirrusSearch via `list=search`
# with `deepcategory:` + `nearcoord:` (or `intitle:` as fallback).
#
# Query shape (verified):
#   srsearch = [
#     'deepcategory:"<cat>"' OR 'intitle:"<fallback>"',
#     'nearcoord:<r>km,<lat>,<lng>',
#     'filemime:image/jpeg'   (filtered client-side instead — see below)
#   ].join(" ")
#
# We do NOT use the `filemime:` operator because pipe-OR doesn't work in
# CirrusSearch — to include PNGs too we'd need a separate query. Client-
# side filename-extension filter is cheaper and gets us both formats.
#
# Hex lattice (`Geo::HexLattice`) generates multiple probe points when
# the region is larger than a single 30km circle. `srlimit=500` is the
# CirrusSearch max; `sroffset` works up to ~10k but most large probes
# hit way fewer hits anyway.
class CommonsImporter
  API = URI("https://commons.wikimedia.org/w/api.php").freeze
  USER_AGENT = WikimediaUserAgent::STRING
  READ_TIMEOUT = 60

  PROBE_RADIUS_KM = 30
  MAX_PROBES = 200             # hex-lattice cap (a 30km circle can't tile a continent)
  # A big region's hex lattice can be 200 probes; each probe is a separate
  # CirrusSearch query (deepcategory is 2-5s). Querying all 200 blows the
  # pipeline's time budget, so the preview/import walk a bounded, evenly-strided
  # subset of the lattice, and COUNT estimates the import by counting that SAME
  # subset (IMPORT_PROBE_CAP probes) concurrently — never a uniform 8-probe
  # extrapolation, which missed the city clusters and reported 0 for countries.
  COUNT_CONCURRENCY   = 8
  SAMPLE_PROBE_CAP    = 12
  IMPORT_PROBE_CAP    = 40
  HTTP_MAX_ATTEMPTS   = 3      # retry transient 5xx / timeouts (e.g. deepcategory 504)
  PER_REQUEST_LIMIT = 500      # gsrlimit max per CirrusSearch request
  # Max rows paginated from a single nearcoord probe. CirrusSearch caps
  # gsroffset at 10k (offset+limit ≤ 10000), so we stay well under to leave
  # headroom and keep one probe from monopolising a multi-probe import.
  PER_PROBE_CAP = 5_000
  HARD_CAP = 10_000             # total rows per import (matches WikidataImporter)
  PREVIEW_OVERSAMPLE = 3
  # Commons file pages render thumbnails via Special:FilePath; image_src
  # appends ?width=N at display time. Same convention as Wikidata/Wikipedia
  # images — and it means we DON'T request a server-rendered thumbnail in
  # the bulk fetch (iiurlwidth), which silently kills gsroffset pagination.
  FILEPATH = "https://commons.wikimedia.org/wiki/Special:FilePath/".freeze
  IMAGE_EXTENSIONS = /\.(jpe?g|png)\z/i

  class Error < StandardError; end

  # === Public API ===

  def self.count(commons_category:, intitle_fallback: nil, region_resolved: nil, on_progress: nil)
    return 0 if commons_category.blank? && intitle_fallback.blank?

    # Estimate the import yield by counting the SAME probes the import will
    # fetch (sample_probes(.., IMPORT_PROBE_CAP)), concurrently. The old code
    # counted 8 evenly-strided probes and ×(200/8) extrapolated — but geotagged
    # photos cluster in cities, so a uniform stride missed them and reported
    # wildly-low or 0 counts for countries ("churches in France" → 0 despite
    # Paris alone having 1292). Clamp to HARD_CAP since that's the import ceiling.
    probes = sample_probes(probes_for(region_resolved), IMPORT_PROBE_CAP)
    # A city / region-less subject is a single probe (possibly nil = no
    # nearcoord) — count it directly (concurrency is pointless and a nil probe
    # can't be enqueued unambiguously).
    if probes.size <= 1
      n = begin
        count_one_probe(commons_category: commons_category, intitle_fallback: intitle_fallback, probe: probes.first)
      rescue Error
        0
      end
      on_progress&.call(1, 1, [ n, HARD_CAP ].min)
      return [ n, HARD_CAP ].min
    end

    total = Concurrent::AtomicFixnum.new(0)
    done  = Concurrent::AtomicFixnum.new(0)
    each_probe_concurrent(probes) do |probe|
      n = begin
        count_one_probe(commons_category: commons_category, intitle_fallback: intitle_fallback, probe: probe)
      rescue Error => e
        Rails.logger.warn "[commons count] probe failed: #{e.message.slice(0, 120)}"
        0
      end
      total.increment(n)
      d = done.increment
      on_progress&.call(d, probes.size, [ total.value, HARD_CAP ].min)
    end
    [ total.value, HARD_CAP ].min
  end

  # Run a totalhits count for each probe concurrently (deepcategory probes are
  # 1-5s of network wait each; a country's 40 probes sequentially would blow the
  # proposal's time budget). Shared thread-pool; per-probe errors handled by the
  # caller's begin/rescue.
  def self.each_probe_concurrent(probes)
    return if probes.empty?
    queue = Queue.new
    probes.each { |p| queue << p }
    pool = [ probes.size, COUNT_CONCURRENCY ].min
    threads = Array.new(pool) do
      Thread.new do
        loop do
          probe = queue.pop(true) rescue nil
          break unless probe
          yield probe
        end
      end
    end
    threads.each(&:join)
  end

  def self.sample(commons_category:, intitle_fallback: nil, region_resolved: nil, limit: 30, on_progress: nil)
    return [] if commons_category.blank? && intitle_fallback.blank?

    target = limit * PREVIEW_OVERSAMPLE
    rows = collect_rows(
      commons_category: commons_category,
      intitle_fallback: intitle_fallback,
      region_resolved: region_resolved,
      max_rows: target,
      probe_cap: SAMPLE_PROBE_CAP
    )
    dedupe_by_external_id(refine_to_polygon(rows, region_resolved)).shuffle.first(limit)
  end

  # expected_count (from the proposal the user already saw) drives the
  # progress bar so it advances smoothly during the fetch — without it, a
  # single-probe region (a city) reported "0 of 1 areas" and looked frozen
  # until the import finished.
  def self.import!(image_set:, commons_category:, intitle_fallback: nil, region_resolved: nil, expected_count: nil)
    target = expected_count.to_i > 0 ? [ expected_count.to_i, HARD_CAP ].min : HARD_CAP
    image_set.update_columns(import_state: "fetching", import_progress: 0, import_total: target)

    rows = collect_rows(
      commons_category: commons_category,
      intitle_fallback: intitle_fallback,
      region_resolved: region_resolved,
      max_rows: HARD_CAP,
      probe_cap: IMPORT_PROBE_CAP,
      on_rows: ->(n) { image_set.update_columns(import_progress: [ n, target ].min) }
    )
    rows = refine_to_polygon(rows, region_resolved)
    rows = dedupe_by_external_id(rows)

    image_set.update_columns(import_state: "inserting", import_total: rows.size, import_progress: 0)
    Image.bulk_insert_for_source!(image_set: image_set, rows: rows, source: "commons")
  end

  # === Effective region ===

  # The region whose `nearcoord:` we anchor on. If the AI named a region,
  # use it. Otherwise, for a region-less subject prompt ("Mount Fuji
  # photos"), anchor on the subject's OWN coordinates so deepcategory
  # pollution and ungeotagged/mistagged files (a "Mount Fuji" photo
  # geotagged in Hong Kong) get pruned. Returns nil only when there's no
  # region AND the topic has no coordinate — then the query runs
  # category-only (rare; e.g. an intitle fallback with no topic).
  def self.effective_region(region_resolved:, topic_qid: nil)
    return region_resolved if region_resolved
    return nil if topic_qid.blank?
    coord = WikidataPropertyLookup.coordinate_for(topic_qid)
    return nil unless coord
    RegionResolver.around_point(lat: coord[:lat], lng: coord[:lng], label: nil)
  end

  # === Probe + query plumbing ===

  def self.probes_for(region_resolved)
    return [ nil ] if region_resolved.nil?
    probes = Geo::HexLattice.probes_for_bbox(region_resolved.bbox, radius_km: PROBE_RADIUS_KM, max_probes: 200)
    # Keep only probes whose centre is inside the region polygon. A country's
    # bbox is mostly ocean/neighbours at the corners; without this the strided
    # count/import sample wastes most of its budget on empty water (the "churches
    # in France → 0" case: the few sampled probes all landed off-land). No-op for
    # Mode-B (polygon-less) regions. Never strands the import if the polygon is odd.
    polygon = region_resolved.polygon
    return probes unless polygon
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    inside = probes.select { |p| polygon.contains?(factory.point(p[:lng], p[:lat])) rescue true }
    inside.presence || probes
  end

  # Builds the CirrusSearch query string. Quoting handled by us — Cirrus
  # treats unquoted multi-word category names as separate tokens. We
  # also escape literal quotes by removing them (Commons category names
  # never contain `"`, but defensive).
  def self.build_srsearch(commons_category:, intitle_fallback:, probe:)
    parts = []
    if commons_category.present?
      cat_safe = commons_category.gsub('"', "")
      parts << %(deepcategory:"#{cat_safe}")
    elsif intitle_fallback.present?
      it_safe = intitle_fallback.gsub('"', "")
      parts << %(intitle:"#{it_safe}")
    end
    parts << "nearcoord:#{probe[:radius_km].to_i}km,#{probe[:lat].round(5)},#{probe[:lng].round(5)}" if probe
    parts.join(" ")
  end

  def self.count_one_probe(commons_category:, intitle_fallback:, probe:)
    srsearch = build_srsearch(commons_category: commons_category, intitle_fallback: intitle_fallback, probe: probe)
    params = {
      action: "query", list: "search", srsearch: srsearch,
      srnamespace: 6, srinfo: "totalhits", srprop: "",
      srlimit: 1, format: "json", formatversion: 2
    }
    data = api_get(params)
    data.dig("query", "searchinfo", "totalhits").to_i
  end

  # Walks a bounded, evenly-spread subset of the region's probes, paginating
  # up to max_rows. Stops early once max_rows reached. A probe that errors
  # (e.g. a transient 504 on one nearcoord area) is logged and skipped rather
  # than failing the whole import. on_rows fires per page with the running
  # total so the progress bar advances even within a single probe.
  def self.collect_rows(commons_category:, intitle_fallback:, region_resolved:, max_rows:, probe_cap: IMPORT_PROBE_CAP, on_rows: nil)
    probes = sample_probes(probes_for(region_resolved), probe_cap)
    rows = []

    probes.each do |probe|
      break if rows.size >= max_rows
      base = rows.size
      begin
        fetched = fetch_probe_rows(
          commons_category: commons_category, intitle_fallback: intitle_fallback,
          probe: probe, limit: [ max_rows - rows.size, PER_PROBE_CAP ].min,
          on_page: on_rows ? ->(probe_rows) { on_rows.call(base + probe_rows) } : nil
        )
        rows.concat(fetched)
      rescue Error => e
        Rails.logger.warn "[commons collect] probe failed, skipping: #{e.message.slice(0, 120)}"
      end
      on_rows&.call(rows.size)
    end
    rows
  end

  # Evenly-strided subset of `items` (≤ n). The hex lattice is row-ordered, so
  # striding keeps geographic spread (vs `.first(n)` which clusters in a corner).
  def self.sample_probes(items, n)
    return items if items.size <= n
    stride = items.size.to_f / n
    (0...n).map { |i| items[(i * stride).floor] }
  end

  # Single probe → up to `limit` rows. Uses generator=search +
  # prop=imageinfo|coordinates to get URL+coord in one API hit. on_page fires
  # after each gsroffset page with the running row count for this probe.
  def self.fetch_probe_rows(commons_category:, intitle_fallback:, probe:, limit:, on_page: nil)
    rows = []
    sroffset = 0
    srsearch = build_srsearch(commons_category: commons_category, intitle_fallback: intitle_fallback, probe: probe)

    while rows.size < limit
      batch_limit = [ limit - rows.size, PER_REQUEST_LIMIT ].min
      params = {
        action: "query",
        generator: "search",
        gsrsearch: srsearch,
        gsrnamespace: 6,
        gsrlimit: batch_limit,
        gsroffset: sroffset,
        prop: "imageinfo|coordinates",
        # No iiurlwidth: asking for a server-rendered thumbnail silently
        # drops the gsroffset continuation (verified), capping a probe to a
        # single 500-row page. We build the thumb URL ourselves below.
        iiprop: "extmetadata",
        coprop: "type",
        # `coordinates` defaults to colimit=10 — without this a 500-file
        # batch returns coordinates for only the first 10, so the other ~490
        # are silently dropped at `next unless coord` below. This one missing
        # param is what made Commons imports yield ~0 despite huge counts.
        colimit: PER_REQUEST_LIMIT,
        format: "json", formatversion: 2
      }
      data = api_get(params)

      pages = data.dig("query", "pages") || []
      break if pages.empty?

      pages.each do |p|
        coord = (p["coordinates"] || []).first
        next unless coord

        title = p["title"].to_s.sub(/\AFile:/, "")
        next unless title.match?(IMAGE_EXTENSIONS)

        ii = (p["imageinfo"] || []).first
        rows << {
          external_source: "commons",
          external_id: p["pageid"].to_s,
          url: filepath_url(title),
          title: title,
          lat: coord["lat"].to_f,
          lng: coord["lon"].to_f,
          author: extract_author(ii&.dig("extmetadata")),
          license: extract_license(ii&.dig("extmetadata"))
        }
      end

      on_page&.call(rows.size)

      cont = data["continue"]
      break unless cont && cont["gsroffset"]
      sroffset = cont["gsroffset"].to_i
    end

    rows
  end

  # Display URL for a Commons file. Special:FilePath resolves to the file
  # (or a width-N thumb when image_src appends ?width). Space→%20 because
  # encode_www_form_component uses '+' for spaces, which Special:FilePath
  # would treat as a literal '+' in the filename.
  def self.filepath_url(filename)
    FILEPATH + URI.encode_www_form_component(filename).gsub("+", "%20")
  end

  # Author/license from extmetadata are HTML — strip tags lightly. We
  # don't need pixel-perfect; this is for attribution display.
  def self.extract_author(extmetadata)
    return nil if extmetadata.blank?
    raw = extmetadata.dig("Artist", "value")
    return nil if raw.blank?
    decoded = ActionController::Base.helpers.strip_tags(raw.to_s).strip
    decoded.empty? ? nil : decoded.slice(0, 200)
  end

  def self.extract_license(extmetadata)
    return nil if extmetadata.blank?
    raw = extmetadata.dig("LicenseShortName", "value") || extmetadata.dig("License", "value")
    return nil if raw.blank?
    raw.to_s.strip.slice(0, 80)
  end

  # Polygon refinement (Mode A only — Mode B/C have no polygon, just bbox).
  # When polygon available, drops rows outside.
  def self.refine_to_polygon(rows, region_resolved)
    return rows unless region_resolved&.polygon
    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    polygon = region_resolved.polygon
    rows.select do |r|
      next false unless r[:lat] && r[:lng]
      point = factory.point(r[:lng], r[:lat])
      polygon.contains?(point) rescue false
    end
  end

  # Dedupe by external_id — multiple probes can return the same file
  # when their nearcoord circles overlap (which is expected, by design).
  def self.dedupe_by_external_id(rows)
    seen = Set.new
    rows.select { |r| seen.add?(r[:external_id]) }
  end

  # === HTTP ===

  # deepcategory is expensive and Commons occasionally returns a transient
  # 5xx (502/503/504 upstream timeout) or the connection times out. Retry
  # those a few times with linear backoff before giving up — one blip
  # shouldn't kill a whole import.
  def self.api_get(params)
    uri = API.dup
    uri.query = URI.encode_www_form(params)
    attempt = 0
    loop do
      attempt += 1
      begin
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = USER_AGENT
          h.request(req)
        end
        if res.is_a?(Net::HTTPServerError) && attempt < HTTP_MAX_ATTEMPTS
          sleep(attempt)
          next
        end
        raise Error, "Commons API HTTP #{res.code}: #{res.body.to_s.slice(0, 300)}" unless res.is_a?(Net::HTTPSuccess)
        return JSON.parse(res.body)
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, SocketError => e
        raise Error, "Commons API network error after #{attempt} attempts: #{e.class}" if attempt >= HTTP_MAX_ATTEMPTS
        sleep(attempt)
      end
    end
  end
end
