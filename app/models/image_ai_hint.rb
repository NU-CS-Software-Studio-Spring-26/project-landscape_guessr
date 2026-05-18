class ImageAiHint < ApplicationRecord
  STATUSES = %w[pending ready failed].freeze
  TIERS = (1..3).freeze
  PROMPT_VERSION = GeminiHintGenerator::PROMPT_VERSION

  belongs_to :image

  validates :tier, inclusion: { in: TIERS }
  validates :status, inclusion: { in: STATUSES }
  validates :tier, uniqueness: { scope: :image_id }

  scope :ready, -> { where(status: "ready") }
  scope :pending, -> { where(status: "pending") }
  scope :failed, -> { where(status: "failed") }
  scope :for_tier, ->(tier) { where(tier: tier) }
end
