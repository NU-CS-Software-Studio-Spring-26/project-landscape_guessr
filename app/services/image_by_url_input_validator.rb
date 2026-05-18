# Validates params for adding an image to a set by URL (ImageSetsController#add_image).
# Kept out of the Image model so legacy rows without coordinates or with
# http URLs are not invalidated on save.
class ImageByUrlInputValidator
  MAX_URL_LENGTH = 500
  TITLE_MAX_LENGTH = ImageSet::NAME_MAX_LENGTH

  Result = Struct.new(:ok?, :url, :title, :latitude, :longitude, :error, keyword_init: true)

  def self.validate(params)
    new(params).validate
  end

  def initialize(params)
    @url = params[:url].to_s.strip
    @title = params[:title].to_s.strip
    @latitude_raw = params[:latitude]
    @longitude_raw = params[:longitude]
  end

  def validate
    return fail("Please enter an image URL.") if @url.empty?
    return fail("URL must be at most #{MAX_URL_LENGTH} characters.") if @url.length > MAX_URL_LENGTH
    return fail("Image URL must start with https://.") unless @url.match?(/\Ahttps:\/\//i)
    return fail("Image URL is not valid.") unless safe_https_url?

    if @title.present?
      return fail("Title must be at most #{TITLE_MAX_LENGTH} characters.") if @title.length > TITLE_MAX_LENGTH
      return fail("Title #{ImageSet::NAME_FORMAT_MESSAGE}.") unless @title.match?(ImageSet::NAME_ALLOWED_PATTERN)
    end
    title = @title.presence || "Untitled"

    latitude = parse_coordinate(@latitude_raw, min: -90, max: 90, label: "Latitude")
    return fail(latitude) if latitude.is_a?(String)

    longitude = parse_coordinate(@longitude_raw, min: -180, max: 180, label: "Longitude")
    return fail(longitude) if longitude.is_a?(String)

    return fail("Latitude and longitude are required.") if latitude.nil? || longitude.nil?

    Result.new(
      ok?:       true,
      url:       @url,
      title:     title,
      latitude:  latitude,
      longitude: longitude
    )
  end

  private

    def fail(message)
      Result.new(ok?: false, error: message)
    end

    def safe_https_url?
      uri = URI.parse(@url)
      uri.is_a?(URI::HTTPS) && uri.host.present?
    rescue URI::InvalidURIError
      false
    end

    # Returns Float on success, or an error message String.
    def parse_coordinate(raw, min:, max:, label:)
      return nil if raw.blank?

      text = raw.to_s.strip
      unless text.match?(/\A-?\d+(?:\.\d+)?\z/)
        return "#{label} must be a number."
      end

      value = text.to_f
      unless value.finite? && value >= min && value <= max
        return "#{label} must be between #{min} and #{max}."
      end

      value
    end
end
