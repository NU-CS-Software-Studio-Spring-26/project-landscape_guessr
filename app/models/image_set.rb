class ImageSet < ApplicationRecord
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

  validates :name, presence: true
  validates :visibility, inclusion: { in: %w[private public] }
  validates :map_style, inclusion: { in: MAP_STYLES }
  validate :system_default_has_no_user
  validate :only_one_system_default, if: :is_system_default?

  before_destroy :capture_member_image_ids
  after_destroy  :sweep_orphan_images

  scope :public_catalog, -> { where(visibility: "public") }
  scope :owned_by, ->(user) { where(user: user) }

  def self.default
    find_by(is_system_default: true)
  end

  def owned_by?(user)
    self.user_id == user&.id
  end

  def playable_by?(user)
    is_system_default? || owned_by?(user) || visibility == "public"
  end

  def filtered?
    parent_image_set_id.present?
  end

  def effective_items
    if filtered?
      expanded_ids = Region.descendants_of(region_ids)
      parent_image_set.image_set_items
        .where(image_id: ImageRegion.where(region_id: expanded_ids).select(:image_id))
    else
      image_set_items
    end
  end

  def effective_items_count
    if filtered?
      effective_items.count
    else
      image_set_items.count
    end
  end

  def selected_regions
    Region.where(id: region_ids)
  end

  private

  def system_default_has_no_user
    errors.add(:user, "must be blank for system default set") if is_system_default? && user_id.present?
  end

  def only_one_system_default
    existing = ImageSet.where(is_system_default: true)
    existing = existing.where.not(id: id) if persisted?
    errors.add(:base, "a system default set already exists") if existing.exists?
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
