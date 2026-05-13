require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "should get start" do
    get root_url
    assert_response :success
  end

  test "should get scoring while signed out" do
    get scoring_url
    assert_response :success
    assert_select "h1", text: /How scoring works/i
  end

  test "should get scoring while signed in" do
    sign_in_as users(:alice)
    get scoring_url
    assert_response :success
  end
end
