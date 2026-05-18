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

  test "verified user can access games" do
    @user.update!(email_verified_at: Time.current)
    sign_in_as @user
    get games_url
    assert_response :success
  end
end
