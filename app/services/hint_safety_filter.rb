# frozen_string_literal: true

class HintSafetyFilter
  MIN_TOKEN_LENGTH = 4

  def self.call(hint, image, tier:, location: nil)
    new(hint, image, tier: tier, location: location).call
  end

  def initialize(hint, image, tier:, location: nil)
    @hint = hint.to_s
    @image = image
    @tier = tier
    @location = location
  end

  def call
    return nil if @hint.blank?
    return @hint unless blocked?(@hint)

    nil
  end

  private

  def blocked?(text)
    normalized = text.downcase
    blocklist_terms.any? { |term| term.present? && normalized.include?(term.downcase) }
  end

  def blocklist_terms
    @blocklist_terms ||= title_tokens + location_terms
  end

  def title_tokens
    self.class.significant_tokens(@image.title)
  end

  def location_terms
    location = @location || HintLocationContext.for_image(@image)
    return [] unless location

    terms = location.locality_terms
    terms << location.region if @tier <= 2 && location.region.present?
    terms << location.country if @tier <= 2 && location.country.present?
    terms
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
