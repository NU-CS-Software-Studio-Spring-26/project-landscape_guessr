class Game < ApplicationRecord
  belongs_to :user
  has_many :guesses, dependent: :destroy
  has_many :game_images, -> { order(:position) }, dependent: :destroy
  has_many :images, through: :game_images

  scope :leaderboard, -> { where.not(completed_at: nil).includes(:user).order(score: :desc, completed_at: :asc).limit(20) }
end
