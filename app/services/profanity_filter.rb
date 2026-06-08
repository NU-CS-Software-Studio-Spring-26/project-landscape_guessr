# Lightweight profanity filter for user-generated text (image titles, set names,
# usernames). Uses the `obscenity` gem for detection.
#
# Usage:
#   ProfanityFilter.clean?("Hello world")  # => true
#   ProfanityFilter.clean?("f**k this")    # => false
#
# If the obscenity gem is not available (e.g. during a migration before bundle
# is updated), falls back gracefully to allowing everything and logs a warning.
class ProfanityFilter
  def self.clean?(text)
    return true if text.blank?

    require "obscenity"
    !Obscenity.profane?(text.to_s)
  rescue LoadError
    Rails.logger.warn("[ProfanityFilter] obscenity gem not loaded — skipping filter")
    true
  end
end
