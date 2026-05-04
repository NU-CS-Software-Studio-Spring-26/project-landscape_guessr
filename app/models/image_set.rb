class ImageSet < ApplicationRecord
  belongs_to :user, optional: true
  has_many :image_set_items, dependent: :destroy
  has_many :images, through: :image_set_items
  has_many :games, dependent: :nullify

  validates :name, presence: true
  validates :visibility, inclusion: { in: %w[private public] }
  validate :system_default_has_no_user
  validate :only_one_system_default, if: :is_system_default?

  scope :system_default, -> { find_by!(is_system_default: true) }
  scope :public_catalog, -> { where(visibility: "public", is_system_default: false) }
  scope :owned_by, ->(user) { where(user: user) }
  scope :visible_to, ->(user) {
    where(user: user).or(where(visibility: "public", is_system_default: false))
  }

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
