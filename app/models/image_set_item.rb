class ImageSetItem < ApplicationRecord
  belongs_to :image_set
  belongs_to :image

  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
  validates :image_id, uniqueness: { scope: :image_set_id, message: "already in this set" }

  delegate :title, :url, to: :image

  def answer_lat
    latitude&.to_f || image.latitude&.to_f
  end

  def answer_lng
    longitude&.to_f || image.longitude&.to_f
  end
end
