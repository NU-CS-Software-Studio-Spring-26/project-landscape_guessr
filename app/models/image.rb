class Image < ApplicationRecord
  has_one_attached :photo
  has_many :guesses, dependent: :destroy
  has_many :game_images, dependent: :destroy
  has_many :image_set_items, dependent: :destroy
  has_many :image_sets, through: :image_set_items

  # Upload pipeline targets. 2560 covers retina edge cases (e.g. 16"
  # MBP) without breaking storage budgets; quality 75 is visually
  # indistinguishable from source on landscape photos.
  PROCESSED_MAX_DIMENSION = 2560
  PROCESSED_QUALITY       = 75

  # Read GPS coords from an upload's EXIF, or nil if absent/unreadable.
  # Accepts ActionDispatch::Http::UploadedFile or anything with #path.
  # HEIC/HEIF: exifr can't parse them, so we transcode to a throwaway JPEG
  # with metadata preserved (saver strip: false) and read GPS from that.
  def self.gps_from_upload(file)
    path = file.respond_to?(:path) ? file.path : file.to_s
    return nil unless path && File.exist?(path)

    require "exifr/jpeg"
    require "exifr/tiff"

    ext = File.extname(path).downcase
    parser =
      case ext
      when ".jpg", ".jpeg" then EXIFR::JPEG.new(path)
      when ".tif", ".tiff" then EXIFR::TIFF.new(path)
      when ".heic", ".heif" then EXIFR::JPEG.new(heic_to_jpeg_with_exif(path))
      end
    gps = parser&.gps
    return nil unless gps&.latitude && gps&.longitude
    [ gps.latitude, gps.longitude ]
  rescue EXIFR::MalformedJPEG, EXIFR::MalformedTIFF, StandardError
    nil
  end

  # Transcode a HEIC/HEIF to a temp JPEG with EXIF preserved, so exifr can
  # read GPS out of it. Returns the temp file path. The OS reaps Tempfiles
  # eventually; for an upload-time call we don't bother explicitly cleaning up.
  def self.heic_to_jpeg_with_exif(path)
    require "image_processing/vips"
    ImageProcessing::Vips
      .source(path)
      .convert("jpg")
      .saver(strip: false)
      .call
      .path
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
    # Convert to sRGB *before* stripping metadata so browsers render colors
    # correctly. iPhone shoots Display P3; without this step the wider-gamut
    # P3 values get rendered as sRGB and look desaturated.
    processed = ImageProcessing::Vips
      .source(file.path)
      .resize_to_limit(PROCESSED_MAX_DIMENSION, PROCESSED_MAX_DIMENSION)
      .colourspace("srgb")
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
