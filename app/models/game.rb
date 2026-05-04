class Game < ApplicationRecord
  belongs_to :user
  has_many :guesses, dependent: :destroy
  has_many :game_images, -> { order(:position) }, dependent: :destroy
  has_many :images, through: :game_images

  LEADERBOARD_SORTS = %w[score completed_at].freeze

  scope :leaderboard, ->(sort: "score", direction: "asc") {
    sort = "score" unless LEADERBOARD_SORTS.include?(sort)
    direction = direction == "desc" ? :desc : :asc
    where.not(completed_at: nil).includes(:user).order(sort => direction).limit(20)
  }
end
