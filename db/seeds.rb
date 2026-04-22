require "net/http"
require "uri"
require "json"

LANDFORM_TYPES = %w[
  Q8502 Q23397 Q34038 Q8072 Q150784 Q23442 Q35666 Q39816
  Q4022 Q45776 Q107679 Q40080 Q185113 Q39594
]
SAMPLE_POOL    = 2000  # how many items bd:sample pulls per type before filtering
PER_TYPE_LIMIT = 100

NON_PHOTO_PATTERNS = [
  /ASTER|MODIS|Landsat|LANDSAT|Sentinel|MISR|Messtischblatt/i,
  /_map[._]|location[_\s-]map|relief[_\s-]map/i,
  /topographic|schematic|Harper.?s[_\s-]New/i
]

subqueries = LANDFORM_TYPES.map do |qid|
  <<~SUB.strip
    { SELECT ?item ?image ?coord WHERE {
        SERVICE bd:sample {
          ?item wdt:P31 wd:#{qid} .
          bd:serviceParam bd:sample.limit #{SAMPLE_POOL} .
          bd:serviceParam bd:sample.sampleType "RANDOM" .
        }
        ?item wdt:P18 ?image ; wdt:P625 ?coord .
      } LIMIT #{PER_TYPE_LIMIT} }
  SUB
end

sparql = <<~SPARQL
  SELECT ?item ?itemLabel ?image ?coord WHERE {
    #{subqueries.join(" UNION ")}
    SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
  }
SPARQL

uri = URI("https://query.wikidata.org/sparql")
req = Net::HTTP::Post.new(uri)
req["Accept"]       = "application/sparql-results+json"
req["Content-Type"] = "application/x-www-form-urlencoded"
req["User-Agent"]   = "landscape-guessr seed script"
req.body = URI.encode_www_form(query: sparql)

puts "Fetching #{LANDFORM_TYPES.size} landform types (true random via bd:sample)..."
start = Time.now
response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(req) }
raise "Wikidata returned #{response.code}: #{response.body[0, 200]}" unless response.code == "200"
bindings = JSON.parse(response.body).dig("results", "bindings") || []
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
