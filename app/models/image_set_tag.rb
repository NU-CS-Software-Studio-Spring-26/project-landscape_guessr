class ImageSetTag < ApplicationRecord
  belongs_to :image_set
  belongs_to :tag

  validates :tag_id, uniqueness: { scope: :image_set_id }
end
