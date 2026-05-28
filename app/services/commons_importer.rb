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
  PER_PROBE_HARD_CAP = 500     # MediaWiki srlimit max
  HARD_CAP = 10_000             # Match WikidataImporter
  PREVIEW_OVERSAMPLE = 3
  THUMB_WIDTH = 1024
  IMAGE_EXTENSIONS = /\.(jpe?g|png)\z/i

  class Error < StandardError; end

  # === Public API ===

  def self.count(commons_category:, intitle_fallback: nil, region_resolved: nil, on_progress: nil)
    return 0 if commons_category.blank? && intitle_fallback.blank?

    probes = probes_for(region_resolved)
    total = 0
    probes.each_with_index do |probe, idx|
      total += count_one_probe(commons_category: commons_category, intitle_fallback: intitle_fallback, probe: probe)
      on_progress&.call(idx + 1, probes.size, total)
    end
    total
  end

  def self.sample(commons_category:, intitle_fallback: nil, region_resolved: nil, limit: 30, on_progress: nil)
    return [] if commons_category.blank? && intitle_fallback.blank?

    target = limit * PREVIEW_OVERSAMPLE
    rows = collect_rows(
      commons_category: commons_category,
      intitle_fallback: intitle_fallback,
      region_resolved: region_resolved,
      max_rows: target,
      on_progress: on_progress
    )
    refine_to_polygon(rows, region_resolved).shuffle.first(limit)
  end

  def self.import!(image_set:, commons_category:, intitle_fallback: nil, region_resolved: nil)
    image_set.update_columns(import_state: "fetching", import_progress: 0, import_total: 0)

    rows = collect_rows(
      commons_category: commons_category,
      intitle_fallback: intitle_fallback,
      region_resolved: region_resolved,
      max_rows: HARD_CAP,
      on_progress: ->(done, total, _sum) {
        image_set.update_columns(import_progress: done, import_total: total)
      }
    )
    rows = refine_to_polygon(rows, region_resolved)
    rows = rows.reject { |r| r[:url].blank? || !r[:url].match?(IMAGE_EXTENSIONS) }
    rows = dedupe_by_external_id(rows)

    image_set.update_columns(import_state: "inserting", import_total: rows.size, import_progress: 0)
    Image.bulk_insert_for_source!(image_set: image_set, rows: rows, source: "commons")
  end

  # === Probe + query plumbing ===

  def self.probes_for(region_resolved)
    return [ nil ] if region_resolved.nil?
    Geo::HexLattice.probes_for_bbox(region_resolved.bbox, radius_km: PROBE_RADIUS_KM, max_probes: 200)
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

  # Walks every probe in turn, paginating up to max_rows. Stops early
  # once max_rows reached. on_progress fires after each probe with
  # (done_probes, total_probes, rows_so_far).
  def self.collect_rows(commons_category:, intitle_fallback:, region_resolved:, max_rows:, on_progress: nil)
    probes = probes_for(region_resolved)
    rows = []

    probes.each_with_index do |probe, idx|
      break if rows.size >= max_rows
      remaining = max_rows - rows.size
      fetched = fetch_probe_rows(
        commons_category: commons_category, intitle_fallback: intitle_fallback,
        probe: probe, limit: [ remaining, PER_PROBE_HARD_CAP ].min
      )
      rows.concat(fetched)
      on_progress&.call(idx + 1, probes.size, rows.size)
    end
    rows
  end

  # Single probe → up to `limit` rows. Uses generator=search +
  # prop=imageinfo|coordinates to get URL+coord in one API hit.
  def self.fetch_probe_rows(commons_category:, intitle_fallback:, probe:, limit:)
    rows = []
    sroffset = 0
    srsearch = build_srsearch(commons_category: commons_category, intitle_fallback: intitle_fallback, probe: probe)

    while rows.size < limit
      batch_limit = [ limit - rows.size, PER_PROBE_HARD_CAP ].min
      params = {
        action: "query",
        generator: "search",
        gsrsearch: srsearch,
        gsrnamespace: 6,
        gsrlimit: batch_limit,
        gsroffset: sroffset,
        prop: "imageinfo|coordinates",
        iiprop: "url|extmetadata",
        iiurlwidth: THUMB_WIDTH,
        coprop: "type|name|country",
        format: "json", formatversion: 2
      }
      data = api_get(params)

      pages = data.dig("query", "pages") || []
      break if pages.empty?

      pages.each do |p|
        ii = (p["imageinfo"] || []).first
        coord = (p["coordinates"] || []).first
        next unless ii && coord

        url = ii["thumburl"].presence || ii["url"]
        next if url.blank?

        rows << {
          external_source: "commons",
          external_id: p["pageid"].to_s,
          url: url,
          title: p["title"].to_s.sub(/\AFile:/, ""),
          lat: coord["lat"].to_f,
          lng: coord["lon"].to_f,
          author: extract_author(ii.dig("extmetadata")),
          license: extract_license(ii.dig("extmetadata"))
        }
      end

      cont = data["continue"]
      break unless cont && cont["gsroffset"]
      sroffset = cont["gsroffset"].to_i
    end

    rows
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

  def self.api_get(params)
    uri = API.dup
    uri.query = URI.encode_www_form(params)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = USER_AGENT
      h.request(req)
    end
    raise Error, "Commons API HTTP #{res.code}: #{res.body.to_s.slice(0, 300)}" unless res.is_a?(Net::HTTPSuccess)
    JSON.parse(res.body)
  end
end
