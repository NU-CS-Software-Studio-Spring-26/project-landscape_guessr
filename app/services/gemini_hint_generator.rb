# frozen_string_literal: true

require "net/http"
require "json"

class GeminiHintGenerator
  PROMPT_VERSION = 5
  API_HOST = "generativelanguage.googleapis.com"

  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error; end
  class RetryableError < ApiError; end

  NEVER_IN_HINT = <<~RULES.squish
    Never name or spell out specific landmark names, exact street addresses, or readable
    place names. Do not quote or reference any image title or filename.
  RULES

  PLAIN_LANGUAGE = <<~RULES.squish
    Write in plain, simple English that anyone can understand quickly. Use everyday words,
    one short sentence, and no jargon, metaphors, wordplay, or complicated phrasing.
  RULES

  def self.generate(image:, tier:, location:)
    new(image: image, tier: tier, location: location).generate
  end

  def initialize(image:, tier:, location:)
    @image = image
    @tier = tier
    @location = location
  end

  def generate
    raise ConfigurationError, "Gemini API is not configured" unless GeminiConfig.enabled?
    raise ApiError, "Location context is required for hint generation" if @location.blank?

    response = request_generate_content
    extract_text(response)
  end

  private

  def request_generate_content
    uri = URI::HTTPS.build(
      host: API_HOST,
      path: "/v1beta/models/#{GeminiConfig.model}:generateContent",
      query: URI.encode_www_form(key: GeminiConfig.api_key)
    )

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(request_body)

    response = http.request(request)
    handle_response(response)
  end

  def request_body
    {
      contents: [
        {
          parts: [
            { text: prompt_for_tier(@tier) }
          ]
        }
      ]
    }
  end

  # Prompt uses geocoded location text only — never image.title, filename, or coordinates.
  def prompt_for_tier(tier)
    intensity =
      case tier
      when 1
        <<~TIER.squish
          Give one short, subtle hint that is highly specific to this place yet understandable
          from common knowledge (typical school geography, widely known culture, famous foods,
          animals, exports, or stereotypes a general audience would recognize). Pick a niche,
          distinctive clue — not vague scenery like "mountainous" or "green hills." Do not use
          obscure trivia, academic jargon, or references only locals would know. Do not name the
          country, region, city, or any landmark.
        TIER
      when 2
        <<~TIER.squish
          Give one medium-strength hint using cultural, historical, folklore, food, or
          geographic references strongly associated with this place (for example, a
          well-known children's story character for Switzerland, or a famous dish for
          Italy) without naming the country, region, city, or any landmark.
        TIER
      when 3
        <<~TIER.squish
          Give one stronger hint that may name the country or continent, but still do not
          name any city, town, region, landmark, or street.
        TIER
      else
        raise ArgumentError, "tier must be 1, 2, or 3"
      end

    <<~PROMPT.strip
      You help a geography photo guessing game. The player is guessing where a landscape photo
      was taken. You are given text location data only — no photograph. Base the hint entirely
      on the location facts below.

      #{location_prompt_section}

      #{intensity}
      #{PLAIN_LANGUAGE}
      #{NEVER_IN_HINT}
      Reply with only the hint sentence, no preamble.
    PROMPT
  end

  def location_prompt_section
    lines = HintLocationContext.to_prompt_lines(@location)

    <<~SECTION.strip
      Location data (for your reasoning only — obey the tier rules for what may appear in the hint):
      #{lines}
    SECTION
  end

  def handle_response(response)
    code = response.code.to_i
    body = response.body.to_s

    if code == 429 || code >= 500
      raise RetryableError, "Gemini HTTP #{code}: #{truncate(body)}"
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise ApiError, "Gemini HTTP #{code}: #{truncate(body)}"
    end

    JSON.parse(body)
  rescue JSON::ParserError => e
    raise ApiError, "Gemini returned invalid JSON: #{e.message}"
  end

  def extract_text(payload)
    parts = payload.dig("candidates", 0, "content", "parts") || []
    text = parts.filter_map { |part| part["text"] }.join.strip
    raise ApiError, "Gemini response contained no hint text" if text.blank?

    text
  end

  def truncate(text, max = 200)
    text.length > max ? "#{text[0, max]}..." : text
  end
end
