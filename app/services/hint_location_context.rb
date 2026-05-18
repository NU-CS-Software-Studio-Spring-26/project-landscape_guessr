# frozen_string_literal: true

# Reverse-geocodes image coordinates for server-side hint generation only.
# Never expose this struct to practice clients.
class HintLocationContext
  Location = Data.define(:country, :country_code, :region, :city, :continent, :latitude_band) do
    def present?
      [ country, region, city, continent, latitude_band ].any?(&:present?)
    end

    def locality_terms
      [ city ].compact
    end
  end

  CONTINENT_BY_COUNTRY_CODE = {
    "CH" => "Europe",
    "AT" => "Europe",
    "DE" => "Europe",
    "FR" => "Europe",
    "IT" => "Europe",
    "US" => "North America",
    "CA" => "North America",
    "JP" => "Asia",
    "AU" => "Oceania",
    "NZ" => "Oceania"
  }.freeze

  NOMINATIM_ADDRESS_KEYS = {
    country: "country",
    country_code: "country_code",
    region: %w[state region],
    city: %w[city town village municipality]
  }.freeze

  def self.for_image(image)
    for_coordinates(image.latitude, image.longitude)
  end

  def self.for_coordinates(latitude, longitude)
    new(latitude, longitude).resolve
  end

  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
  end

  def resolve
    return nil if @latitude.blank? || @longitude.blank?

    address = fetch_address
    return nil if address.blank?

    country_code = address["country_code"].to_s.upcase.presence
    continent = CONTINENT_BY_COUNTRY_CODE[country_code] if country_code

    Location.new(
      country: address["country"].presence,
      country_code: country_code,
      region: first_present(address, NOMINATIM_ADDRESS_KEYS[:region]),
      city: first_present(address, NOMINATIM_ADDRESS_KEYS[:city]),
      continent: continent,
      latitude_band: self.class.latitude_band(@latitude)
    )
  end

  def self.latitude_band(latitude)
    lat = latitude.to_f
    case lat
    when 66.5.. then "High northern latitudes"
    when 23.5...66.5 then "Northern mid-latitudes"
    when -23.5...23.5 then "Tropics or subtropics"
    when -66.5...-23.5 then "Southern mid-latitudes"
    else "High southern latitudes"
    end
  end

  def self.to_prompt_lines(location)
    return nil unless location&.present?

    lines = []
    lines << "Climate band: #{location.latitude_band}" if location.latitude_band.present?
    lines << "Continent: #{location.continent}" if location.continent.present?
    lines << "Country: #{location.country}" if location.country.present?
    lines << "Region: #{location.region}" if location.region.present?
    lines << "City or town: #{location.city}" if location.city.present?
    lines.join("\n")
  end

  private

  def fetch_address
    uri = URI("https://nominatim.openstreetmap.org/reverse")
    uri.query = URI.encode_www_form(
      lat: @latitude,
      lon: @longitude,
      format: "jsonv2",
      "accept-language": "en"
    )

    data = Region.nominatim_request(uri)
    return nil unless data.is_a?(Hash)

    data["address"]
  rescue StandardError => e
    Rails.logger.warn "[HintLocationContext] geocode failed: #{e.message}"
    nil
  end

  def first_present(hash, keys)
    Array(keys).each do |key|
      value = hash[key]
      return value if value.present?
    end
    nil
  end
end
