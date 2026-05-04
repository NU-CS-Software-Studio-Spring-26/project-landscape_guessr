class Game < ApplicationRecord
  # Classic GeoGuessr per-round: round(5000 * exp(-distance_km / 1492.7))
  # 1492.7 is the world-map characteristic length in *kilometers*, not meters.
  GEOGUESSR_MAX_ROUND_SCORE = 5000
  GEOGUESSR_DECAY_KM = 1492.7

  belongs_to :user
  belongs_to :image_set, optional: true
  has_many :guesses, dependent: :destroy
  has_many :game_images, -> { order(:position) }, dependent: :destroy
  has_many :images, through: :game_images

  LEADERBOARD_SORTS = %w[score completed_at].freeze

  scope :leaderboard, ->(sort: "score", direction: "desc") {
    sort = "score" unless LEADERBOARD_SORTS.include?(sort)
    direction = direction == "asc" ? :asc : :desc
    joins(:image_set)
      .where(image_sets: { is_system_default: true })
      .where.not(completed_at: nil)
      .includes(:user)
      .order(sort => direction)
      .limit(20)
  }

  def self.geoguessr_round_score(distance_km)
    (GEOGUESSR_MAX_ROUND_SCORE * Math.exp(-distance_km / GEOGUESSR_DECAY_KM)).round.clamp(0, GEOGUESSR_MAX_ROUND_SCORE)
  end
end
