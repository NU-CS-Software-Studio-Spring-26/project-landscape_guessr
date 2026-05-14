class TagImageRegionsJob < ApplicationJob
  queue_as :default

  def perform(image)
    return unless image.latitude.present? && image.longitude.present?

    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    point = factory.point(image.longitude.to_f, image.latitude.to_f)

    matching_region_ids = []

    Region.where.not(boundary: nil).find_each(batch_size: 500) do |region|
      geom = RGeo::GeoJSON.decode(region.boundary.to_json)
      next unless geom

      if geom.contains?(point)
        matching_region_ids << region.id
      end
    rescue => e
      Rails.logger.warn "TagImageRegionsJob: failed checking region #{region.id}: #{e.message}"
    end

    existing_ids = image.image_regions.pluck(:region_id)
    new_ids = matching_region_ids - existing_ids
    stale_ids = existing_ids - matching_region_ids

    ImageRegion.insert_all(new_ids.map { |rid| { image_id: image.id, region_id: rid, created_at: Time.current, updated_at: Time.current } }) if new_ids.any?
    image.image_regions.where(region_id: stale_ids).delete_all if stale_ids.any?
  end
end
