class RegionsController < ApplicationController
  def search
    query = params[:q].to_s.strip
    return render(json: []) if query.length < 2

    regions = Region.search(query, parent_image_set_id: params[:image_set_id], limit: 20)

    render json: regions.map { |r|
      result = {
        id: r.id,
        name: r.name,
        admin_level: r.admin_level,
        parent_id: r.parent_id,
        full_name: region_full_name(r)
      }
      result[:image_count] = r.image_count.to_i if r.respond_to?(:image_count)
      result
    }
  end

  def tree
    parent_id = params[:parent_id]
    regions = if parent_id.present?
      Region.where(parent_id: parent_id).order(:name)
    else
      Region.continents.order(:name)
    end

    render json: regions.map { |r|
      {
        id: r.id,
        name: r.name,
        admin_level: r.admin_level,
        has_children: r.children.exists?
      }
    }
  end

  def boundaries
    ids = Array(params[:ids]).map(&:to_i).reject(&:zero?)
    return render(json: { type: "FeatureCollection", features: [] }) if ids.empty?

    regions = Region.where(id: ids).where.not(boundary: nil)

    features = regions.map do |r|
      {
        type: "Feature",
        id: r.id,
        geometry: r.boundary,
        properties: { name: r.name, admin_level: r.admin_level }
      }
    end

    render json: { type: "FeatureCollection", features: features }
  end

  def at_point
    lat = params[:lat].to_f
    lng = params[:lng].to_f
    return render(json: []) if lat.zero? && lng.zero?

    factory = RGeo::Geographic.spherical_factory(srid: 4326)
    point = factory.point(lng, lat)

    candidates = Region
      .where.not(boundary: nil)
      .where("min_lat <= ? AND max_lat >= ? AND min_lng <= ? AND max_lng >= ?", lat, lat, lng, lng)

    matching = candidates.select do |r|
      geom = RGeo::GeoJSON.decode(r.boundary.to_json)
      geom&.contains?(point)
    rescue
      false
    end

    render json: matching.sort_by { |r| Region::ADMIN_LEVELS.index(r.admin_level) || 99 }.map { |r|
      { id: r.id, name: r.name, admin_level: r.admin_level, full_name: region_full_name(r) }
    }
  end

  private

  def region_full_name(region)
    parts = [ region.name ]
    current = region
    while current.parent_id
      current = current.parent
      break unless current
      parts << current.name
    end
    parts.reverse.join(" > ")
  end
end
