class PracticeController < ApplicationController
  allow_unauthenticated_access only: %i[ show check ]

  def show
    default_set = ImageSet.default
    @image = default_set&.images&.order("RANDOM()")&.first || Image.order("RANDOM()").first

    if @image.nil?
      redirect_to images_path, alert: "No images available. Seed some first."
    end
  end

  def check
    image = Image.find_by(id: params[:image_id])
    return render json: { error: "image_not_found" }, status: :not_found unless image

    ans_lat = image.latitude.to_f
    ans_lng = image.longitude.to_f
    distance_km = haversine_km(params[:lat].to_f, params[:lng].to_f, ans_lat, ans_lng)

    render json: {
      answer_lat: ans_lat,
      answer_lng: ans_lng,
      distance_km: distance_km
    }
  end

  private

  def haversine_km(lat1, lon1, lat2, lon2)
    rad = Math::PI / 180
    dlat = (lat2 - lat1) * rad
    dlon = (lon2 - lon1) * rad
    a = Math.sin(dlat / 2)**2 +
        Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2)**2
    6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end
end
