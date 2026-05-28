class Image < ApplicationRecord
  has_one_attached :photo
  has_many :guesses, dependent: :destroy
  has_many :game_images, dependent: :destroy
  has_many :challenge_images, dependent: :destroy
  has_many :image_set_items, dependent: :destroy
  has_many :image_sets, through: :image_set_items
  has_many :saved_practice_items, class_name: "SavedPracticeImage", dependent: :destroy
  has_many :saved_by_users, through: :saved_practice_items, source: :user
  has_many :ai_hints, class_name: "ImageAiHint", dependent: :destroy

  # Images visible to a given user: only those that live in at least one
  # set the user is allowed to see. Pass nil for the unauthenticated case.
  scope :visible_to, ->(user) {
    joins(:image_sets).merge(ImageSet.visible_to(user)).distinct
  }

  def visible_to?(user)
    image_sets.any? { |s| s.playable_by?(user) }
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

  # Bulk-insert importer rows into Image + ImageSetItem, dispatching on
  # source. Used by CommonsImporter and MapillaryImporter; WikidataImporter
  # still has its own legacy `insert_rows!` (kept for backward compat — its
  # URL-based dedup is the right shape for Wikidata's stable Commons URLs).
  #
  # Dedup keys by source:
  #   * mapillary: (external_source, external_id) — `url` is NULL until
  #     resolved at render time, so URL-dedup wouldn't work
  #   * commons:   (external_source, external_id) primary, with URL also
  #     unique-indexed as a fallback safety net
  #
  # Each row hash must have at least: external_source, external_id,
  # lat, lng, url (may be nil for mapillary), and optionally title,
  # author, license.
  def self.bulk_insert_for_source!(image_set:, rows:, source:)
    return 0 if rows.empty?

    new_links = 0
    inserted  = 0

    ActiveRecord::Base.logger.silence do
      rows.each_slice(500) do |slice|
        ImageSetItem.transaction do
          new_links += insert_slice_by_external_id!(image_set: image_set, slice: slice, source: source)
        end
        inserted += slice.size
        image_set.update_columns(import_progress: inserted)
      end
    end

    new_links
  end

  def self.insert_slice_by_external_id!(image_set:, slice:, source:)
    ext_ids = slice.filter_map { |r| r[:external_id] }
    existing = Image.where(external_source: source, external_id: ext_ids).pluck(:external_id, :id).to_h

    # images.url is globally unique. The same file can arrive under two
    # source identities — e.g. a Commons file already imported as a Wikidata
    # P18 — sharing one Special:FilePath URL. Inserting it again would
    # violate the url index, so resolve any row whose URL already exists
    # (under any source) onto that existing image and reuse it. Rows with a
    # blank URL (Mapillary, resolved lazily) are exempt — they have no URL
    # to collide on, and many legitimately share NULL.
    unresolved_urls = slice.reject { |r| existing.key?(r[:external_id]) }
                           .filter_map { |r| r[:url].presence }.uniq
    if unresolved_urls.any?
      by_url = Image.where(url: unresolved_urls).pluck(:url, :id).to_h
      slice.each do |r|
        next if r[:url].blank? || existing.key?(r[:external_id])
        id = by_url[r[:url]]
        existing[r[:external_id]] = id if id  # only map when a real match exists
      end
    end

    seen_urls = Set.new
    new_image_rows = slice.reject { |r| existing.key?(r[:external_id]) }
                          .uniq { |r| r[:external_id] }
                          .select { |r| r[:url].blank? || seen_urls.add?(r[:url]) }
                          .map do |r|
      {
        external_source: source,
        external_id:     r[:external_id],
        url:             r[:url],
        title:           r[:title].presence || "Untitled",
        latitude:        r[:lat],
        longitude:       r[:lng],
        author:          r[:author],
        license:         r[:license],
        created_at:      Time.current,
        updated_at:      Time.current
      }
    end

    if new_image_rows.any?
      result = Image.insert_all(
        new_image_rows,
        returning: %i[id external_id],
        unique_by: :index_images_on_external_source_and_external_id
      )
      result.rows.each { |id, ext_id| existing[ext_id] = id }
      still_missing = new_image_rows.map { |r| r[:external_id] } - existing.keys
      unless still_missing.empty?
        Image.where(external_source: source, external_id: still_missing).pluck(:external_id, :id).each do |ext_id, id|
          existing[ext_id] = id
        end
      end
    end

    candidate_image_ids = slice.filter_map { |r| existing[r[:external_id]] }.uniq
    already_linked = image_set.image_set_items
                              .where(image_id: candidate_image_ids)
                              .pluck(:image_id).to_set

    item_rows = slice.filter_map do |r|
      image_id = existing[r[:external_id]]
      next nil unless image_id
      next nil if already_linked.include?(image_id)
      already_linked << image_id
      {
        image_set_id: image_set.id, image_id: image_id,
        latitude: r[:lat], longitude: r[:lng],
        created_at: Time.current, updated_at: Time.current
      }
    end

    if item_rows.any?
      ImageSetItem.insert_all(item_rows, unique_by: %i[image_set_id image_id])
      item_rows.size
    else
      0
    end
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
    return if challenge_images.exists?
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
