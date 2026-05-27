class Tag < ApplicationRecord
  NAME_MAX_LENGTH = 40
  SLUG_MAX_LENGTH = 60

  before_validation :normalize

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :slug, presence: true, length: { maximum: SLUG_MAX_LENGTH }, uniqueness: { case_sensitive: false }

  def self.parse_list(list)
    Array(list)
      .join(",")
      .split(",")
      .map { |t| t.to_s.strip }
      .reject(&:blank?)
      .uniq
  end

  def self.find_or_create_by_name!(name)
    normalized = name.to_s.strip
    slug = normalized.parameterize
    raise ActiveRecord::RecordInvalid, new(name: name) if slug.blank?

    find_or_create_by!(slug: slug) do |t|
      t.name = normalized
    end
  end

  private

  def normalize
    self.name = name.to_s.strip.presence
    self.slug = (slug.presence || name).to_s.parameterize.presence
  end
end
