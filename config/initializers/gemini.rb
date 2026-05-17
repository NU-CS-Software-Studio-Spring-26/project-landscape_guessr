# frozen_string_literal: true

# Optional Gemini API configuration for AI practice hints (Phase 0+).
# Missing GEMINI_API_KEY does not prevent boot; use GeminiConfig.enabled? before calling the API.
module GeminiConfig
  DEFAULT_MODEL = "gemini-2.5-flash-lite"

  module_function

  def api_key
    ENV["GEMINI_API_KEY"].presence
  end

  def model
    ENV.fetch("GEMINI_MODEL", DEFAULT_MODEL)
  end

  def enabled?
    ai_hints_enabled? && api_key.present?
  end

  def ai_hints_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["AI_HINTS_ENABLED"]) == true
  end
end
