class Game < ApplicationRecord
  # Classic GeoGuessr per-round: round(5000 * exp(-distance_km / 1492.7))
  # 1492.7 is the world-map characteristic length in *kilometers*, not meters.
  GEOGUESSR_MAX_ROUND_SCORE = 5000
  GEOGUESSR_DECAY_KM = 1492.7

  belongs_to :user
  belongs_to :image_set, optional: true
  belongs_to :challenge, optional: true
  has_many :guesses, dependent: :destroy
  has_many :game_images, -> { order(:position) }, dependent: :destroy
  has_many :images, through: :game_images

  LEADERBOARD_SORTS = %w[score completed_at duration_seconds].freeze
  LEADERBOARD_PERIODS = %w[week month year all].freeze

  scope :leaderboard, ->(image_set:, sort: "score", direction: "desc", period: "all") {
    sort = "score" unless LEADERBOARD_SORTS.include?(sort)
    direction = direction == "asc" ? :asc : :desc
    period = "all" unless LEADERBOARD_PERIODS.include?(period)

    cutoff = case period
    when "week"  then 1.week.ago
    when "month" then 1.month.ago
    when "year"  then 1.year.ago
    end

    rel = where(image_set: image_set)
            .where.not(completed_at: nil)
            .includes(:user)
    rel = rel.where(completed_at: cutoff..) if cutoff
    rel.order(sort => direction).limit(20)
  }

  # `decay_km` is the characteristic length of the exponential score curve.
  # Defaults to the classic world value, but callers pass a per-set decay
  # (see ImageSet#scoring_decay_km) so a geographically small set is scored
  # on its own scale instead of everyone landing near 5000.
  def self.geoguessr_round_score(distance_km, decay_km: GEOGUESSR_DECAY_KM)
    (GEOGUESSR_MAX_ROUND_SCORE * Math.exp(-distance_km / decay_km)).round.clamp(0, GEOGUESSR_MAX_ROUND_SCORE)
  end

  # Great-circle distance in kilometers via the Haversine formula. Used
  # by GamesController#results and PracticeController#check; the
  # client-side JS in game_controller.js implements the same formula
  # for the in-round "X km away" readout.
  def self.haversine_km(lat1, lon1, lat2, lon2)
    rad = Math::PI / 180
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad
    a = Math.sin(dlat / 2)**2 +
        Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2)**2
    6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end
end
