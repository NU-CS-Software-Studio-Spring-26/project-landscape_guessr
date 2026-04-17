class Image < ApplicationRecord
  has_many :guesses, dependent: :destroy
end
