require "net/http"
require "json"

namespace :regions do
  CONTINENT_COUNTRIES = {
    "Africa" => %w[DZA AGO BEN BWA BFA BDI CPV CMR CAF TCD COM COD COG CIV DJI EGY GNQ ERI SWZ ETH GAB GMB GHA GIN GNB KEN LSO LBR LBY MDG MWI MLI MRT MUS MAR MOZ NAM NER NGA RWA STP SEN SYC SLE SOM ZAF SSD SDN TZA TGO TUN UGA ZMB ZWE],
    "Asia" => %w[AFG ARM AZE BHR BGD BTN BRN KHM CHN CYP GEO IND IDN IRN IRQ ISR JPN JOR KAZ KWT KGZ LAO LBN MYS MDV MNG MMR NPL PRK OMN PAK PSE PHL QAT SAU SGP KOR LKA SYR TWN TJK THA TLS TUR TKM ARE UZB VNM YEM],
    "Europe" => %w[ALB AND AUT BLR BEL BIH BGR HRV CZE DNK EST FIN FRA DEU GRC HUN ISL IRL ITA XKX LVA LIE LTU LUX MLT MDA MCO MNE NLD MKD NOR POL PRT ROU RUS SMR SRB SVK SVN ESP SWE CHE UKR GBR VAT],
    "North America" => %w[ATG BHS BRB BLZ CAN CRI CUB DMA DOM SLV GRD GTM HTI HND JAM MEX NIC PAN KNA LCA VCT TTO USA],
    "South America" => %w[ARG BOL BRA CHL COL ECU GUY PRY PER SUR URY VEN],
    "Oceania" => %w[AUS FJI KIR MHL FSM NRU NZL PLW PNG WSM SLB TON TUV VUT],
    "Antarctica" => %w[ATA]
  }.freeze

  desc "Seed continent regions"
  task seed_continents: :environment do
    puts "Seeding continents..."
    CONTINENT_COUNTRIES.each_key do |name|
      Region.find_or_create_by!(name: name, admin_level: "continent")
    end
    puts "  #{Region.continents.count} continents"
  end

  desc "Seed countries from Natural Earth 10m"
  task seed_admin0: :environment do
    puts "Seeding admin0 (countries) from Natural Earth..."
    url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_countries.geojson"
    geojson = download_geojson(url, "ne_admin0")

    continent_map = {}
    CONTINENT_COUNTRIES.each do |continent_name, codes|
      continent = Region.find_by!(name: continent_name, admin_level: "continent")
      codes.each { |c| continent_map[c] = continent.id }
    end

    features = geojson["features"]
    puts "  Processing #{features.size} countries..."

    features.each_with_index do |feature, idx|
      props = feature["properties"]
      iso = props["ISO_A3"] || props["ADM0_A3"]
      name = props["NAME"] || props["ADMIN"]
      next unless name.present? && iso.present? && iso != "-99"

      parent_id = continent_map[iso]
      geometry = simplify_geometry(feature["geometry"], 0.01)

      region = Region.find_or_initialize_by(iso_code: iso, admin_level: "country")
      region.assign_attributes(name: name, parent_id: parent_id, boundary: geometry)
      region.save!

      print "\r  #{idx + 1}/#{features.size}" if ((idx + 1) % 10).zero?
    end
    puts "\n  Done: #{Region.countries.count} countries"
  end

  desc "Seed states/provinces from Natural Earth 10m"
  task seed_admin1: :environment do
    puts "Seeding admin1 (states/provinces) from Natural Earth..."
    url = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_1_states_provinces.geojson"
    geojson = download_geojson(url, "ne_admin1")

    country_lookup = Region.countries.index_by(&:iso_code)

    features = geojson["features"]
    puts "  Processing #{features.size} admin1 regions..."

    features.each_with_index do |feature, idx|
      props = feature["properties"]
      name = props["name"] || props["NAME"]
      country_iso = props["iso_a2"] ? iso_a2_to_a3(props["iso_a2"]) : props["adm0_a3"]
      iso_code = props["iso_3166_2"]
      next unless name.present?

      parent = country_lookup[country_iso]
      next unless parent

      geometry = simplify_geometry(feature["geometry"], 0.01)

      region = Region.find_or_initialize_by(name: name, admin_level: "admin1", parent_id: parent.id)
      region.assign_attributes(iso_code: iso_code, boundary: geometry)
      region.save!

      print "\r  #{idx + 1}/#{features.size}" if ((idx + 1) % 100).zero?
    end
    puts "\n  Done: #{Region.admin1s.count} admin1 regions"
  end

  desc "Seed admin2 (counties/districts) from geoBoundaries per-country"
  task seed_admin2: :environment do
    puts "Seeding admin2 (counties/districts)..."
    puts "  Fetching geoBoundaries ADM2 index..."

    index_url = "https://www.geoboundaries.org/api/current/gbOpen/ALL/ADM2/"
    index_resp = fetch_with_redirects(URI(index_url))
    index_data = JSON.parse(index_resp.body)
    puts "  Found #{index_data.size} countries with ADM2 data"

    countries_with_images = Region.countries
      .joins(children: { image_regions: {} })
      .distinct
      .pluck(:iso_code)
      .compact

    relevant_entries = index_data.select { |e| countries_with_images.include?(e["boundaryISO"]) }
    puts "  Filtering to #{relevant_entries.size} countries with tagged images..."

    relevant_entries.each_with_index do |entry, country_idx|
      iso = entry["boundaryISO"]
      download_url = entry["gjDownloadURL"]
      next unless download_url.present?

      country = Region.find_by(iso_code: iso, admin_level: "country")
      next unless country

      existing_admin2_count = Region.where(admin_level: "admin2")
        .joins("JOIN regions AS parents ON regions.parent_id = parents.id")
        .where("parents.parent_id = ?", country.id)
        .count
      if existing_admin2_count > 0
        print "\r  [#{country_idx + 1}/#{relevant_entries.size}] #{iso}: already seeded (#{existing_admin2_count} regions)"
        next
      end

      begin
        geojson = download_geojson(download_url, "admin2_#{iso}")
        features = geojson["features"]
        admin1_lookup = Region.where(admin_level: "admin1", parent_id: country.id).to_a

        features.each do |feature|
          props = feature["properties"]
          name = props["shapeName"]
          next unless name.present?

          parent = admin1_lookup.first
          geometry = simplify_geometry(feature["geometry"], 0.02)

          region = Region.find_or_initialize_by(name: name, admin_level: "admin2", parent_id: parent&.id || country.id)
          region.assign_attributes(boundary: geometry)
          region.save!
        end

        print "\r  [#{country_idx + 1}/#{relevant_entries.size}] #{iso}: #{features.size} admin2 regions"
      rescue => e
        puts "\n  Warning: Failed to seed admin2 for #{iso}: #{e.message}"
      end
    end
    puts "\n  Done: #{Region.admin2s.count} total admin2 regions"
  end

  desc "Compute bounding boxes for all regions"
  task compute_bboxes: :environment do
    puts "Computing bounding boxes..."
    regions = Region.where.not(boundary: nil).where(min_lat: nil)
    total = regions.count
    puts "  #{total} regions to process..."

    regions.find_each(batch_size: 500).with_index do |region, idx|
      bbox = compute_bbox(region.boundary)
      region.update_columns(bbox) if bbox
      print "\r  #{idx + 1}/#{total}" if ((idx + 1) % 200).zero?
    end
    puts "\n  Done"
  end

  desc "Seed cities from GeoNames cities1000 dataset"
  task seed_cities: :environment do
    puts "Seeding cities from GeoNames..."
    url = "https://download.geonames.org/export/dump/cities1000.zip"
    cache_dir = Rails.root.join("tmp", "geoboundaries")
    FileUtils.mkdir_p(cache_dir)
    zip_file = cache_dir.join("cities1000.zip")
    txt_file = cache_dir.join("cities1000.txt")

    unless txt_file.exist?
      puts "  Downloading cities1000.zip..."
      uri = URI(url)
      response = fetch_with_redirects(uri)
      File.binwrite(zip_file, response.body)
      puts "  Extracting..."
      system("unzip", "-o", zip_file.to_s, "-d", cache_dir.to_s)
    end

    puts "  Reading cities..."
    admin1_lookup = Region.where(admin_level: "admin1").select(:id, :name, :iso_code, :parent_id).to_a
    country_lookup = Region.countries.index_by(&:iso_code)

    # Build admin1 lookup by country ISO + admin1 code
    admin1_by_country = {}
    admin1_lookup.each do |a1|
      next unless a1.iso_code.present?
      # iso_code format: "US-CA", so extract country part
      country_part = a1.iso_code.split("-").first
      admin1_by_country[a1.iso_code] = a1
    end

    # Also group admin1s by parent (country) id
    admin1_by_parent = admin1_lookup.group_by(&:parent_id)

    lines = File.readlines(txt_file, encoding: "UTF-8")
    puts "  #{lines.size} cities in dataset"

    # Only seed cities in countries that have tagged images
    countries_with_images = ImageRegion.joins(:region)
      .where(regions: { admin_level: "country" })
      .distinct
      .pluck("regions.iso_code")

    batch = []
    seeded = 0
    skipped = 0

    lines.each_with_index do |line, idx|
      fields = line.chomp.split("\t")
      # GeoNames fields: 0=geonameid, 1=name, 2=asciiname, 3=alternatenames,
      # 4=latitude, 5=longitude, 6=feature_class, 7=feature_code,
      # 8=country_code(2), 9=cc2, 10=admin1_code, 11=admin2_code,
      # 12=admin3_code, 13=admin4_code, 14=population, 15=elevation,
      # 16=dem, 17=timezone, 18=modification_date
      name = fields[1]
      lat = fields[4].to_f
      lng = fields[5].to_f
      country_code_2 = fields[8]
      admin1_code = fields[10]
      population = fields[14].to_i

      country_iso3 = iso_a2_to_a3(country_code_2)
      next unless countries_with_images.include?(country_iso3)
      next if population < 5000 # Only cities with 5k+ population

      country = country_lookup[country_iso3]
      next unless country

      # Find parent admin1
      iso_3166_2 = "#{country_code_2}-#{admin1_code}"
      parent = admin1_by_country[iso_3166_2]
      parent ||= begin
        candidates = admin1_by_parent[country.id] || []
        candidates.first
      end
      parent_id = parent&.id || country.id

      # Create a small circular polygon around the city center
      # Radius based on population (bigger city = bigger area)
      radius_km = city_radius_km(population)
      boundary = circle_polygon(lat, lng, radius_km)

      batch << {
        name: name,
        admin_level: "city",
        parent_id: parent_id,
        boundary: boundary,
        min_lat: lat - (radius_km / 111.0),
        max_lat: lat + (radius_km / 111.0),
        min_lng: lng - (radius_km / (111.0 * Math.cos(lat * Math::PI / 180))),
        max_lng: lng + (radius_km / (111.0 * Math.cos(lat * Math::PI / 180))),
        created_at: Time.current,
        updated_at: Time.current
      }

      if batch.size >= 500
        Region.insert_all(batch)
        seeded += batch.size
        batch = []
        print "\r  #{seeded} cities seeded (#{idx + 1}/#{lines.size} processed)"
      end
    end

    Region.insert_all(batch) if batch.any?
    seeded += batch.size

    puts "\n  Done: #{Region.where(admin_level: 'city').count} cities seeded"
  end

  desc "Seed all region levels"
  task seed_all: [ :seed_continents, :seed_admin0, :seed_admin1, :seed_admin2, :seed_cities, :compute_bboxes ]

  desc "Seed base levels only (continents + countries + states + cities)"
  task seed_base: [ :seed_continents, :seed_admin0, :seed_admin1, :seed_cities, :compute_bboxes ]

  desc "Tag all images with their containing regions"
  task tag_images: :environment do
    puts "Tagging images with regions..."
    factory = RGeo::Geographic.spherical_factory(srid: 4326)

    # Load non-city regions into memory (they're small enough)
    non_city_regions = Region.where.not(boundary: nil).where.not(admin_level: "city").filter_map do |r|
      geom = RGeo::GeoJSON.decode(r.boundary.to_json)
      next nil unless geom
      geom = geom.make_valid rescue (geom.buffer(0) rescue geom)
      [ r, geom ]
    end
    puts "  Loaded #{non_city_regions.size} non-city region geometries"

    images = Image.where.not(latitude: nil).where.not(longitude: nil)
    total = images.count
    puts "  Processing #{total} images..."

    tagged = 0
    images.find_each(batch_size: 200).with_index do |image, idx|
      lat = image.latitude.to_f
      lng = image.longitude.to_f
      point = factory.point(lng, lat)

      # Check non-city regions (in memory)
      matching_ids = non_city_regions.filter_map do |region, geom|
        region.id if geom.contains?(point)
      rescue
        nil
      end

      # Check cities using bbox pre-filter (SQL)
      city_candidates = Region.where(admin_level: "city")
        .where("min_lat <= ? AND max_lat >= ? AND min_lng <= ? AND max_lng >= ?", lat, lat, lng, lng)

      city_candidates.each do |city|
        geom = RGeo::GeoJSON.decode(city.boundary.to_json)
        matching_ids << city.id if geom&.contains?(point)
      rescue
        nil
      end

      existing_ids = image.image_regions.pluck(:region_id)
      new_ids = matching_ids - existing_ids

      if new_ids.any?
        ImageRegion.insert_all(
          new_ids.map { |rid| { image_id: image.id, region_id: rid, created_at: Time.current, updated_at: Time.current } }
        )
        tagged += new_ids.size
      end

      print "\r  #{idx + 1}/#{total} images (#{tagged} tags created)" if ((idx + 1) % 50).zero?
    end
    puts "\n  Done: #{ImageRegion.count} total image-region associations"
  end

  desc "Reset all regions (destructive - clears regions and image_regions tables)"
  task reset: :environment do
    puts "Resetting all regions..."
    ImageRegion.delete_all
    Region.delete_all
    puts "  Done"
  end

  private

  def city_radius_km(population)
    case population
    when 0..10_000 then 8
    when 10_001..50_000 then 12
    when 50_001..200_000 then 18
    when 200_001..1_000_000 then 25
    when 1_000_001..5_000_000 then 35
    else 50
    end
  end

  def circle_polygon(lat, lng, radius_km, segments = 16)
    coords = (0..segments).map do |i|
      angle = (2 * Math::PI * i) / segments
      dlat = (radius_km / 111.0) * Math.sin(angle)
      dlng = (radius_km / (111.0 * Math.cos(lat * Math::PI / 180))) * Math.cos(angle)
      [ (lng + dlng).round(5), (lat + dlat).round(5) ]
    end
    { "type" => "Polygon", "coordinates" => [ coords ] }
  end

  def simplify_geometry(geometry, tolerance)
    return geometry unless geometry.is_a?(Hash)
    return geometry if tolerance <= 0

    case geometry["type"]
    when "Polygon"
      simplified_coords = geometry["coordinates"].map { |ring| douglas_peucker(ring, tolerance) }
      simplified_coords.reject! { |ring| ring.size < 4 }
      return nil if simplified_coords.empty?
      { "type" => "Polygon", "coordinates" => simplified_coords }
    when "MultiPolygon"
      simplified_polys = geometry["coordinates"].map do |polygon|
        rings = polygon.map { |ring| douglas_peucker(ring, tolerance) }
        rings.reject! { |ring| ring.size < 4 }
        rings.empty? ? nil : rings
      end.compact
      return nil if simplified_polys.empty?
      { "type" => "MultiPolygon", "coordinates" => simplified_polys }
    else
      geometry
    end
  end

  def douglas_peucker(points, tolerance)
    return points if points.size <= 2

    max_dist = 0
    max_idx = 0
    first = points.first
    last = points.last

    (1...points.size - 1).each do |i|
      dist = perpendicular_distance(points[i], first, last)
      if dist > max_dist
        max_dist = dist
        max_idx = i
      end
    end

    if max_dist > tolerance
      left = douglas_peucker(points[0..max_idx], tolerance)
      right = douglas_peucker(points[max_idx..], tolerance)
      left[0...-1] + right
    else
      [ first, last ]
    end
  end

  def perpendicular_distance(point, line_start, line_end)
    dx = line_end[0] - line_start[0]
    dy = line_end[1] - line_start[1]
    if dx == 0 && dy == 0
      Math.sqrt((point[0] - line_start[0])**2 + (point[1] - line_start[1])**2)
    else
      ((dy * point[0] - dx * point[1] + line_end[0] * line_start[1] - line_end[1] * line_start[0]).abs /
        Math.sqrt(dx**2 + dy**2))
    end
  end

  def iso_a2_to_a3(iso2)
    return nil unless iso2
    mapping = {
      "AF" => "AFG", "AL" => "ALB", "DZ" => "DZA", "AD" => "AND", "AO" => "AGO", "AG" => "ATG",
      "AR" => "ARG", "AM" => "ARM", "AU" => "AUS", "AT" => "AUT", "AZ" => "AZE", "BS" => "BHS",
      "BH" => "BHR", "BD" => "BGD", "BB" => "BRB", "BY" => "BLR", "BE" => "BEL", "BZ" => "BLZ",
      "BJ" => "BEN", "BT" => "BTN", "BO" => "BOL", "BA" => "BIH", "BW" => "BWA", "BR" => "BRA",
      "BN" => "BRN", "BG" => "BGR", "BF" => "BFA", "BI" => "BDI", "CV" => "CPV", "KH" => "KHM",
      "CM" => "CMR", "CA" => "CAN", "CF" => "CAF", "TD" => "TCD", "CL" => "CHL", "CN" => "CHN",
      "CO" => "COL", "KM" => "COM", "CG" => "COG", "CD" => "COD", "CR" => "CRI", "CI" => "CIV",
      "HR" => "HRV", "CU" => "CUB", "CY" => "CYP", "CZ" => "CZE", "DK" => "DNK", "DJ" => "DJI",
      "DM" => "DMA", "DO" => "DOM", "EC" => "ECU", "EG" => "EGY", "SV" => "SLV", "GQ" => "GNQ",
      "ER" => "ERI", "EE" => "EST", "SZ" => "SWZ", "ET" => "ETH", "FJ" => "FJI", "FI" => "FIN",
      "FR" => "FRA", "GA" => "GAB", "GM" => "GMB", "GE" => "GEO", "DE" => "DEU", "GH" => "GHA",
      "GR" => "GRC", "GD" => "GRD", "GT" => "GTM", "GN" => "GIN", "GW" => "GNB", "GY" => "GUY",
      "HT" => "HTI", "HN" => "HND", "HU" => "HUN", "IS" => "ISL", "IN" => "IND", "ID" => "IDN",
      "IR" => "IRN", "IQ" => "IRQ", "IE" => "IRL", "IL" => "ISR", "IT" => "ITA", "JM" => "JAM",
      "JP" => "JPN", "JO" => "JOR", "KZ" => "KAZ", "KE" => "KEN", "KI" => "KIR", "KP" => "PRK",
      "KR" => "KOR", "KW" => "KWT", "KG" => "KGZ", "LA" => "LAO", "LV" => "LVA", "LB" => "LBN",
      "LS" => "LSO", "LR" => "LBR", "LY" => "LBY", "LI" => "LIE", "LT" => "LTU", "LU" => "LUX",
      "MG" => "MDG", "MW" => "MWI", "MY" => "MYS", "MV" => "MDV", "ML" => "MLI", "MT" => "MLT",
      "MH" => "MHL", "MR" => "MRT", "MU" => "MUS", "MX" => "MEX", "FM" => "FSM", "MD" => "MDA",
      "MC" => "MCO", "MN" => "MNG", "ME" => "MNE", "MA" => "MAR", "MZ" => "MOZ", "MM" => "MMR",
      "NA" => "NAM", "NR" => "NRU", "NP" => "NPL", "NL" => "NLD", "NZ" => "NZL", "NI" => "NIC",
      "NE" => "NER", "NG" => "NGA", "MK" => "MKD", "NO" => "NOR", "OM" => "OMN", "PK" => "PAK",
      "PW" => "PLW", "PS" => "PSE", "PA" => "PAN", "PG" => "PNG", "PY" => "PRY", "PE" => "PER",
      "PH" => "PHL", "PL" => "POL", "PT" => "PRT", "QA" => "QAT", "RO" => "ROU", "RU" => "RUS",
      "RW" => "RWA", "KN" => "KNA", "LC" => "LCA", "VC" => "VCT", "WS" => "WSM", "SM" => "SMR",
      "ST" => "STP", "SA" => "SAU", "SN" => "SEN", "RS" => "SRB", "SC" => "SYC", "SL" => "SLE",
      "SG" => "SGP", "SK" => "SVK", "SI" => "SVN", "SB" => "SLB", "SO" => "SOM", "ZA" => "ZAF",
      "SS" => "SSD", "ES" => "ESP", "LK" => "LKA", "SD" => "SDN", "SR" => "SUR", "SE" => "SWE",
      "CH" => "CHE", "SY" => "SYR", "TW" => "TWN", "TJ" => "TJK", "TZ" => "TZA", "TH" => "THA",
      "TL" => "TLS", "TG" => "TGO", "TO" => "TON", "TT" => "TTO", "TN" => "TUN", "TR" => "TUR",
      "TM" => "TKM", "TV" => "TUV", "UG" => "UGA", "UA" => "UKR", "AE" => "ARE", "GB" => "GBR",
      "US" => "USA", "UY" => "URY", "UZ" => "UZB", "VU" => "VUT", "VE" => "VEN", "VN" => "VNM",
      "YE" => "YEM", "ZM" => "ZMB", "ZW" => "ZWE", "XK" => "XKX"
    }
    mapping[iso2.upcase]
  end

  def compute_bbox(geometry)
    coords = extract_all_coords(geometry)
    return nil if coords.empty?

    lats = coords.map { |c| c[1] }
    lngs = coords.map { |c| c[0] }
    { min_lat: lats.min, max_lat: lats.max, min_lng: lngs.min, max_lng: lngs.max }
  end

  def extract_all_coords(geometry)
    return [] unless geometry.is_a?(Hash)

    case geometry["type"]
    when "Polygon"
      geometry["coordinates"].flatten(1)
    when "MultiPolygon"
      geometry["coordinates"].flatten(2)
    else
      []
    end
  end

  def download_geojson(url, label)
    cache_dir = Rails.root.join("tmp", "geoboundaries")
    FileUtils.mkdir_p(cache_dir)
    cache_file = cache_dir.join("#{label}.geojson")

    if cache_file.exist?
      puts "  Using cached #{label} data" unless label.start_with?("admin2_")
      return JSON.parse(File.read(cache_file))
    end

    puts "  Downloading #{label}..." unless label.start_with?("admin2_")
    uri = URI(url)
    response = fetch_with_redirects(uri)
    body = response.body.force_encoding("UTF-8")
    File.write(cache_file, body)
    JSON.parse(body)
  end

  def fetch_with_redirects(uri, limit = 10)
    raise "Too many redirects" if limit == 0

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 300
    http.open_timeout = 30

    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "LandscapeGuessr/1.0 (region-seeder)"
    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response
    when Net::HTTPRedirection
      fetch_with_redirects(URI(response["location"]), limit - 1)
    else
      raise "HTTP #{response.code}: #{response.message}"
    end
  end
end
