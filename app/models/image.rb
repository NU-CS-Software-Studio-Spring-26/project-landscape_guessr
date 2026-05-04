class Image < ApplicationRecord
  has_one_attached :photo
  has_many :guesses, dependent: :destroy
  has_many :game_images, dependent: :destroy
  has_many :image_set_items, dependent: :destroy
  has_many :image_sets, through: :image_set_items
end
