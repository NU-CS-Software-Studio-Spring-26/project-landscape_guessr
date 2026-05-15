require "net/http"
require "json"

namespace :regions do
  CONTINENT_CODE_MAP = {
    "AF" => "Africa",
    "AS" => "Asia",
    "EU" => "Europe",
    "NA" => "North America",
    "SA" => "South America",
    "OC" => "Oceania",
    "AN" => "Antarctica"
  }.freeze

  CONTINENT_GEOJSON_URL = "https://gist.githubusercontent.com/hrbrmstr/91ea5cc9474286c72838/raw/continents.json"

  CONTINENT_NAME_MAP = {
    "Asia" => "Asia",
    "North America" => "North America",
    "Europe" => "Europe",
    "Africa" => "Africa",
    "South America" => "South America",
    "Oceania" => "Oceania",
    "Australia" => "Oceania",
    "Antarctica" => "Antarctica"
  }.freeze

  # Buffer applied to continent polygons to catch coastal cities that fall just
  # outside the low-res hrbrmstr boundary (e.g., Miami, Lisbon, Reykjavik).
  # Empirically determined: 0.1° catches all major coastal cities tested without
  # introducing false positives between continents (no overlap in inland areas).
  CONTINENT_BUFFER_DEGREES = 0.1

  desc "Seed continent regions with boundaries"
  task seed_continents: :environment do
    puts "Seeding continents..."
    CONTINENT_CODE_MAP.each_value do |name|
      Region.find_or_create_by!(name: name, admin_level: "continent")
    end

    puts "  Fetching continent boundaries..."
    geojson = download_geojson(CONTINENT_GEOJSON_URL, "continents")
    factory = RGeo::Geographic.spherical_factory(srid: 4326)

    # Group features by our continent name (handles Australia + Oceania merging)
    by_name = Hash.new { |h, k| h[k] = [] }
    geojson["features"].each do |feature|
      our_name = CONTINENT_NAME_MAP[feature["properties"]["CONTINENT"] || feature["properties"]["continent"]]
      by_name[our_name] << feature["geometry"] if our_name
    end

    by_name.each do |our_name, geometries|
      region = Region.find_by(name: our_name, admin_level: "continent")
      next unless region

      # Decode all geoms, buffer each, then union into one MultiPolygon
      buffered = geometries.filter_map do |geom|
        g = RGeo::GeoJSON.decode(geom.to_json)
        next nil unless g
        g = g.make_valid rescue (g.buffer(0) rescue g)
        g.buffer(CONTINENT_BUFFER_DEGREES)
      end
      next if buffered.empty?

      merged = buffered.reduce { |acc, g| acc.union(g) rescue acc }
      region.update!(boundary: RGeo::GeoJSON.encode(merged))
    end

    Region.continents.where.not(boundary: nil).each do |r|
      bbox = Region.compute_bbox(r.boundary)
      r.update_columns(bbox) if bbox
    end

    puts "  #{Region.continents.count} continents (#{Region.continents.where.not(boundary: nil).count} with boundaries)"
  end

  desc "Seed countries from GeoNames countryInfo.txt"
  task seed_admin0: :environment do
    puts "Seeding admin0 (countries) from GeoNames..."
    cache_dir = Rails.root.join("tmp", "geoboundaries")
    FileUtils.mkdir_p(cache_dir)
    file = cache_dir.join("countryInfo.txt")

    unless file.exist?
      puts "  Downloading countryInfo.txt..."
      File.binwrite(file, fetch_with_redirects(URI("https://download.geonames.org/export/dump/countryInfo.txt")).body)
    end

    continent_lookup = CONTINENT_CODE_MAP.transform_values do |name|
      Region.find_by!(name: name, admin_level: "continent").id
    end

    lines = File.readlines(file, encoding: "UTF-8")
    seeded = 0

    lines.each do |line|
      next if line.start_with?("#") || line.strip.empty?
      fields = line.chomp.split("\t")
      # 0=ISO, 1=ISO3, 2=ISO-Numeric, 3=fips, 4=Country, 5=Capital, 6=Area, 7=Population, 8=Continent, ...
      iso2 = fields[0]
      iso3 = fields[1]
      name = fields[4]
      population = fields[7].to_i
      continent_code = fields[8]
      next unless iso2.present? && iso3.present? && name.present?

      parent_id = continent_lookup[continent_code]
      next unless parent_id

      region = Region.find_or_initialize_by(iso_code: iso3, admin_level: "country")
      region.assign_attributes(name: name, parent_id: parent_id, population: population)
      region.save!
      seeded += 1
    end

    puts "  Done: #{seeded} countries"
  end

  desc "Seed states/provinces from GeoNames admin1CodesASCII.txt"
  task seed_admin1: :environment do
    puts "Seeding admin1 (states/provinces) from GeoNames..."
    cache_dir = Rails.root.join("tmp", "geoboundaries")
    FileUtils.mkdir_p(cache_dir)
    file = cache_dir.join("admin1CodesASCII.txt")

    unless file.exist?
      puts "  Downloading admin1CodesASCII.txt..."
      File.binwrite(file, fetch_with_redirects(URI("https://download.geonames.org/export/dump/admin1CodesASCII.txt")).body)
    end

    # Map ISO2 -> country region
    country_by_iso2 = {}
    Region.countries.find_each do |c|
      iso2 = iso_a3_to_a2(c.iso_code)
      country_by_iso2[iso2] = c if iso2
    end
    puts "  #{country_by_iso2.size} countries available for parent lookup"

    lines = File.readlines(file, encoding: "UTF-8")
    seeded = 0
    skipped = 0

    lines.each do |line|
      fields = line.chomp.split("\t")
      code = fields[0]      # "US.MA"
      name = fields[1]      # "Massachusetts"
      next unless code && name.present?

      iso2 = code.split(".").first
      parent = country_by_iso2[iso2]
      unless parent
        skipped += 1
        next
      end

      region = Region.find_or_initialize_by(iso_code: code, admin_level: "admin1")
      region.assign_attributes(name: name, parent_id: parent.id)
      region.save!
      seeded += 1
    end

    puts "  Done: #{seeded} admin1 regions (#{skipped} skipped — no parent country)"
  end

  desc "Seed admin2 (counties/districts) from GeoNames admin2Codes.txt"
  task seed_admin2: :environment do
    puts "Seeding admin2 (counties/districts) from GeoNames..."

    cache_dir = Rails.root.join("tmp", "geoboundaries")
    FileUtils.mkdir_p(cache_dir)
    codes_file = cache_dir.join("admin2Codes.txt")

    unless codes_file.exist?
      puts "  Downloading admin2Codes.txt..."
      uri = URI("https://download.geonames.org/export/dump/admin2Codes.txt")
      File.binwrite(codes_file, fetch_with_redirects(uri).body)
    end

    # admin1.iso_code is now stored as GeoNames format "US.MA"
    admin1_by_code = Region.admin1s.where.not(iso_code: nil).index_by(&:iso_code)
    puts "  Built admin1 lookup with #{admin1_by_code.size} entries"

    lines = File.readlines(codes_file, encoding: "UTF-8")
    puts "  #{lines.size} admin2 codes to process..."

    batch = []
    seeded = 0
    skipped_no_parent = 0

    lines.each_with_index do |line, idx|
      fields = line.chomp.split("\t")
      code = fields[0]      # e.g., "US.MA.025"
      name = fields[1]      # e.g., "Norfolk County"
      next unless code && name.present?

      admin1_key = code.split(".").first(2).join(".")
      parent = admin1_by_code[admin1_key]
      unless parent
        skipped_no_parent += 1
        next
      end

      batch << {
        name: name,
        admin_level: "admin2",
        parent_id: parent.id,
        iso_code: code,
        created_at: Time.current,
        updated_at: Time.current
      }

      if batch.size >= 500
        Region.insert_all(batch)
        seeded += batch.size
        batch = []
        print "\r  #{seeded} admin2 seeded"
      end
    end

    Region.insert_all(batch) if batch.any?
    seeded += batch.size
    puts "\n  Done: #{seeded} admin2 regions (#{skipped_no_parent} skipped — no parent admin1)"
  end

  desc "Aggregate city populations and bboxes up to parent admin1/admin2"
  task aggregate_populations: :environment do
    puts "Aggregating populations and bboxes up to admin1/admin2..."

    # admin2: aggregate from children cities
    admin2_pop_sql = <<~SQL.squish
      UPDATE regions SET
        population = sub.total_pop,
        min_lat = sub.min_lat, max_lat = sub.max_lat,
        min_lng = sub.min_lng, max_lng = sub.max_lng
      FROM (
        SELECT parent_id,
               SUM(population) AS total_pop,
               MIN(min_lat) AS min_lat, MAX(max_lat) AS max_lat,
               MIN(min_lng) AS min_lng, MAX(max_lng) AS max_lng
        FROM regions
        WHERE admin_level = 'city'
        GROUP BY parent_id
      ) sub
      WHERE regions.id = sub.parent_id AND regions.admin_level = 'admin2'
    SQL
    ActiveRecord::Base.connection.execute(admin2_pop_sql)
    puts "  admin2 populations aggregated: #{Region.admin2s.where('population > 0').count}"

    # admin1: aggregate from children (cities + admin2)
    admin1_sql = <<~SQL.squish
      UPDATE regions SET
        population = sub.total_pop,
        min_lat = sub.min_lat, max_lat = sub.max_lat,
        min_lng = sub.min_lng, max_lng = sub.max_lng
      FROM (
        SELECT parent_id,
               SUM(population) AS total_pop,
               MIN(min_lat) AS min_lat, MAX(max_lat) AS max_lat,
               MIN(min_lng) AS min_lng, MAX(max_lng) AS max_lng
        FROM regions
        WHERE admin_level IN ('city', 'admin2') AND min_lat IS NOT NULL
        GROUP BY parent_id
      ) sub
      WHERE regions.id = sub.parent_id AND regions.admin_level = 'admin1'
    SQL
    ActiveRecord::Base.connection.execute(admin1_sql)
    puts "  admin1 populations aggregated: #{Region.admin1s.where('population > 0').count}"

    # country: aggregate bbox from admin1 children (population already from GeoNames)
    country_sql = <<~SQL.squish
      UPDATE regions SET
        min_lat = sub.min_lat, max_lat = sub.max_lat,
        min_lng = sub.min_lng, max_lng = sub.max_lng
      FROM (
        SELECT parent_id,
               MIN(min_lat) AS min_lat, MAX(max_lat) AS max_lat,
               MIN(min_lng) AS min_lng, MAX(max_lng) AS max_lng
        FROM regions
        WHERE admin_level = 'admin1' AND min_lat IS NOT NULL
        GROUP BY parent_id
      ) sub
      WHERE regions.id = sub.parent_id AND regions.admin_level = 'country'
    SQL
    ActiveRecord::Base.connection.execute(country_sql)
    puts "  country bboxes aggregated: #{Region.countries.where.not(min_lat: nil).count}"
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
    country_lookup = Region.countries.index_by(&:iso_code)
    admin1_by_code = Region.admin1s.where.not(iso_code: nil).index_by(&:iso_code)
    admin2_by_code = Region.admin2s.where.not(iso_code: nil).index_by(&:iso_code)

    lines = File.readlines(txt_file, encoding: "UTF-8")
    puts "  #{lines.size} cities in dataset"

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
      feature_code = fields[7]
      country_code_2 = fields[8]
      admin1_code = fields[10]
      admin2_code = fields[11]
      population = fields[14].to_i

      # Only seed actual populated places, not military bases, hospitals, etc.
      next unless %w[PPL PPLA PPLA2 PPLA3 PPLA4 PPLC PPLG PPLL PPLR].include?(feature_code)
      # cities1000.txt already filters to pop ≥ 1000 by definition. Reject the
      # ~12k entries with population=0 (GeoNames placeholder for "unknown" —
      # mostly stubs without real demographic data). Keeping pop=1000 cutoff
      # gives us ~136k cities including small towns like Dover, MA (pop 2265).
      next if population < 1000
      next if name.include?(",") || name.length > 50

      country_iso3 = iso_a2_to_a3(country_code_2)
      country = country_lookup[country_iso3]
      next unless country

      # Prefer admin2 as parent (more specific), fall back to admin1, then country
      admin2_key = "#{country_code_2}.#{admin1_code}.#{admin2_code}"
      admin1_key = "#{country_code_2}.#{admin1_code}"
      parent = admin2_by_code[admin2_key] || admin1_by_code[admin1_key]
      parent_id = parent&.id || country.id

      # No fake boundary — real polygon is fetched from Nominatim on first use.
      # Store the point as min_lat=max_lat=lat (and same for lng) so aggregation
      # to parent bboxes still works, and search distance ranking has something
      # to compare against.
      batch << {
        name: name,
        admin_level: "city",
        parent_id: parent_id,
        population: population,
        min_lat: lat, max_lat: lat,
        min_lng: lng, max_lng: lng,
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

  desc "Fetch Nominatim boundaries for all countries (~4 min, rate-limited)"
  task fetch_country_boundaries: :environment do
    puts "Fetching Nominatim boundaries for countries..."
    countries = Region.countries.order(:name)
    total = countries.count
    fetched = 0

    countries.each_with_index do |country, idx|
      if country.boundary.present?
        print "\r  #{idx + 1}/#{total} #{country.name} (cached)"
        next
      end

      result = country.fetch_real_boundary!
      fetched += 1 if result
      status = result ? "OK (#{country.boundary_coord_count} coords)" : "FAILED"
      print "\r  #{idx + 1}/#{total} #{country.name}: #{status}        "
    end
    puts "\n  Done: #{fetched} boundaries fetched"
  end

  # aggregate_populations is part of the chain — without it, admin1/admin2 rows
  # have NULL population, and Region.search's log10(pop) score ranks states
  # below their own cities. ("Massachusetts" search would return Boston before
  # the state row.)
  desc "Seed all region levels"
  task seed_all: [ :seed_continents, :seed_admin0, :seed_admin1, :seed_admin2, :seed_cities, :compute_bboxes, :aggregate_populations ]

  desc "Seed base levels only (continents + countries + states + cities)"
  task seed_base: [ :seed_continents, :seed_admin0, :seed_admin1, :seed_cities, :compute_bboxes, :aggregate_populations ]

  desc "Re-seed boundaries with current quality settings (clears cached GeoJSON, re-downloads)"
  task reseed: :environment do
    cache_dir = Rails.root.join("tmp", "geoboundaries")
    if cache_dir.exist?
      puts "Clearing cached GeoJSON files..."
      FileUtils.rm_rf(cache_dir)
    end
    puts "Running full reset + seed pipeline..."
    Rake::Task["regions:reset"].invoke
    Rake::Task["regions:seed_all"].invoke
  end

  desc "Reset all regions (destructive — clears regions table)"
  task reset: :environment do
    puts "Resetting all regions..."
    Region.delete_all
    puts "  Done"
  end

  private

  def iso_a3_to_a2(iso3)
    IsoCountryCodes.alpha2(iso3)
  end

  def iso_a2_to_a3(iso2)
    IsoCountryCodes.alpha3(iso2)
  end

  def compute_bbox(geometry)
    Region.compute_bbox(geometry)
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
