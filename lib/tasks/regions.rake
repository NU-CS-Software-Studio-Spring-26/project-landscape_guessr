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

  desc "Download and seed geoBoundaries admin0 (countries)"
  task seed_admin0: :environment do
    puts "Seeding admin0 (countries)..."
    url = "https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/CGAZ/geoBoundariesCGAZ_ADM0.geojson"
    geojson = download_geojson(url, "admin0")

    continent_map = {}
    CONTINENT_COUNTRIES.each do |continent_name, codes|
      continent = Region.find_by!(name: continent_name, admin_level: "continent")
      codes.each { |c| continent_map[c] = continent.id }
    end

    features = geojson["features"]
    puts "  Processing #{features.size} countries..."

    features.each_with_index do |feature, idx|
      props = feature["properties"]
      iso = props["shapeISO"] || props["ISO_A3"] || props["shapeName"]
      name = props["shapeName"]
      next unless name.present?

      parent_id = continent_map[iso]

      region = Region.find_or_initialize_by(iso_code: iso, admin_level: "country")
      region.assign_attributes(
        name: name,
        parent_id: parent_id,
        boundary: feature["geometry"]
      )
      region.save!

      print "\r  #{idx + 1}/#{features.size} countries processed"
    end
    puts "\n  Done: #{Region.countries.count} countries"
  end

  desc "Download and seed geoBoundaries admin1 (states/provinces)"
  task seed_admin1: :environment do
    puts "Seeding admin1 (states/provinces)..."
    url = "https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/CGAZ/geoBoundariesCGAZ_ADM1.geojson"
    geojson = download_geojson(url, "admin1")

    country_lookup = Region.countries.index_by(&:iso_code)

    features = geojson["features"]
    puts "  Processing #{features.size} admin1 regions..."

    features.each_with_index do |feature, idx|
      props = feature["properties"]
      name = props["shapeName"]
      country_iso = props["shapeISO"]&.slice(0, 3) || props["ADM0_ISO"]
      iso_code = props["shapeISO"]
      next unless name.present?

      parent = country_lookup[country_iso]
      next unless parent

      region = Region.find_or_initialize_by(name: name, admin_level: "admin1", parent_id: parent.id)
      region.assign_attributes(
        iso_code: iso_code,
        boundary: feature["geometry"]
      )
      region.save!

      print "\r  #{idx + 1}/#{features.size}" if (idx % 100).zero?
    end
    puts "\n  Done: #{Region.admin1s.count} admin1 regions"
  end

  desc "Download and seed geoBoundaries admin2 (counties/districts)"
  task seed_admin2: :environment do
    puts "Seeding admin2 (counties/districts)..."
    url = "https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/CGAZ/geoBoundariesCGAZ_ADM2.geojson"
    geojson = download_geojson(url, "admin2")

    admin1_lookup = Region.admin1s.select(:id, :name, :parent_id).group_by(&:parent_id)

    features = geojson["features"]
    puts "  Processing #{features.size} admin2 regions..."

    features.each_with_index do |feature, idx|
      props = feature["properties"]
      name = props["shapeName"]
      admin1_name = props["ADM1_NAME"] || props["shapeGroup"]
      country_iso = props["shapeISO"]&.slice(0, 3) || props["ADM0_ISO"]
      next unless name.present?

      country = Region.find_by(iso_code: country_iso, admin_level: "country")
      next unless country

      candidates = admin1_lookup[country.id] || []
      parent = candidates.find { |r| r.name == admin1_name }
      parent ||= candidates.first

      next unless parent

      region = Region.find_or_initialize_by(name: name, admin_level: "admin2", parent_id: parent.id)
      region.assign_attributes(boundary: feature["geometry"])
      region.save!

      print "\r  #{idx + 1}/#{features.size}" if (idx % 500).zero?
    end
    puts "\n  Done: #{Region.admin2s.count} admin2 regions"
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

  desc "Seed all region levels"
  task seed_all: [ :seed_continents, :seed_admin0, :seed_admin1, :seed_admin2, :compute_bboxes ]

  desc "Tag all images with their containing regions"
  task tag_images: :environment do
    puts "Tagging images with regions..."
    factory = RGeo::Geographic.spherical_factory(srid: 4326)

    regions_with_geom = Region.where.not(boundary: nil).map do |r|
      geom = RGeo::GeoJSON.decode(r.boundary.to_json)
      [ r, geom ] if geom
    end.compact

    puts "  Loaded #{regions_with_geom.size} region geometries"

    images = Image.where.not(latitude: nil).where.not(longitude: nil)
    total = images.count
    puts "  Processing #{total} images..."

    tagged = 0
    images.find_each(batch_size: 200).with_index do |image, idx|
      point = factory.point(image.longitude.to_f, image.latitude.to_f)

      matching_ids = regions_with_geom.filter_map do |region, geom|
        region.id if geom.contains?(point)
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
      puts "  Using cached #{label} data from #{cache_file}"
      return JSON.parse(File.read(cache_file))
    end

    puts "  Downloading #{label} from #{url}..."
    uri = URI(url)
    response = fetch_with_redirects(uri)
    File.write(cache_file, response.body)
    puts "  Saved to #{cache_file} (#{(response.body.bytesize / 1024.0 / 1024).round(1)} MB)"
    JSON.parse(response.body)
  end

  def fetch_with_redirects(uri, limit = 5)
    raise "Too many redirects" if limit == 0

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 300

    request = Net::HTTP::Get.new(uri)
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
