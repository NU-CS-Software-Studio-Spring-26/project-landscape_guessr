# frozen_string_literal: true

# User-facing copy for failed AI hint rows (PracticeController#hint).
class AiHintPublicError
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

    "Couldn't generate an AI hint right now. Try again.#{CREDITS_NOTE}"
  end

  def self.gemini_quota_exceeded?(message)
    message.include?("429") ||
      message.match?(/rate.?limit|resource_exhausted|quota|billing|limit exceeded|exhausted/i)
  end
end
