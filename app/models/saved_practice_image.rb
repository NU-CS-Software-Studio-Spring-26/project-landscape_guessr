class SavedPracticeImage < ApplicationRecord
  belongs_to :user
  belongs_to :image

  validates :image_id, uniqueness: { scope: :user_id }
end
