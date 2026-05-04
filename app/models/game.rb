class Game < ApplicationRecord
  # Classic GeoGuessr per-round: round(5000 * exp(-distance_m / 1492.7))
  GEOGUESSR_MAX_ROUND_SCORE = 5000
  GEOGUESSR_DECAY_METERS = 1492.7

  belongs_to :user
  has_many :guesses, dependent: :destroy
  has_many :game_images, -> { order(:position) }, dependent: :destroy
  has_many :images, through: :game_images

  scope :leaderboard, -> { where.not(completed_at: nil).includes(:user).order(score: :desc, completed_at: :asc).limit(20) }

  def self.geoguessr_round_score(distance_km)
    metres = distance_km * 1000.0
    (GEOGUESSR_MAX_ROUND_SCORE * Math.exp(-metres / GEOGUESSR_DECAY_METERS)).round.clamp(0, GEOGUESSR_MAX_ROUND_SCORE)
  end
end
