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
    distance_km = Game.haversine_km(params[:lat].to_f, params[:lng].to_f, ans_lat, ans_lng)

    render json: {
      answer_lat: ans_lat,
      answer_lng: ans_lng,
      distance_km: distance_km
    }
  end
end
