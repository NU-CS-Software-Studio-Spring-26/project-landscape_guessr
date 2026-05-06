class ImageSet < ApplicationRecord
  belongs_to :user, optional: true
  has_many :image_set_items, dependent: :destroy
  has_many :images, through: :image_set_items
  has_many :games, dependent: :nullify

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

  private

  def system_default_has_no_user
    errors.add(:user, "must be blank for system default set") if is_system_default? && user_id.present?
  end

  def only_one_system_default
    existing = ImageSet.where(is_system_default: true)
    existing = existing.where.not(id: id) if persisted?
    errors.add(:base, "a system default set already exists") if existing.exists?
  end
end
