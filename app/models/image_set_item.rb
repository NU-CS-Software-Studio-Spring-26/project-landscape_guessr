class ImageSetItem < ApplicationRecord
  belongs_to :image_set
  belongs_to :image

  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
  validates :image_id, uniqueness: { scope: :image_set_id, message: "already in this set" }

  # Items that have an answer location — either a per-item override or a
  # fallback to the underlying image's coords. Without this filter, picking
  # rounds for a game/challenge can silently include items where both coord
  # paths are nil, and every guess for that round scores against (0, 0).
  scope :with_usable_coords, -> {
    joins(:image)
      .where("COALESCE(image_set_items.latitude,  images.latitude)  IS NOT NULL")
      .where("COALESCE(image_set_items.longitude, images.longitude) IS NOT NULL")
      .preload(:image)
  }

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
  # leak. Image#purge_if_orphan! is conservative — it skips destruction
  # if any other association still points at the image, so this is safe
  # even when the image lives in multiple sets or has played games.
  def purge_image_if_orphan
    image&.purge_if_orphan!
  end
end
