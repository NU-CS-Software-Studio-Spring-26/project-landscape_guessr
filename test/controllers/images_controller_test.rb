require "test_helper"

class ImagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @image = images(:one)
    @user = users(:alice)
  end

  test "should get index without auth" do
    get images_url
    assert_response :success
  end

  test "should show image without auth" do
    get image_url(@image)
    assert_response :success
  end

  test "new image requires auth" do
    get new_image_url
    assert_redirected_to new_session_url
  end

  test "should get new when signed in" do
    sign_in_as @user
    get new_image_url
    assert_response :success
  end

  test "should create image when signed in" do
    sign_in_as @user
    assert_difference("Image.count") do
      post images_url, params: { image: { latitude: @image.latitude, longitude: @image.longitude, title: @image.title, url: @image.url } }
    end

    assert_redirected_to image_url(Image.last)
  end

  test "should get edit when signed in" do
    sign_in_as @user
    get edit_image_url(@image)
    assert_response :success
  end

  test "should update image when signed in" do
    sign_in_as @user
    patch image_url(@image), params: { image: { latitude: @image.latitude, longitude: @image.longitude, title: @image.title, url: @image.url } }
    assert_redirected_to image_url(@image)
  end

  test "should destroy image when signed in" do
    sign_in_as @user
    assert_difference("Image.count", -1) do
      delete image_url(@image)
    end

    assert_redirected_to images_url
  end
end
