class Game < ApplicationRecord
  has_many :guesses, dependent: :destroy
  has_many :images, through: :guesses
end
