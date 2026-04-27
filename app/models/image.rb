class Image < ApplicationRecord
  has_many :guesses, dependent: :destroy
  has_many :game_images, dependent: :destroy
end
