# Validates user prompts for AI image-set generation before they are
# stored or sent to Gemini. Keeps input bounded, strips unsafe content,
# and blocks profanity.
class AiPromptValidator
  MAX_LENGTH = 250

  # Control chars except tab / LF / CR.
  DISALLOWED_CONTROL = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/.freeze
  # Zero-width and bidi override chars (homograph / smuggling tricks).
  DISALLOWED_INVISIBLE = /[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/.freeze
  DISALLOWED_MARKUP = /<[^>]+>|javascript\s*:/i.freeze

  PROFANITY_WORDS = %w[
    asshole bastard bitch bollocks bullshit cock cunt damn dick
    fag faggot fuck fucker fucking goddamn hell motherfucker
    nigger piss pussy shit shitty slut twat wanker whore
  ].freeze

  PROFANITY_PATTERN = /\b(?:#{PROFANITY_WORDS.map { |w| Regexp.escape(w) }.join("|")})\b/i.freeze

  Result = Struct.new(:ok?, :text, :error, keyword_init: true)

  def self.validate(text)
    new(text).validate
  end

  def initialize(text)
    @text = text.to_s.strip
  end

  def validate
    return fail("Type a prompt first.") if @text.empty?
    return fail("Prompt must be at most #{MAX_LENGTH} characters.") if @text.length > MAX_LENGTH
    return fail("Prompt contains invalid characters.") if @text.match?(DISALLOWED_CONTROL)
    return fail("Prompt contains invalid characters.") if @text.match?(DISALLOWED_INVISIBLE)
    return fail("Prompt cannot contain HTML or script markup.") if @text.match?(DISALLOWED_MARKUP)
    return fail("Please keep your prompt family-friendly.") if profane?(@text)

    Result.new(ok?: true, text: @text)
  end

  private

  def fail(message)
    Result.new(ok?: false, error: message)
  end

  def profane?(text)
    normalized = normalize_for_profanity(text)
    normalized.match?(PROFANITY_PATTERN)
  end

  # Light leetspeak normalization so obvious obfuscations still match.
  def normalize_for_profanity(text)
    text.downcase
        .tr("@4", "aa")
        .tr("3", "e")
        .tr("1!", "ii")
        .tr("0", "o")
        .tr("$5", "ss")
        .tr("7", "t")
        .gsub(/[^a-z\s]/, " ")
        .squeeze(" ")
        .strip
  end
end
