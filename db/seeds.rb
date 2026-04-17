require "net/http"
require "uri"
require "json"

LANDFORM_TYPES = %w[
  Q8502 Q23397 Q34038 Q8072 Q150784 Q23442 Q35666 Q39816
  Q4022 Q45776 Q107679 Q40080 Q185113 Q39594
]
PER_TYPE_LIMIT = 100

subqueries = LANDFORM_TYPES.map do |qid|
  "{ SELECT ?item ?image ?coord WHERE { ?item wdt:P31 wd:#{qid} ; wdt:P18 ?image ; wdt:P625 ?coord . } LIMIT #{PER_TYPE_LIMIT} }"
end

sparql = <<~SPARQL
  SELECT ?item ?itemLabel ?image ?coord WHERE {
    #{subqueries.join(" UNION ")}
    SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
  }
SPARQL

uri = URI("https://query.wikidata.org/sparql")
uri.query = URI.encode_www_form(query: sparql)

puts "Fetching #{LANDFORM_TYPES.size} landform types x #{PER_TYPE_LIMIT} from Wikidata..."
req = Net::HTTP::Get.new(uri)
req["Accept"] = "application/sparql-results+json"
req["User-Agent"] = "landscape-guessr seed script"

response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 90) do |http|
  http.request(req)
end

raise "Wikidata returned #{response.code}: #{response.body[0, 200]}" unless response.code == "200"

bindings = JSON.parse(response.body).dig("results", "bindings") || []
puts "Received #{bindings.size} records, inserting..."

before = Image.count
bindings.each do |b|
  coord = b.dig("coord", "value")
  match = coord && coord.match(/Point\(([-\d.]+)\s+([-\d.]+)\)/)
  next unless match
  lng, lat = match[1].to_f, match[2].to_f

  url = b.dig("image", "value")&.sub(/\Ahttp:/, "https:")
  next if url.blank? || url.length > 500
  title = b.dig("itemLabel", "value").presence || "Untitled"

  Image.find_or_create_by!(url: url) do |img|
    img.latitude  = lat
    img.longitude = lng
    img.title     = title
  end
end

puts "Created #{Image.count - before} new images (#{Image.count} total)"
