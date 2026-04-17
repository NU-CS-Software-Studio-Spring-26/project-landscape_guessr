require "net/http"
require "uri"
require "json"

LANDFORM_TYPES = %w[
  Q8502 Q23397 Q34038 Q8072 Q150784 Q23442 Q35666 Q39816
  Q4022 Q45776 Q107679 Q40080 Q185113 Q39594
]
PER_TYPE_LIMIT = 100
CONCURRENCY    = 5

NON_PHOTO_PATTERNS = [
  /ASTER|MODIS|Landsat|LANDSAT|Sentinel|MISR|Messtischblatt/i,
  /_map[._]|location[_\s-]map|relief[_\s-]map/i,
  /topographic|schematic|Harper.?s[_\s-]New/i,
]

fetch_type = lambda do |qid|
  sparql = <<~SPARQL
    SELECT ?item ?itemLabel ?image ?coord WHERE {
      ?item wdt:P31 wd:#{qid} ; wdt:P18 ?image ; wdt:P625 ?coord .
      BIND(SHA512(CONCAT(STR(RAND()), STR(?item))) AS ?r)
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
    } ORDER BY ?r LIMIT #{PER_TYPE_LIMIT}
  SPARQL

  uri = URI("https://query.wikidata.org/sparql")
  req = Net::HTTP::Post.new(uri)
  req["Accept"]       = "application/sparql-results+json"
  req["Content-Type"] = "application/x-www-form-urlencoded"
  req["User-Agent"]   = "landscape-guessr seed script"
  req.body = URI.encode_www_form(query: sparql)

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(req) }
  raise "Wikidata #{res.code} for #{qid}: #{res.body[0, 200]}" unless res.code == "200"
  JSON.parse(res.body).dig("results", "bindings") || []
end

puts "Fetching #{LANDFORM_TYPES.size} landform types in parallel (#{CONCURRENCY} at a time, #{PER_TYPE_LIMIT} each)..."
start = Time.now
bindings = LANDFORM_TYPES.each_slice(CONCURRENCY).flat_map do |batch|
  batch.map { |qid| Thread.new { fetch_type.call(qid) } }.map(&:value).flatten
end
puts "Received #{bindings.size} records in #{(Time.now - start).round(1)}s, inserting..."

skipped_non_photo = 0
before = Image.count
bindings.each do |b|
  coord = b.dig("coord", "value")
  match = coord && coord.match(/Point\(([-\d.]+)\s+([-\d.]+)\)/)
  next unless match
  lng, lat = match[1].to_f, match[2].to_f

  url = b.dig("image", "value")&.sub(/\Ahttp:/, "https:")
  next if url.blank? || url.length > 500
  next unless url.match?(/\.jpe?g\z/i)
  if NON_PHOTO_PATTERNS.any? { |p| url.match?(p) }
    skipped_non_photo += 1
    next
  end

  title = b.dig("itemLabel", "value").presence || "Untitled"
  Image.find_or_create_by!(url: url) do |img|
    img.latitude  = lat
    img.longitude = lng
    img.title     = title
  end
end

puts "Created #{Image.count - before} new images (#{Image.count} total); skipped #{skipped_non_photo} non-photos"
