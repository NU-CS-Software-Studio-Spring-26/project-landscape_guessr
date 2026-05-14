class Region < ApplicationRecord
  belongs_to :parent, class_name: "Region", optional: true
  has_many :children, class_name: "Region", foreign_key: :parent_id, dependent: :destroy
  has_many :image_regions, dependent: :destroy
  has_many :images, through: :image_regions

  ADMIN_LEVELS = %w[continent country admin1 admin2].freeze

  validates :admin_level, inclusion: { in: ADMIN_LEVELS }
  validates :name, presence: true

  scope :continents, -> { where(admin_level: "continent") }
  scope :countries, -> { where(admin_level: "country") }
  scope :admin1s, -> { where(admin_level: "admin1") }
  scope :admin2s, -> { where(admin_level: "admin2") }

  def self.descendants_of(region_ids)
    return [] if region_ids.empty?

    placeholders = region_ids.map { "?" }.join(",")
    base_sql = sanitize_sql_array(
      [ "WITH RECURSIVE tree AS (
          SELECT id FROM regions WHERE id IN (#{placeholders})
          UNION ALL
          SELECT r.id FROM regions r JOIN tree t ON r.parent_id = t.id
        )
        SELECT id FROM tree", *region_ids.map(&:to_i) ]
    )
    connection.select_values(base_sql).map(&:to_i)
  end

  def self.search(query, parent_image_set_id: nil, limit: 20)
    scope = where("name ILIKE ?", "%#{sanitize_sql_like(query)}%")
      .order(Arel.sql(<<~SQL))
        CASE admin_level
          WHEN 'continent' THEN 0
          WHEN 'country' THEN 1
          WHEN 'admin1' THEN 2
          WHEN 'admin2' THEN 3
        END, name
      SQL
    scope = scope.limit(limit)

    if parent_image_set_id.present?
      scope.select("regions.*, (
        SELECT COUNT(DISTINCT image_regions.image_id)
        FROM image_regions
        JOIN image_set_items ON image_set_items.image_id = image_regions.image_id
        WHERE image_set_items.image_set_id = #{parent_image_set_id.to_i}
        AND image_regions.region_id = regions.id
      ) AS image_count")
    else
      scope
    end
  end

  def rgeo_boundary
    return nil unless boundary
    RGeo::GeoJSON.decode(boundary.to_json)
  end

  def contains_point?(lat, lng)
    geom = rgeo_boundary
    return false unless geom

    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    point = factory.point(lng.to_f, lat.to_f)
    geom.contains?(point)
  rescue
    false
  end
end
