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
