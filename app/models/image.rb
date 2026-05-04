class Image < ApplicationRecord
  has_one_attached :photo
  has_many :guesses, dependent: :destroy
  has_many :game_images, dependent: :destroy
  has_many :image_set_items, dependent: :destroy
  has_many :image_sets, through: :image_set_items

  # Read GPS coords from a JPEG/TIFF upload's EXIF, or nil if absent/unreadable.
  # Accepts ActionDispatch::Http::UploadedFile or anything with #path.
  def self.gps_from_upload(file)
    path = file.respond_to?(:path) ? file.path : file.to_s
    return nil unless path && File.exist?(path)

    require "exifr/jpeg"
    require "exifr/tiff"
    parser =
      case File.extname(path).downcase
      when ".jpg", ".jpeg" then EXIFR::JPEG.new(path)
      when ".tif", ".tiff" then EXIFR::TIFF.new(path)
      end
    gps = parser&.gps
    return nil unless gps&.latitude && gps&.longitude
    [ gps.latitude, gps.longitude ]
  rescue EXIFR::MalformedJPEG, EXIFR::MalformedTIFF, StandardError
    nil
  end
end
