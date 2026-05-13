class ChallengeImage < ApplicationRecord
  belongs_to :challenge
  belongs_to :image

  # Symmetrical to GameImage / ImageSetItem: when the last challenge_image
  # referencing an Image is destroyed and nothing else points at it,
  # Image#purge_if_orphan! cleans up the row and its S3 blob.
  after_destroy :purge_image_if_orphan

  private

  def purge_image_if_orphan
    image&.purge_if_orphan!
  end
end
