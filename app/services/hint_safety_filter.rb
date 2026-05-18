# frozen_string_literal: true

class HintSafetyFilter
  MIN_TOKEN_LENGTH = 4

  Rejection = Data.define(:kind, :matched_terms) do
    def geographic?
      kind == :geographic
    end

    def feedback_message
      terms = matched_terms.join(", ")
      if geographic?
        <<~MSG.squish
          Your previous hint was rejected because it named or revealed geographic
          location (#{terms}). Do not name or imply the continent, country, region,
          city, town, or any landmark. Reply with only a new hint sentence that
          follows all rules.
        MSG
      else
        <<~MSG.squish
          Your previous hint was rejected because it referenced forbidden place names
          (#{terms}). Reply with only a new hint sentence that follows all rules.
        MSG
      end
    end
  end

  def self.call(hint, image, tier:, location: nil)
    new(hint, image, tier: tier, location: location).call
  end

  def self.rejection(hint, image, tier:, location: nil)
    new(hint, image, tier: tier, location: location).rejection
  end

  def initialize(hint, image, tier:, location: nil)
    @hint = hint.to_s
    @image = image
    @tier = tier
    @location = location
  end

  def call
    return nil if @hint.blank?
    return @hint unless rejection

    nil
  end

  def rejection
    return nil if @hint.blank?

    matched = matched_blocklist_terms(@hint)
    return nil if matched.empty?

    kind = (matched & geographic_blocklist_terms).any? ? :geographic : :title
    Rejection.new(kind: kind, matched_terms: matched)
  end

  private

  def matched_blocklist_terms(text)
    normalized = text.downcase
    blocklist_terms.filter_map do |term|
      term if term.present? && normalized.include?(term.downcase)
    end
  end

  def blocklist_terms
    @blocklist_terms ||= title_tokens + geographic_blocklist_terms
  end

  def geographic_blocklist_terms
    @geographic_blocklist_terms ||= location_geographic_terms + locality_terms
  end

  def title_tokens
    self.class.significant_tokens(@image.title)
  end

  def locality_terms
    location = resolved_location
    return [] unless location

    location.locality_terms
  end

  def location_geographic_terms
    location = resolved_location
    return [] unless location

    [ location.continent, location.country, location.region ].compact
  end

  def resolved_location
    @location || HintLocationContext.for_image(@image)
  end

  class << self
    def significant_tokens(title)
      return [] if title.blank?

      title
        .split(/[^[:alnum:]]+/)
        .map { |token| token.downcase }
        .select { |token| token.length >= MIN_TOKEN_LENGTH }
        .uniq
    end
  end
end
