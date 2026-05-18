# frozen_string_literal: true

# User-facing copy for failed AI hint rows (PracticeController#hint).
class AiHintPublicError
  UNAVAILABLE_MESSAGE = "AI hints are unavailable at the moment; we're fixing the issue."

  CREDITS_NOTE = " This may also mean today's AI hint credits are used up (Google Gemini free tier)."

  QUOTA_MESSAGE = <<~MSG.squish
    AI hints are unavailable right now — the Gemini API rate limit or free-tier
    credits may be used up. Try again later.
  MSG

  def self.message(raw_error_message)
    message = raw_error_message.to_s
    return "Couldn't generate an AI hint for this image.#{CREDITS_NOTE}" if message.blank?
    return QUOTA_MESSAGE if gemini_quota_exceeded?(message)

    if message.match?(/no coordinates|geocode/i)
      return "This image has no location data for AI hints."
    end

    if message.include?("safety filter")
      return "Couldn't produce a safe hint for this image. Try another tier."
    end

    return UNAVAILABLE_MESSAGE if gemini_service_unavailable?(message)

    "Couldn't generate an AI hint right now. Try again.#{CREDITS_NOTE}"
  end

  def self.gemini_service_unavailable?(message)
    text = message.to_s
    return false if text.blank?
    return false if gemini_quota_exceeded?(text)

    return true if text.start_with?("Gemini HTTP") || text.include?("Gemini returned invalid JSON")
    return true if text.match?(/timeout|timed out|connection|socket|ssl|unreachable|getaddrinfo/i)

    false
  end

  def self.gemini_quota_exceeded?(message)
    message.include?("429") ||
      message.match?(/rate.?limit|resource_exhausted|quota|billing|limit exceeded|exhausted/i)
  end
end
