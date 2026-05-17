class PracticeController < ApplicationController
  PRACTICE_TIMER_SECONDS = [ 30, 60, 120 ].freeze
  PRACTICE_ATTEMPTS = [ 1, 2 ].freeze
  HINT_TIERS = (1..3).freeze

  allow_unauthenticated_access only: %i[ show check hint ]
  skip_before_action :require_email_verified

  def show
    resume_session
    @time_limit_seconds = practice_seconds_param
    @attempts = practice_attempts_param
    @hint_circle_enabled = practice_hint_circle_param
    @ai_hints_enabled = GeminiConfig.enabled?
    load_random_located_image
    return if performed?

    @saved_for_practice =
      authenticated? && Current.user.saved_practice_items.exists?(image_id: @image.id)
  end

  def saved
    saved_ids = SavedPracticeImage
                .where(user_id: Current.user.id)
                .order(created_at: :desc)
                .pluck(:image_id)

    visible = Image.visible_to(Current.user)
                   .where.not(latitude: nil, longitude: nil)
                   .where(id: saved_ids)
                   .index_by(&:id)
    @saved_images = saved_ids.filter_map { |id| visible[id] }
  end

  def save
    image = savable_image_from_params
    if image.blank?
      respond_to do |format|
        format.html { redirect_to practice_path, alert: "That image isn't available for practice." }
        format.json { render json: { error: "image_not_available" }, status: :unprocessable_entity }
      end
      return
    end

    Current.user.saved_practice_items.create_or_find_by!(image: image)
    saved_practice_set_for(Current.user).image_set_items.find_or_create_by!(image: image) do |item|
      item.latitude = image.latitude
      item.longitude = image.longitude
    end
    respond_to do |format|
      format.html do
        redirect_to practice_path(practice_redirect_params(image_id: image.id)),
                    notice: "Saved for practice."
      end
      format.json { render json: { status: "saved" } }
    end
  end

  def unsave
    Current.user.saved_practice_items.where(image_id: params[:image_id].to_i).destroy_all
    saved_practice_set_for(Current.user)
      .image_set_items
      .where(image_id: params[:image_id].to_i)
      .destroy_all

    respond_to do |format|
      format.html do
        if params[:from_saved].present?
          redirect_to practice_saved_path, notice: "Removed from saved practice images."
        else
          redirect_to practice_path(practice_redirect_params(image_id: params[:image_id].to_i)),
                      notice: "Removed from saved practice images."
        end
      end
      format.json { render json: { status: "removed" } }
    end
  end

  def hint
    resume_session

    unless GeminiConfig.enabled?
      return render json: { error: "ai_hints_disabled" }, status: :service_unavailable
    end

    tier = hint_tier_param
    image = visible_located_image_from_params
    return render json: { error: "image_not_found" }, status: :not_found unless image

    ai_hint = ImageAiHint.find_by(image: image, tier: tier)

    if ai_hint&.status == "ready"
      return render json: { status: "ready", hint: ai_hint.body, tier: tier }
    end

    if ai_hint&.status == "failed"
      if hint_retry_requested? || stale_failed_hint?(ai_hint)
        ai_hint.update!(status: "pending", error_message: nil)
        enqueue_hint_job!(image.id, tier)
        return render json: { status: "pending", tier: tier }
      end

      return render json: { status: "failed", error: public_hint_error(ai_hint), tier: tier }
    end

    if ai_hint&.status == "pending"
      reenqueue_stale_pending_hint!(image.id, tier, ai_hint)
      return render json: { status: "pending", tier: tier }
    end

    ImageAiHint.create!(image: image, tier: tier, status: "pending")
    enqueue_hint_job!(image.id, tier)
    render json: { status: "pending", tier: tier }
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
    visible_images = Image.visible_to(Current.user)
    @image = current_image_from_params
    return if @image.present?

    # Practice mode shows a random image and asks for a guess, so the image
    # must have lat/lng — otherwise the "answer" is (0, 0) and every guess
    # scores arbitrarily. Filter at the DB level.
    located = ->(scope) { scope.where.not(latitude: nil).where.not(longitude: nil) }
    @image = located.call(default_set&.images || visible_images).order(Arel.sql("RANDOM()")).first ||
             located.call(visible_images).order(Arel.sql("RANDOM()")).first

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

  def practice_hint_circle_param
    params[:hint_circle].to_s == "1"
  end

  def hint_tier_param
    tier = params[:tier].to_i
    HINT_TIERS.cover?(tier) ? tier : 1
  end

  def hint_retry_requested?
    ActiveModel::Type::Boolean.new.cast(params[:retry])
  end

  def enqueue_hint_job!(image_id, tier)
    GenerateAiHintJob.perform_later(image_id, tier)
  end

  STALE_PENDING_HINT_AFTER = 2.minutes
  STALE_FAILED_HINT_AFTER = 5.minutes

  def reenqueue_stale_pending_hint!(image_id, tier, ai_hint)
    return unless ai_hint.updated_at < STALE_PENDING_HINT_AFTER.ago

    enqueue_hint_job!(image_id, tier)
  end

  def stale_failed_hint?(ai_hint)
    ai_hint.updated_at < STALE_FAILED_HINT_AFTER.ago
  end

  def public_hint_error(ai_hint)
    AiHintPublicError.message(ai_hint.error_message)
  end

  def visible_located_image_from_params
    image_id = params[:image_id].to_i
    return nil if image_id <= 0

    Image.visible_to(Current.user)
         .where.not(latitude: nil, longitude: nil)
         .find_by(id: image_id)
  end

  def current_image_from_params
    image_id = params[:image_id].to_i
    return nil if image_id <= 0

    Image.visible_to(Current.user)
         .where(id: image_id)
         .where.not(latitude: nil, longitude: nil)
         .first
  end

  def savable_image_from_params
    image_id = params[:image_id].to_i
    return nil if image_id <= 0

    Image.visible_to(Current.user)
         .where(id: image_id)
         .where.not(latitude: nil, longitude: nil)
         .first
  end

  def practice_redirect_params(image_id:)
    result = { image_id: image_id }
    seconds = params[:seconds].to_i
    attempts = params[:attempts].to_i
    result[:seconds] = seconds if PRACTICE_TIMER_SECONDS.include?(seconds)
    result[:attempts] = attempts if PRACTICE_ATTEMPTS.include?(attempts) && attempts > 1
    result
  end

  def saved_practice_set_for(user)
    user.image_sets.find_or_create_by!(name: ImageSet::SAVED_FOR_PRACTICE_NAME) do |set|
      set.visibility = "private"
      set.map_style = "outdoor-v2"
    end
  end
end
