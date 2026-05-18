class ImageSet < ApplicationRecord
  SAVED_FOR_PRACTICE_NAME = "Saved for Practice".freeze

  # Name validation rules — kept as constants so the form helpers can mirror
  # the same bounds in HTML5 attrs (minlength/maxlength/pattern) without
  # drifting out of sync with the model.
  NAME_MIN_LENGTH = 3
  NAME_MAX_LENGTH = 60
  # Letters (any script), numbers, spaces, and basic punctuation: - _ . , ' & ! ?
  NAME_ALLOWED_PATTERN = /\A[\p{L}\p{N} \-_.,'&!?]+\z/u
  # HTML5 pattern attribute — same character class, no anchors (HTML anchors
  # implicitly). The pattern attribute is compiled with the `v` flag, which
  # supports \p{L}/\p{N} in modern browsers.
  NAME_HTML_PATTERN = "[\\p{L}\\p{N} \\-_.,'&!?]+".freeze
  NAME_FORMAT_MESSAGE = "may only contain letters, numbers, spaces, and - _ . , ' & ! ?".freeze

  # Set by trusted server-side flows (e.g. the auto-created practice set)
  # to bypass the reserved-name check. Never set from user input.
  attr_accessor :system_managed

  belongs_to :user, optional: true
  belongs_to :parent_image_set, class_name: "ImageSet", optional: true
  # dependent: :delete_all (NOT :destroy) — destroying a 5000-item set
  # via per-row :destroy loads every row + fires ImageSetItem#after_destroy
  # for each, which runs Image#purge_if_orphan! (3 SQL counts each), which
  # destroys the Image (firing ActiveStorage purge_later for any
  # attachment). On a 4000+ item set that's tens of thousands of SQL
  # ops + thousands of in-memory AR objects — H12 timeout on web dynos
  # and R14 OOM on Heroku Basic. :delete_all collapses the join-row
  # cleanup into one bulk SQL. The per-set orphan sweep is replicated
  # below in #sweep_orphan_images, batched and split by attachment kind.
  has_many :image_set_items, dependent: :delete_all
  has_many :images, through: :image_set_items
  has_many :games, dependent: :nullify
  has_many :filtered_sets, class_name: "ImageSet", foreign_key: :parent_image_set_id, dependent: :destroy

  # MapTiler basemap styles available per set. Used by the guess /
  # results / set-map controllers — see app/javascript/controllers/*.js.
  # outdoor-v2 is the default ("terrain + mountain peaks + POIs"); the
  # others are common pickings for urban (streets, bright) or aerial
  # (satellite, hybrid) sets. Adding more = same line + one option in
  # the form's select.
  MAP_STYLES = %w[outdoor-v2 streets-v2 bright-v2 topo-v2 satellite hybrid].freeze

  before_validation :strip_name

  validates :name,
    presence: true,
    length: { in: NAME_MIN_LENGTH..NAME_MAX_LENGTH },
    format: { with: NAME_ALLOWED_PATTERN, message: NAME_FORMAT_MESSAGE, allow_blank: true },
    uniqueness: { scope: :user_id, case_sensitive: false, allow_blank: true }
  validates :visibility, inclusion: { in: %w[private public] }
  validates :map_style, inclusion: { in: MAP_STYLES }
  validate :system_default_has_no_user
  validate :only_one_system_default, if: :is_system_default?
  validate :name_not_reserved

  # `prepend: true` so this runs BEFORE the `dependent: :delete_all` on
  # image_set_items (declared above) — dependent destroy strategies are
  # before_destroy callbacks added at class-load time in declaration
  # order, so without prepend our snapshot would see an empty join table.
  before_destroy :capture_member_image_ids, prepend: true
  after_destroy  :sweep_orphan_images

  scope :public_catalog, -> { where(visibility: "public") }
  scope :owned_by, ->(user) { where(user: user) }
  # Sets a given user is allowed to see. Mirrors `playable_by?` at the
  # query level: system_default OR public OR owned. Pass nil for the
  # unauthenticated case — effectively system_default OR public.
  scope :visible_to, ->(user) {
    where(is_system_default: true)
      .or(public_catalog)
      .or(where(user_id: user&.id))
  }

  def self.default
    find_by(is_system_default: true)
  end

  def owned_by?(user)
    self.user_id == user&.id
  end

  def saved_for_practice?
    name == SAVED_FOR_PRACTICE_NAME
  end

  def practice_set_for?(user)
    saved_for_practice? && owned_by?(user)
  end

  def playable_by?(user)
    is_system_default? || owned_by?(user) || visibility == "public"
  end

  def filtered?
    parent_image_set_id.present?
  end

  def effective_items
    image_set_items
  end

  def effective_items_count
    image_set_items.count
  end

  def selected_regions
    Region.where(id: region_ids)
  end

  def materialize_filtered_items!
    return unless filtered?

    # Allow Nominatim fetches when actually saving — it's a one-time cost
    matched = compute_matching_image_ids(fetch_missing_boundaries: true)
    transaction do
      image_set_items.delete_all

      if matched.any?
        parent_items = parent_image_set.image_set_items
          .where(image_id: matched)
          .pluck(:image_id, :latitude, :longitude)

        rows = parent_items.map do |image_id, lat, lng|
          { image_set_id: id, image_id: image_id,
            latitude: lat, longitude: lng,
            created_at: Time.current, updated_at: Time.current }
        end
        ImageSetItem.insert_all(rows)
      end
    end
  end

  # Earth radius in metres — used for haversine distance in circle matching.
  EARTH_RADIUS_M = 6_371_000.0

  def compute_matching_image_ids(fetch_missing_boundaries: false)
    regions = resolve_filter_regions(fetch_missing_boundaries: fetch_missing_boundaries)
    region_geoms = build_region_geoms(regions)
    circles = parsed_circle_areas
    polygons = parsed_polygon_areas
    return [] if region_geoms.empty? && circles.empty? && polygons.empty?

    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    candidates = parent_image_set.image_set_items
      .joins(:image)
      .where.not(images: { latitude: nil, longitude: nil })
      .pluck("images.id", "images.latitude", "images.longitude")

    matched = []
    candidates.each do |image_id, lat, lng|
      lat = lat.to_f
      lng = lng.to_f

      # Cheap bbox-then-poly check for each region, fall through to circle/polygon
      # custom areas if no region matched. Any match short-circuits to next image.
      hit = image_matches_any?(image_id, lat, lng, region_geoms, circles, polygons, factory)
      matched << image_id if hit
    end

    matched
  end

  def resolve_filter_regions(fetch_missing_boundaries: false)
    selected = Region.where(id: region_ids).to_a
    result = []

    selected.each do |region|
      if region.boundary.present?
        # Continents have buffered hrbrmstr polygons (accurate enough for filtering).
        # admin1/admin2/city use polygons we previously fetched from Nominatim.
        result << region
      elsif fetch_missing_boundaries
        # admin1/admin2/city without boundary yet — fetch from Nominatim now (rate-limited).
        # Only happens at filter save, never in the live preview path.
        region.fetch_real_boundary!
        result << region if region.boundary.present?
      end
    end

    result.uniq
  end

  # Parsed view of custom_areas where type=="circle". Each entry:
  #   { lat:, lng:, radius_m:, radius_lat_deg:, radius_lng_deg: }
  # The "radius in degrees" fields are pre-computed for a cheap bbox pre-filter
  # before paying for haversine; lng-radius widens at high latitudes by 1/cos(lat).
  def parsed_circle_areas
    Array(custom_areas).filter_map do |a|
      next nil unless a.is_a?(Hash) && a["type"] == "circle"
      center = a["center"] || {}
      lat = center["lat"]&.to_f
      lng = center["lng"]&.to_f
      rad = a["radius_m"]&.to_f
      next nil unless lat && lng && rad && rad.positive?
      next nil unless lat.between?(-90, 90) && lng.between?(-180, 180)
      rad_lat = rad / 111_320.0  # metres per degree of latitude (constant)
      rad_lng = rad / (111_320.0 * Math.cos(lat * Math::PI / 180).abs.clamp(0.000001, 1))
      { lat: lat, lng: lng, radius_m: rad, radius_lat_deg: rad_lat, radius_lng_deg: rad_lng }
    end
  end

  # Parsed view of custom_areas where type=="polygon", decoded to RGeo geometry.
  # Not user-facing yet (no drawing UI), but the data path is in place so we
  # can ship the UI without touching matching.
  def parsed_polygon_areas
    Array(custom_areas).filter_map do |a|
      next nil unless a.is_a?(Hash) && a["type"] == "polygon"
      geom = RGeo::GeoJSON.decode(a["geojson"].to_json) rescue nil
      next nil unless geom
      bbox = Region.compute_bbox(a["geojson"])
      { geom: geom, **bbox.to_h.transform_keys(&:to_sym) }
    end
  end

  private

  def build_region_geoms(regions)
    regions.filter_map do |r|
      geom = r.rgeo_boundary
      next nil unless geom
      { geom: geom, min_lat: r.min_lat, max_lat: r.max_lat, min_lng: r.min_lng, max_lng: r.max_lng }
    end
  end

  def image_matches_any?(_image_id, lat, lng, region_geoms, circles, polygons, factory)
    point = nil

    region_geoms.each do |g|
      next if g[:min_lat] && outside_bbox?(lat, lng, g)
      point ||= factory.point(lng, lat)
      return true if (g[:geom].contains?(point) rescue false)
    end

    circles.each do |c|
      # Cheap bbox pre-filter before paying for haversine.
      next if (lat - c[:lat]).abs > c[:radius_lat_deg]
      next if (lng - c[:lng]).abs > c[:radius_lng_deg]
      return true if haversine_m(c[:lat], c[:lng], lat, lng) <= c[:radius_m]
    end

    polygons.each do |p|
      next if p[:min_lat] && outside_bbox?(lat, lng, p)
      point ||= factory.point(lng, lat)
      return true if (p[:geom].contains?(point) rescue false)
    end

    false
  end

  def outside_bbox?(lat, lng, area)
    lat < area[:min_lat] || lat > area[:max_lat] ||
      lng < area[:min_lng] || lng > area[:max_lng]
  end

  # Great-circle distance in metres between two lat/lng points.
  def haversine_m(lat1, lng1, lat2, lng2)
    rad_per_deg = Math::PI / 180.0
    dlat = (lat2 - lat1) * rad_per_deg
    dlng = (lng2 - lng1) * rad_per_deg
    a = Math.sin(dlat / 2)**2 +
        Math.cos(lat1 * rad_per_deg) * Math.cos(lat2 * rad_per_deg) * Math.sin(dlng / 2)**2
    2 * EARTH_RADIUS_M * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end

  public

  def system_default_has_no_user
    errors.add(:user, "must be blank for system default set") if is_system_default? && user_id.present?
  end

  def only_one_system_default
    existing = ImageSet.where(is_system_default: true)
    existing = existing.where.not(id: id) if persisted?
    errors.add(:base, "a system default set already exists") if existing.exists?
  end

  def strip_name
    self.name = name.strip if name.is_a?(String)
  end

  # Reserved-name check: the auto-created "Saved for Practice" set is owned
  # by the practice flow (see PracticeController#saved_practice_set_for).
  # Users mustn't be able to claim that name from a form, because the
  # presence of a set with that name is the signal that turns it into the
  # user's practice set everywhere else in the app. The `system_managed`
  # flag lets the trusted creator bypass this. Existing rows that already
  # carry the reserved name (created before this validation, or by the
  # system flow) keep working as long as the name isn't being changed —
  # `will_save_change_to_name?` skips the check when name is untouched.
  def name_not_reserved
    return if system_managed || is_system_default?
    return if name.blank?
    return if persisted? && !will_save_change_to_name?
    errors.add(:name, "is reserved") if name.casecmp?(SAVED_FOR_PRACTICE_NAME)
  end

  # Snapshot member image_ids before dependent: :delete_all wipes the
  # join rows. Batched pluck — pulling 100k IDs at once is fine for
  # Postgres but allocates a big array.
  def capture_member_image_ids
    @member_image_ids = image_set_items.pluck(:image_id).uniq
  end

  # After the set + join rows are gone, find Images that (a) were
  # members of this set and (b) are no longer referenced anywhere
  # (no other set, no played games, no guesses), and clean them up.
  # Split by attachment kind:
  # - URL-only Images get delete_all (single SQL, no callbacks needed
  #   since there's no S3 blob to purge).
  # - Active Storage-attached Images go through #destroy (one row at
  #   a time) so has_one_attached's purge_later fires and the blob
  #   actually leaves S3.
  # Chunk through the candidate ID list to keep the IN clause and
  # any in-memory loops bounded for very large sets.
  def sweep_orphan_images
    return if @member_image_ids.blank?

    @member_image_ids.each_slice(5_000) do |chunk|
      orphan_ids = Image.where(id: chunk)
                        .where.missing(:image_set_items)
                        .where.missing(:game_images)
                        .where.missing(:challenge_images)
                        .where.missing(:guesses)
                        .pluck(:id)
      next if orphan_ids.empty?

      attached_ids = ActiveStorage::Attachment
                       .where(record_type: "Image", name: "photo", record_id: orphan_ids)
                       .pluck(:record_id)
      url_only_ids = orphan_ids - attached_ids

      Image.where(id: url_only_ids).delete_all if url_only_ids.any?
      Image.where(id: attached_ids).find_each(batch_size: 50, &:destroy) if attached_ids.any?
    end
  end
end
