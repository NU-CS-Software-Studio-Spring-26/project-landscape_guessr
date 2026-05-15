class PracticeController < ApplicationController
  PRACTICE_TIMER_SECONDS = [ 30, 60, 120 ].freeze
  PRACTICE_ATTEMPTS = [ 1, 2 ].freeze

  allow_unauthenticated_access only: %i[ show check ]
  skip_before_action :require_email_verified

  def show
    @time_limit_seconds = practice_seconds_param
    @attempts = practice_attempts_param
    load_random_located_image
  end

  def check
    # allow_unauthenticated_access (above) skips require_authentication,
    # which is also the hook that calls resume_session to populate
    # Current.user from the session cookie. Call it explicitly here so
    # signed-in users still see their own private-set images while
    # anonymous callers fall through to the system_default + public sets.
    resume_session

    # Gate by visibility — without this, /practice/check?image_id=N is
    # an unauthenticated read of any image's coordinates by enumerating
    # sequential IDs. That leaks lat/lng for images in private sets
    # (especially user uploads with EXIF GPS).
    image = Image.visible_to(Current.user).find_by(id: params[:image_id])
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

  private

  def load_random_located_image
    default_set = ImageSet.default
    @image = current_image_from_params(default_set)
    return if @image.present?

    # Practice mode shows a random image and asks for a guess, so the image
    # must have lat/lng — otherwise the "answer" is (0, 0) and every guess
    # scores arbitrarily. Filter at the DB level.
    located = ->(scope) { scope.where.not(latitude: nil).where.not(longitude: nil) }
    @image = located.call(default_set&.images || Image.all).order(Arel.sql("RANDOM()")).first ||
             located.call(Image.all).order(Arel.sql("RANDOM()")).first

    return unless @image.nil?

    redirect_to images_path, alert: "No images with coordinates are available yet."
  end

  def practice_seconds_param
    seconds = params[:seconds].to_i
    return nil if seconds <= 0

    PRACTICE_TIMER_SECONDS.include?(seconds) ? seconds : 60
  end

  def practice_attempts_param
    attempts = params[:attempts].to_i
    PRACTICE_ATTEMPTS.include?(attempts) ? attempts : 1
  end

  def current_image_from_params(default_set)
    image_id = params[:image_id].to_i
    return nil if image_id <= 0 || default_set.blank?

    default_set.images
               .where(id: image_id)
               .where.not(latitude: nil, longitude: nil)
               .first
  end
end
