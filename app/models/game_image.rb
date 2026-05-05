class GameImage < ApplicationRecord
  belongs_to :game
  belongs_to :image

  # Symmetrical to ImageSetItem's hook: when the last game referencing
  # an image is destroyed (and the image isn't in any set or guesses),
  # purge it so S3 doesn't accumulate orphans across game deletions.
  after_destroy :purge_image_if_orphan

  def answer_lat
    answer_latitude&.to_f || image.latitude&.to_f
  end

  def answer_lng
    answer_longitude&.to_f || image.longitude&.to_f
  end

  private

  def purge_image_if_orphan
    image&.purge_if_orphan!
  end
end
