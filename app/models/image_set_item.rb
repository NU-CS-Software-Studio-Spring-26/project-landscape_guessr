class ImageSetItem < ApplicationRecord
  belongs_to :image_set
  belongs_to :image

  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
  validates :image_id, uniqueness: { scope: :image_set_id, message: "already in this set" }

  after_destroy :purge_image_if_orphan

  delegate :title, :url, to: :image

  def answer_lat
    latitude&.to_f || image.latitude&.to_f
  end

  def answer_lng
    longitude&.to_f || image.longitude&.to_f
  end

  private

  # When the last set membership goes away, destroy the Image too so the
  # S3 blob (purged via has_one_attached's :purge_later default) doesn't
  # leak. Skip if the image is still load-bearing for game history:
  # game_images preserves which images appeared in a played game, and
  # guesses are the per-round records.
  def purge_image_if_orphan
    return unless image
    return if image.image_set_items.exists?
    return if image.game_images.exists?
    return if image.guesses.exists?
    image.destroy
  end
end
