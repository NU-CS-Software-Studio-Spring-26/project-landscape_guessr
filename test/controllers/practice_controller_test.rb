require "test_helper"

class PracticeControllerTest < ActionDispatch::IntegrationTest
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
    saved_set = @alice.image_sets.create!(name: "Saved for Practice", visibility: "private", map_style: "outdoor-v2")
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
    saved_set = @alice.image_sets.create!(name: "Saved for Practice", visibility: "private", map_style: "outdoor-v2")
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
end
