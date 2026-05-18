class Guess < ApplicationRecord
  belongs_to :game
  belongs_to :image

  validates :latitude,  presence: true, numericality: { greater_than_or_equal_to: -90,  less_than_or_equal_to: 90 }
  validates :longitude, presence: true, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  # One guess per (game, image): without this, a player who fires Submit twice
  # before the page redirects produces duplicate rows that the results view
  # then double-counts. Enforced at the model level only — DB unique index can
  # come later if we ever see contention.
  validates :image_id, uniqueness: { scope: :game_id }
end
