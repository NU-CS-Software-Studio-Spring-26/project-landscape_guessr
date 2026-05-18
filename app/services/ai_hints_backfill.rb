# frozen_string_literal: true

# Enqueues GenerateAiHintJob for located images (default set or SCOPE=all).
# Used by images:generate_ai_hints — not loaded during normal web requests.
class AiHintsBackfill
  class Disabled < StandardError; end

  Result = Data.define(:enqueued, :skipped)

  def self.run(tier:, limit: nil, sleep_seconds: 4, scope: nil)
    new(tier: tier, limit: limit, sleep_seconds: sleep_seconds, scope: scope).run
  end

  def initialize(tier:, limit:, sleep_seconds:, scope:)
    @tier = tier
    @limit = limit
    @sleep_seconds = sleep_seconds
    @scope = scope
  end

  def run
    raise Disabled, "Gemini AI hints are disabled (set AI_HINTS_ENABLED and GEMINI_API_KEY)" unless GeminiConfig.enabled?

    enqueued = 0
    skipped = 0

    images_scope.find_each do |image|
      hint = ImageAiHint.find_by(image_id: image.id, tier: @tier)

      if skip?(hint)
        skipped += 1
        next
      end

      GenerateAiHintJob.perform_later(image.id, @tier)
      enqueued += 1
      sleep(@sleep_seconds) if @sleep_seconds.positive?
    end

    Result.new(enqueued: enqueued, skipped: skipped)
  end

  def self.stats
    counts = ImageAiHint.group(:tier, :status).count
    ImageAiHint::TIERS.index_with do |tier|
      statuses = ImageAiHint::STATUSES.index_with { 0 }
      ImageAiHint::STATUSES.each do |status|
        statuses[status] = counts[[ tier, status ]] || 0
      end
      statuses
    end
  end

  private

  def skip?(hint)
    return true if hint&.status == "pending"
    return true if hint&.status == "ready" && hint.prompt_version == ImageAiHint::PROMPT_VERSION

    false
  end

  def images_scope
    located = Image.where.not(latitude: nil).where.not(longitude: nil)
    scope = use_all_located_images? ? located : located_in_default_set(located)
    scope = scope.order(:id)
    @limit ? scope.limit(@limit) : scope
  end

  def use_all_located_images?
    @scope.to_s == "all" || ENV["SCOPE"].to_s == "all"
  end

  def located_in_default_set(located)
    default_set = ImageSet.default
    return Image.none unless default_set

    located.joins(:image_set_items)
           .where(image_set_items: { image_set_id: default_set.id })
           .distinct
  end
end
