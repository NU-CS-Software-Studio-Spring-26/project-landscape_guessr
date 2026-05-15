# One round-trip of the AI-image-set generator: a user prompt (plus any
# prior conversation) → an AI-generated SPARQL pattern, with the count
# and a preview sample populated as the AiGenerationJob progresses.
#
# Decoupled from ImageSet on purpose: a generation is just the AI's
# proposal. The user reviews the preview and, if they like it, hits
# "Import" — only THEN does an ImageSet get created.
class AiGeneration < ApplicationRecord
  belongs_to :user

  STATUSES = %w[pending running completed failed].freeze
  PHASES   = %w[thinking counting sampling].freeze

  validates :status, inclusion: { in: STATUSES }

  # If a job dies mid-run, the record sits as `running` forever. After
  # this much wall time with no update, the status endpoint reports it
  # as failed so the UI can recover instead of polling indefinitely.
  STALE_AFTER = 5.minutes

  def stale?
    %w[pending running].include?(status) && updated_at < STALE_AFTER.ago
  end

  def in_progress?
    %w[pending running].include?(status) && !stale?
  end

  # JSON accessors. Round-trip the text columns through JSON so the
  # rest of the app can use plain hashes/arrays. Empty/garbage data
  # degrades to empty rather than 500ing the page. Each accessor
  # enforces the expected shape — without that, a value like
  # `"\"oops\""` parses to a String, and the view's `.each` blows up.
  def conversation
    val = parse_json(conversation_json)
    val.is_a?(Array) ? val : []
  end

  def result
    val = parse_json(result_json)
    val.is_a?(Hash) ? val : nil
  end

  def preview
    val = parse_json(preview_json)
    val.is_a?(Array) ? val : []
  end

  private

  def parse_json(raw)
    return nil if raw.blank?
    JSON.parse(raw, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end
