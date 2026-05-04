class Game < ApplicationRecord
  belongs_to :user
  belongs_to :image_set, optional: true
  has_many :guesses, dependent: :destroy
  has_many :game_images, -> { order(:position) }, dependent: :destroy
  has_many :images, through: :game_images

  scope :leaderboard, -> {
    joins(:image_set)
      .where(image_sets: { is_system_default: true })
      .where.not(completed_at: nil)
      .includes(:user)
      .order(:score, :completed_at)
      .limit(20)
  }
end
