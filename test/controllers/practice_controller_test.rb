require "test_helper"

class PracticeControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  setup do
    @alice = users(:alice)
    @bob   = users(:bob)
    # alice_only is in alice_private (a private set) and NOT in any
    # public or system-default set, so it's invisible to anyone but
    # alice (and admins).
    @private_image = images(:alice_only)
    # image one is in the system-default set, so it's visible to
    # everyone — including unauthenticated callers.
    @public_image  = images(:one)
  end

  test "show renders without auth" do
    get practice_path
    assert_response :success
  end

  test "show includes AI hint controls when ai hints enabled" do
    with_ai_hints_config(enabled: true) do
      get practice_path
    end

    assert_response :success
    assert_includes response.body, 'data-practice-type-param="visual"'
    assert_includes response.body, "AI hint"
    assert_includes response.body, "Subtle"
    assert_includes response.body, "Medium"
    assert_includes response.body, "Strong"
    assert_includes response.body, "data-practice-hint-url-value"
    assert_includes response.body, "data-practice-hint-quota-used-value"
    assert_includes response.body, "(0/100)"
  end

  test "show omits AI hint controls when ai hints disabled" do
    with_ai_hints_config(enabled: false) do
      get practice_path
    end

    assert_response :success
    assert_not_includes response.body, 'data-practice-type-param="visual"'
    assert_not_includes response.body, "data-practice-hint-url-value"
  end

  test "show and check do not query image_ai_hints" do
    with_ai_hints_config(enabled: true) do
      hint_queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*_, payload|
        hint_queries << payload[:sql] if payload[:sql].include?("image_ai_hints")
      end

      get practice_path
      get practice_check_path, params: {
        image_id: @public_image.id,
        lat: @public_image.latitude,
        lng: @public_image.longitude
      }

      assert_empty hint_queries, "image_ai_hints must only load on hint requests"
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end

  test "hint queries image_ai_hints" do
    hint_queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*_, payload|
      hint_queries << payload[:sql] if payload[:sql].include?("image_ai_hints")
    end

    with_ai_hints_config(enabled: true) do
      get practice_hint_path(image_id: @public_image.id, tier: 1), as: :json
    end

    assert_response :success
    assert_not_empty hint_queries, "hint action should read image_ai_hints"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "practice renders with default timer when no seconds provided" do
    get practice_path
    assert_response :success
    assert_includes response.body, 'data-practice-time-limit-value="0"'
  end

  test "practice accepts supported timer duration" do
    get practice_path(seconds: 120)
    assert_response :success
    assert_includes response.body, 'data-practice-time-limit-value="120"'
  end

  test "practice falls back to default duration on unsupported seconds" do
    get practice_path(seconds: 999)
    assert_response :success
    assert_includes response.body, 'data-practice-time-limit-value="60"'
  end

  test "practice accepts two-attempt option" do
    get practice_path(attempts: 2)
    assert_response :success
    assert_includes response.body, 'data-practice-attempts-value="2"'
    assert_includes response.body, "Submit first attempt"
  end

  test "practice enables 4000km hint circle when requested" do
    with_ai_hints_config(enabled: false) do
      get practice_path(hint_circle: 1)
    end

    assert_response :success
    assert_includes response.body, 'data-practice-hint-circle-value="true"'
    assert_includes response.body, "Circle radius"
    assert_includes response.body, "4000 km"
    assert_not_includes response.body, 'data-practice-type-param="visual"'
  end

  test "practice falls back to one attempt on unsupported attempts value" do
    get practice_path(attempts: 9)
    assert_response :success
    assert_includes response.body, 'data-practice-attempts-value="1"'
  end

  test "practice reuses provided image when changing timer options" do
    get practice_path(seconds: 30, image_id: @public_image.id)
    assert_response :success
    assert_includes response.body, "data-practice-image-id-value=\"#{@public_image.id}\""
    assert_includes response.body, 'data-action="practice#setTimer"'
    assert_includes response.body, 'data-practice-seconds-param="60"'
    assert_includes response.body, 'data-action="practice#setAttempts"'
  end

  test "signed in user can practice a saved private image by id" do
    sign_in_as @alice
    get practice_path(image_id: @private_image.id)
    assert_response :success
    assert_includes response.body, "data-practice-image-id-value=\"#{@private_image.id}\""
  end

  test "practice set mode only uses saved set images" do
    sign_in_as @alice
    saved_set = @alice.image_sets.create!(name: "Saved for Practice", visibility: "private", map_style: "outdoor-v2", system_managed: true)
    saved_set.image_set_items.create!(
      image: @public_image,
      latitude: @public_image.latitude,
      longitude: @public_image.longitude
    )
    SavedPracticeImage.create!(user: @alice, image: @public_image)

    get practice_path(practice_set_id: saved_set.id)
    assert_response :success
    assert_includes response.body, "Saved practice set"
    assert_includes response.body, "data-practice-image-id-value=\"#{@public_image.id}\""
    assert_includes response.body, "data-practice-practice-set-id-value=\"#{saved_set.id}\""
  end

  test "completing saved practice set redirects to congratulations page" do
    sign_in_as @alice
    saved_set = @alice.image_sets.create!(name: "Saved for Practice", visibility: "private", map_style: "outdoor-v2", system_managed: true)
    saved_set.image_set_items.create!(
      image: @public_image,
      latitude: @public_image.latitude,
      longitude: @public_image.longitude
    )
    SavedPracticeImage.create!(user: @alice, image: @public_image)

    get practice_path(practice_set_id: saved_set.id, completed_image_id: @public_image.id)
    assert_redirected_to practice_complete_path(practice_set_id: saved_set.id)

    follow_redirect!
    assert_response :success
    assert_includes response.body, "Congratulations"
  end

  test "practice set mode requires sign in" do
    saved_set = ImageSet.create!(name: "Saved for Practice", visibility: "private", map_style: "outdoor-v2", user: @alice, system_managed: true)

    get practice_path(practice_set_id: saved_set.id)
    assert_redirected_to new_session_path
  end

  test "saved practice index requires authentication" do
    get practice_saved_path
    assert_redirected_to new_session_path
  end

  test "signed in user sees only their saved practice images" do
    sign_in_as @alice
    SavedPracticeImage.create!(user: @alice, image: @public_image)
    SavedPracticeImage.create!(user: @bob, image: images(:two))

    get practice_saved_path
    assert_response :success
    assert_includes response.body, @public_image.title
    assert_not_includes response.body, images(:two).title
  end

  test "signed in user can save a visible image for later practice" do
    sign_in_as @alice

    assert_difference("SavedPracticeImage.count", 1) do
      post practice_save_path, params: { image_id: @public_image.id, seconds: 60, attempts: 2 }
    end

    assert_redirected_to practice_path(image_id: @public_image.id, seconds: 60, attempts: 2)
    assert_equal @alice.id, SavedPracticeImage.last.user_id
    assert_equal @public_image.id, SavedPracticeImage.last.image_id
    saved_set = @alice.image_sets.find_by(name: "Saved for Practice")
    assert saved_set.present?
    assert saved_set.image_set_items.exists?(image_id: @public_image.id)
  end

  test "save responds with json for async practice save" do
    sign_in_as @alice

    assert_difference("SavedPracticeImage.count", 1) do
      post practice_save_path, params: { image_id: @public_image.id }, as: :json
    end

    assert_response :success
    assert_equal "saved", JSON.parse(response.body)["status"]
  end

  test "save refuses a private image the user cannot access" do
    sign_in_as @bob

    assert_no_difference("SavedPracticeImage.count") do
      post practice_save_path, params: { image_id: @private_image.id }
    end

    assert_redirected_to practice_path
  end

  test "signed in user can remove saved image from saved list flow" do
    sign_in_as @alice
    SavedPracticeImage.create!(user: @alice, image: @public_image)
    saved_set = @alice.image_sets.create!(name: "Saved for Practice", visibility: "private", map_style: "outdoor-v2", system_managed: true)
    saved_set.image_set_items.create!(image: @public_image, latitude: @public_image.latitude, longitude: @public_image.longitude)

    assert_difference("SavedPracticeImage.count", -1) do
      delete practice_unsave_path(@public_image.id), params: { from_saved: 1 }
    end

    assert_redirected_to practice_saved_path
    assert_not saved_set.image_set_items.exists?(image_id: @public_image.id)
  end

  test "unsave responds with json for async practice remove" do
    sign_in_as @alice
    SavedPracticeImage.create!(user: @alice, image: @public_image)
    saved_set = @alice.image_sets.create!(name: "Saved for Practice", visibility: "private", map_style: "outdoor-v2", system_managed: true)
    saved_set.image_set_items.create!(image: @public_image, latitude: @public_image.latitude, longitude: @public_image.longitude)

    assert_difference("SavedPracticeImage.count", -1) do
      delete practice_unsave_path(@public_image.id), as: :json
    end

    assert_response :success
    assert_equal "removed", JSON.parse(response.body)["status"]
    assert_not saved_set.image_set_items.exists?(image_id: @public_image.id)
  end

  test "check returns coords for system-default image when unauthenticated" do
    get practice_check_path, params: { image_id: @public_image.id, lat: 0, lng: 0 }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_in_delta @public_image.latitude.to_f,  body["answer_lat"], 0.0001
    assert_in_delta @public_image.longitude.to_f, body["answer_lng"], 0.0001
  end

  test "check refuses unauthenticated access to a private-set image" do
    # Privacy regression: previously /practice/check?image_id=N
    # returned the answer coords for any image, leaking GPS from
    # user-uploaded images in private sets to anyone who could
    # enumerate IDs. Must 404 — the image isn't visible to nil.
    get practice_check_path, params: { image_id: @private_image.id, lat: 0, lng: 0 }, as: :json
    assert_response :not_found
  end

  test "check refuses access to another user's private-set image" do
    sign_in_as @bob
    # bob owns no sets containing @private_image, so even authenticated
    # he gets 404.
    get practice_check_path, params: { image_id: @private_image.id, lat: 0, lng: 0 }, as: :json
    assert_response :not_found
  end

  test "check returns coords for own private-set image when signed in" do
    sign_in_as @alice
    get practice_check_path, params: { image_id: @private_image.id, lat: 0, lng: 0 }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_in_delta @private_image.latitude.to_f,  body["answer_lat"], 0.0001
    assert_in_delta @private_image.longitude.to_f, body["answer_lng"], 0.0001
  end

  test "hint returns ai_hints_disabled when feature is off" do
    with_ai_hints_config(enabled: false) do
      get practice_hint_path(image_id: @public_image.id, tier: 1), as: :json
    end

    assert_response :service_unavailable
    assert_equal "ai_hints_disabled", JSON.parse(response.body)["error"]
  end

  test "hint returns ready hint when cached" do
    with_ai_hints_config(enabled: true) do
      get practice_hint_path(image_id: @public_image.id, tier: 1), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ready", body["status"]
    assert_equal "Alpine terrain", body["hint"]
    assert_equal 1, body["tier"]
    assert_equal 0, body["quota_used"]
    assert_equal 100, body["quota_limit"]
    refute_hint_coordinate_leak(body)
  end

  test "hint returns pending when row is pending" do
    with_ai_hints_config(enabled: true) do
      get practice_hint_path(image_id: @public_image.id, tier: 2), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "pending", body["status"]
    assert_equal 2, body["tier"]
    refute_hint_coordinate_leak(body)
  end

  test "hint returns too many requests when daily quota is exceeded" do
    sign_in_as @alice

    with_ai_hints_config(enabled: true) do
      with_memory_cache do
        quota = AiHintDailyQuota.for(user: @alice)
        AiHintDailyQuota::LIMIT.times { quota.record! }

        assert_no_enqueued_jobs only: GenerateAiHintJob do
          assert_no_difference("ImageAiHint.count") do
            get practice_hint_path(image_id: images(:three).id, tier: 3), as: :json
          end
        end
      end
    end

    assert_response :too_many_requests
    body = JSON.parse(response.body)
    assert_equal "failed", body["status"]
    assert_includes body["error"], "Daily AI hint limit"
    assert_equal 3, body["tier"]
    assert_equal 100, body["quota_used"]
    assert_equal 100, body["quota_limit"]
    refute_hint_coordinate_leak(body)
  end

  test "hint serves cached ready hints when daily quota is exceeded" do
    sign_in_as @alice

    with_ai_hints_config(enabled: true) do
      with_memory_cache do
        quota = AiHintDailyQuota.for(user: @alice)
        AiHintDailyQuota::LIMIT.times { quota.record! }

        get practice_hint_path(image_id: @public_image.id, tier: 1), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ready", body["status"]
    assert_equal "Alpine terrain", body["hint"]
    refute_hint_coordinate_leak(body)
  end

  test "hint creates pending row and enqueues job on first request" do
    with_ai_hints_config(enabled: true) do
      with_memory_cache do
        assert_enqueued_with(job: GenerateAiHintJob, args: [ @public_image.id, 3 ]) do
          assert_difference("ImageAiHint.count", 1) do
            get practice_hint_path(image_id: @public_image.id, tier: 3), as: :json
          end
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "pending", body["status"]
    assert_equal 3, body["tier"]
    assert_equal 1, body["quota_used"]
    assert_equal 100, body["quota_limit"]
    hint = ImageAiHint.find_by!(image: @public_image, tier: 3)
    assert_equal "pending", hint.status
    refute_hint_coordinate_leak(body)
  end

  test "hint returns failed without retrying on every poll" do
    failed_image = images(:two)

    with_ai_hints_config(enabled: true) do
      assert_no_enqueued_jobs only: GenerateAiHintJob do
        get practice_hint_path(image_id: failed_image.id, tier: 1), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "failed", body["status"]
    assert_equal AiHintPublicError::UNAVAILABLE_MESSAGE, body["error"]
    assert_equal "failed", image_ai_hints(:two_tier_1).reload.status
    refute_hint_coordinate_leak(body)
  end

  test "hint auto-retries stale failed row without retry param" do
    failed_image = images(:two)
    image_ai_hints(:two_tier_1).update_columns(status: "failed", updated_at: 10.minutes.ago)

    with_ai_hints_config(enabled: true) do
      assert_enqueued_with(job: GenerateAiHintJob, args: [ failed_image.id, 1 ]) do
        get practice_hint_path(image_id: failed_image.id, tier: 1), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "pending", body["status"]
    assert_equal "pending", image_ai_hints(:two_tier_1).reload.status
    refute_hint_coordinate_leak(body)
  end

  test "hint retry after geographic failure does not charge quota twice" do
    failed_image = images(:two)
    image_ai_hints(:two_tier_1).update_columns(
      status: "failed",
      error_message: "Hint failed safety filter after 3 attempts",
      updated_at: 10.minutes.ago
    )

    sign_in_as @alice

    with_ai_hints_config(enabled: true) do
      with_memory_cache do
        get practice_hint_path(image_id: failed_image.id, tier: 1), as: :json
        assert_equal 1, JSON.parse(response.body)["quota_used"]

        image_ai_hints(:two_tier_1).update_columns(
          status: "failed",
          error_message: "Hint failed safety filter after 3 attempts",
          updated_at: 1.minute.ago
        )

        get practice_hint_path(image_id: failed_image.id, tier: 1, retry: 1), as: :json
        assert_equal 1, JSON.parse(response.body)["quota_used"]
      end
    end
  end

  test "hint retries failed row when retry param is set" do
    failed_image = images(:two)

    with_ai_hints_config(enabled: true) do
      assert_enqueued_with(job: GenerateAiHintJob, args: [ failed_image.id, 1 ]) do
        get practice_hint_path(image_id: failed_image.id, tier: 1, retry: 1), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "pending", body["status"]
    assert_equal "pending", image_ai_hints(:two_tier_1).reload.status
    refute_hint_coordinate_leak(body)
  end

  test "hint refuses unauthenticated access to a private-set image" do
    with_ai_hints_config(enabled: true) do
      get practice_hint_path(image_id: @private_image.id, tier: 1), as: :json
    end

    assert_response :not_found
    assert_equal "image_not_found", JSON.parse(response.body)["error"]
  end

  private

  def with_memory_cache
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:memory_store)
    yield
  ensure
    Rails.cache = previous_cache
  end

  def with_ai_hints_config(enabled:)
    previous_enabled = ENV["AI_HINTS_ENABLED"]
    previous_key = ENV["GEMINI_API_KEY"]

    if enabled
      ENV["AI_HINTS_ENABLED"] = "true"
      ENV["GEMINI_API_KEY"] = "test-key"
    else
      ENV.delete("AI_HINTS_ENABLED")
      ENV.delete("GEMINI_API_KEY")
    end

    yield
  ensure
    if previous_enabled.nil?
      ENV.delete("AI_HINTS_ENABLED")
    else
      ENV["AI_HINTS_ENABLED"] = previous_enabled
    end

    if previous_key.nil?
      ENV.delete("GEMINI_API_KEY")
    else
      ENV["GEMINI_API_KEY"] = previous_key
    end
  end

  def refute_hint_coordinate_leak(body)
    %w[answer_lat answer_lng title].each do |key|
      assert_not body.key?(key), "response must not include #{key}"
    end
  end
end
