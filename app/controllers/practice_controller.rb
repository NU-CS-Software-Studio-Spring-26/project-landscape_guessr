class PracticeController < ApplicationController
  allow_unauthenticated_access only: %i[ show check ]

  def show
    default_set = ImageSet.default
    # Practice mode shows a random image and asks for a guess, so the image
    # must have lat/lng — otherwise the "answer" is (0, 0) and every guess
    # scores arbitrarily. Filter at the DB level.
    located = ->(scope) { scope.where.not(latitude: nil).where.not(longitude: nil) }
    @image = located.call(default_set&.images || Image.all).order(Arel.sql("RANDOM()")).first ||
             located.call(Image.all).order(Arel.sql("RANDOM()")).first

    if @image.nil?
      redirect_to images_path, alert: "No images with coordinates are available yet."
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
