class Image < ApplicationRecord
  has_one_attached :photo
  has_many :guesses, dependent: :destroy
  has_many :game_images, dependent: :destroy
  has_many :image_set_items, dependent: :destroy
  has_many :image_sets, through: :image_set_items

  # Images visible to a given user: only those that live in at least one
  # set the user is allowed to see (system_default, public, or owned).
  # Pass nil for the unauthenticated case — they see only system_default
  # and public sets.
  scope :visible_to, ->(user) {
    joins(:image_sets).merge(
      ImageSet.where(is_system_default: true)
              .or(ImageSet.where(visibility: "public"))
              .or(ImageSet.where(user_id: user&.id))
    ).distinct
  }

  def visible_to?(user)
    image_sets.any? { |s| s.is_system_default? || s.visibility == "public" || s.user_id == user&.id }
  end

  # An image is editable by anyone who owns at least one set containing
  # it (admins included), EXCEPT once it lives in the system-default set
  # — at which point only admins can change it. Otherwise any logged-in
  # user could add a default-set image to their own private set (via
  # `add_image`'s find_or_create_by!(url:)), gaining edit rights, and
  # rename it to something offensive. The renamed title would propagate
  # back to every game played on the default set.
  #
  # Edits otherwise propagate across every set the image is in — by
  # design, since Image is the canonical record and ImageSetItem is
  # just a join row. Per-set title overrides aren't implemented yet;
  # if/when they are, this rule loosens.
  def editable_by?(user)
    return false unless user
    return true if user.admin?
    return false if image_sets.exists?(is_system_default: true)
    image_sets.exists?(user_id: user.id)
  end

  # Convenience: a Google Maps URL pointing at this image's coordinates.
  # Nil if either coord is missing. Used by the detail and results pages
  # for "Open in Maps ↗" — works for every image (Wikimedia, uploads,
  # arbitrary URL) since lat/lng is the only requirement.
  def google_maps_url
    return nil unless latitude && longitude
    "https://www.google.com/maps?q=#{latitude},#{longitude}"
  end

  # Destroy this image (and its S3 blob via has_one_attached purge_later)
  # if no record still references it. Called from ImageSetItem and
  # GameImage after_destroy hooks so removing an image's last set
  # membership *or* deleting the games that played it both clean up the
  # underlying S3 storage. Conservative — refuses to destroy as long as
  # any join row still points here.
  def purge_if_orphan!
    return if image_set_items.exists?
    return if game_images.exists?
    return if guesses.exists?
    destroy
  end

  # True once ProcessImageJob has run on this Image's current attachment.
  # The marker is set on the freshly-attached processed JPEG blob; the
  # original raw blob never carries it. URL-only Images (no Active Storage
  # attachment) are treated as already-processed since there's nothing to
  # convert.
  def processed?
    return true unless photo.attached?
    photo.blob.metadata["processed"] == true
  end

  # Upload pipeline targets. 2560 covers retina edge cases (e.g. 16"
  # MBP) without breaking storage budgets; quality 75 is visually
  # indistinguishable from source on landscape photos.
  PROCESSED_MAX_DIMENSION = 2560
  PROCESSED_QUALITY       = 75

  # Display target for the zoomable game/practice/detail viewer.
  # Wikimedia serves a 3840-wide thumbnail when ?width=3840 is appended,
  # and the zoomable Stimulus controller reveals "load full quality"
  # only when the loaded img.naturalWidth ≥ this value (so the button
  # only shows up when there's a higher-res original to fetch). The
  # Ruby `image_src(image, width: …)` call and the JS
  # data-zoomable-cap-width-value have to agree — both read this.
  ZOOM_CAP_WIDTH = 3840

  # Read GPS coords from an upload's EXIF, or nil if absent/unreadable.
  # Accepts ActionDispatch::Http::UploadedFile or anything with #path.
  #
  # HEIC/HEIF: tries a fast path first — vips's heif loader exposes the
  # embedded EXIF as raw bytes via image.get("exif-data"), so we can hand
  # those to exifr without decoding any pixels (huge memory + speed win
  # on the bulk-upload path). If the fast path can't extract GPS for
  # some reason, falls back to transcoding HEIC -> tempJPEG and reading
  # via exifr/jpeg.
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
      when ".heic", ".heif"
        heic_exif_parser_fast(path) || EXIFR::JPEG.new(heic_to_jpeg_with_exif(path))
      end
    gps = parser&.gps
    return nil unless gps&.latitude && gps&.longitude
    [ gps.latitude, gps.longitude ]
  rescue EXIFR::MalformedJPEG, EXIFR::MalformedTIFF, StandardError
    nil
  end

  # Fast path: read EXIF bytes directly out of a HEIC via libvips (no
  # pixel decode, no transcode, no temp file) and parse them with
  # EXIFR::TIFF. Returns nil — the caller will fall back to the slow
  # path — on any error or if the heif loader didn't surface an EXIF
  # block.
  def self.heic_exif_parser_fast(path)
    require "vips"
    require "exifr/tiff"
    img = Vips::Image.new_from_file(path)
    return nil unless img.get_fields.include?("exif-data")
    bytes = img.get("exif-data").b
    # vips prefixes the EXIF payload with the standard "Exif\0\0" magic
    # for JPEG-style EXIF; EXIFR::TIFF wants raw TIFF bytes after it.
    bytes = bytes[6..] if bytes.start_with?("Exif\x00\x00".b)
    return nil if bytes.nil? || bytes.bytesize < 8
    EXIFR::TIFF.new(StringIO.new(bytes))
  rescue StandardError
    nil
  end

  # Transcode a HEIC/HEIF to a temp JPEG with EXIF preserved, so exifr can
  # read GPS out of it. Returns the temp file path. Fallback for the rare
  # HEIC where the fast path above can't surface EXIF.
  def self.heic_to_jpeg_with_exif(path)
    require "image_processing/vips"
    ImageProcessing::Vips
      .source(path)
      .convert("jpg")
      .saver(strip: false)
      .call
      .path
  end

  # Convert a file at `path` (HEIC/JPEG/PNG/WebP/etc) to a JPEG variant
  # downscaled to PROCESSED_MAX_DIMENSION on the longest side and
  # re-encoded at PROCESSED_QUALITY. Returns kwargs you can pass straight
  # to ActiveStorage::Attached#attach.
  #
  # Requires libvips on the host (brew install vips, or libvips42t64 from
  # the apt buildpack on Heroku). Used by ProcessImageJob to convert the
  # original blob the browser uploaded directly to S3.
  def self.process_path(path, original_filename)
    require "image_processing/vips"
    base = File.basename(original_filename, ".*")
    # Convert to sRGB *before* stripping metadata so browsers render colors
    # correctly. iPhone shoots Display P3; without this step the wider-gamut
    # P3 values get rendered as sRGB and look desaturated.
    processed = ImageProcessing::Vips
      .source(path)
      # sharpen: false disables image_processing's default 3x3 sharpen mask.
      # Apple's HEIC->JPEG transcode doesn't sharpen, and the extra
      # high-frequency noise both shifts colors slightly and bloats the JPEG.
      .resize_to_limit(PROCESSED_MAX_DIMENSION, PROCESSED_MAX_DIMENSION, sharpen: false)
      .icc_transform("srgb", embedded: true)
      .convert("jpg")
      .saver(quality: PROCESSED_QUALITY, strip: true)
      .call
    {
      io: processed,
      filename: "#{base}.jpg",
      content_type: "image/jpeg"
    }
  end
end
