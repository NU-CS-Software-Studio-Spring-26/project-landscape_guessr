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

def normalize_longitude(value)
  return nil if value.nil?
  # Wrap values from [180, 540], etc. into the valid [-180, 180] range.
  ((value + 180.0) % 360.0) - 180.0
end

def valid_latitude?(value)
  !value.nil? && value >= -90.0 && value <= 90.0
end

def valid_longitude?(value)
  !value.nil? && value >= -180.0 && value <= 180.0
end

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
skipped_bad_coords = 0
before = Image.count
bindings.each do |b|
  coord = b.dig("coord", "value")
  match = coord && coord.match(/Point\(([-\d.]+)\s+([-\d.]+)\)/)
  unless match
    skipped_bad_coords += 1
    next
  end
  lng = normalize_longitude(match[1].to_f)
  lat = match[2].to_f
  unless valid_latitude?(lat) && valid_longitude?(lng)
    skipped_bad_coords += 1
    next
  end

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

puts "Created #{Image.count - before} new images (#{Image.count} total); skipped #{skipped_non_photo} non-photos; rejected #{skipped_bad_coords} for coordinate issues"

# Ensure every Image is linked into the default set
default_set = ImageSet.find_or_create_by!(is_system_default: true) do |s|
  s.name = "Default Landscapes"
  s.visibility = "public"
end

linked = 0
Image.find_each do |img|
  item = default_set.image_set_items.find_or_initialize_by(image: img)
  if item.new_record?
    lat = img.latitude&.to_f
    lng = normalize_longitude(img.longitude&.to_f)
    item.latitude  = valid_latitude?(lat) ? lat : nil
    item.longitude = valid_longitude?(lng) ? lng : nil
    item.save!
    linked += 1
  end
end
puts "Linked #{linked} new images into default set (#{default_set.image_set_items.count} total)"

# Demo users + sample games so the local dev leaderboard isn't empty.
#
# Only seed these in development — committing real passwords to the public
# repo and re-using them in production would mean anyone could log into
# the deployed app as alice/bob/charlie. Real admin elevation in any env
# is done via console: User.find_by(email_address: "...").update!(admin: true)
if Rails.env.development?
  DEMO_USERS = [
    { email_address: "alice@example.com",   username: "alice",   password: "password123" },
    { email_address: "bob@example.com",     username: "bob",     password: "password123" },
    { email_address: "charlie@example.com", username: "charlie", password: "password123" }
  ]

  demo_user_records = DEMO_USERS.map do |attrs|
    user = User.find_or_initialize_by(email_address: attrs[:email_address])
    if user.new_record?
      user.username = attrs[:username]
      user.password = attrs[:password]
      user.save!
      puts "Created demo user #{attrs[:username]}"
    end
    user
  end

  # Give each demo user 1-2 completed games on the default set so the leaderboard
  # has something to show. Seeded games use real images from the default set and
  # real guesses, with scores computed via the same scoring formula the app uses.
  if default_set.image_set_items.count >= 5
    demo_user_records.each do |user|
      next if user.games.where.not(completed_at: nil).exists?

      rand(1..2).times do
        Game.transaction do
          game = user.games.create!(status: "in_progress", image_set: default_set)
          items = default_set.image_set_items.includes(:image).order("RANDOM()").limit(5)
          total_score = 0
          items.each_with_index do |item, idx|
            gi = game.game_images.create!(
              image_id: item.image_id, position: idx + 1,
              answer_latitude: item.latitude || item.image.latitude,
              answer_longitude: item.longitude || item.image.longitude
            )
            ans_lat = gi.answer_lat
            ans_lng = gi.answer_lng
            # Demo guesses scattered: half the time they're close, half random.
            if rand < 0.5
              guess_lat = ans_lat + rand(-3.0..3.0)
              guess_lng = ans_lng + rand(-3.0..3.0)
            else
              guess_lat = rand(-60.0..70.0)
              guess_lng = rand(-180.0..180.0)
            end
            game.guesses.create!(image_id: item.image_id, latitude: guess_lat, longitude: guess_lng)
            total_score += Game.geoguessr_round_score(Game.haversine_km(guess_lat, guess_lng, ans_lat, ans_lng))
          end
          game.update!(status: "completed", score: total_score, completed_at: Time.current - rand(0..14).days)
        end
      end
      puts "Seeded #{user.games.where.not(completed_at: nil).count} demo game(s) for #{user.username}"
    end
  else
    puts "Skipping demo games — default set has fewer than 5 images"
  end
else
  puts "Skipping demo users + games (only seeded in development)"
end
