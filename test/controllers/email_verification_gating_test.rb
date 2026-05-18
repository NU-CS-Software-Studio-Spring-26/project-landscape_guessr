require "test_helper"

class EmailVerificationGatingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alice)
    @user.update!(email_verified_at: nil)
  end

  test "unverified user is blocked from games" do
    sign_in_as @user
    get games_url
    assert_redirected_to root_path
  end

  test "unverified user is blocked from creating image sets" do
    sign_in_as @user
    get image_sets_url
    assert_redirected_to root_path
  end

  test "unverified user can still view home page" do
    sign_in_as @user
    get root_url
    assert_response :success
  end

  test "unverified user can still view public images" do
    sign_in_as @user
    get images_url
    assert_response :success
  end

  test "unverified user can still access practice mode" do
    sign_in_as @user
    get practice_url
    assert_response :success
  end

  test "unverified user can view their saved for practice set" do
    sign_in_as @user
    set = @user.image_sets.create!(
      name: ImageSet::SAVED_FOR_PRACTICE_NAME,
      visibility: "private",
      map_style: "outdoor-v2",
      system_managed: true
    )

    get image_set_url(set)
    assert_response :success
  end

  test "unverified user is blocked from viewing other sets" do
    sign_in_as @user
    get image_set_url(image_sets(:alice_public))
    assert_redirected_to root_path
  end

  test "verified user can access games" do
    @user.update!(email_verified_at: Time.current)
    sign_in_as @user
    get games_url
    assert_response :success
  end
end
