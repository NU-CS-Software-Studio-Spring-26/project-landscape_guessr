class Image < ApplicationRecord
  has_one_attached :photo
  has_many :guesses, dependent: :destroy
  has_many :game_images, dependent: :destroy
  has_many :image_set_items, dependent: :destroy
  has_many :image_sets, through: :image_set_items

  # Maximum side length the upload pipeline downscales to. iPhone 13 Pro shoots
  # 4032x3024; capping at 3024 cuts the pixel count ~36% with no visible loss
  # for the guessing-game use case.
  PROCESSED_MAX_DIMENSION = 3024
  PROCESSED_QUALITY       = 85

  # Read GPS coords from a JPEG/TIFF upload's EXIF, or nil if absent/unreadable.
  # Accepts ActionDispatch::Http::UploadedFile or anything with #path.
  # Note: HEIC GPS extraction is not implemented; fall back to the form fields.
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

  # Convert an uploaded file (HEIC/JPEG/PNG/WebP/etc) to a JPEG variant
  # downscaled to PROCESSED_MAX_DIMENSION on the longest side and
  # re-encoded at PROCESSED_QUALITY. Returns the kwargs you can pass
  # straight to ActiveStorage::Attached#attach.
  #
  # Requires libvips on the host (brew install vips, or a vips buildpack
  # on Heroku). Falls back to the original file if processing fails so
  # uploads don't 500 even on a misconfigured machine.
  def self.process_upload(file)
    require "image_processing/vips"
    base = File.basename(file.original_filename, ".*")
    processed = ImageProcessing::Vips
      .source(file.path)
      .resize_to_limit(PROCESSED_MAX_DIMENSION, PROCESSED_MAX_DIMENSION)
      .convert("jpg")
      .saver(quality: PROCESSED_QUALITY, strip: true)
      .call
    {
      io: processed,
      filename: "#{base}.jpg",
      content_type: "image/jpeg"
    }
  rescue StandardError => e
    Rails.logger.warn "[Image.process_upload] falling back to raw upload: #{e.class}: #{e.message}"
    file.rewind if file.respond_to?(:rewind)
    {
      io: file,
      filename: file.original_filename,
      content_type: file.content_type
    }
  end
end
