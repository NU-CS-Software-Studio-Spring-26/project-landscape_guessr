require "test_helper"

class ImagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @image = images(:one)
    @user  = users(:alice)
    @admin = users(:admin)
  end

  test "should get index without auth" do
    get images_url
    assert_response :success
  end

  test "should show image without auth" do
    get image_url(@image)
    assert_response :success
  end

  test "admin sees New/Edit/Destroy on index" do
    sign_in_as @admin
    get images_url
    assert_select "a", text: "New image"
    assert_select "a", text: "Edit"
  end

  test "non-admin does not see New/Edit on index" do
    sign_in_as @user
    get images_url
    assert_select "a", text: "New image", count: 0
    assert_select "a", text: "Edit", count: 0
  end

  test "non-admin cannot get new" do
    sign_in_as @user
    get new_image_url
    assert_redirected_to root_path
  end

  test "non-admin cannot create" do
    sign_in_as @user
    assert_no_difference("Image.count") do
      post images_url, params: { image: { latitude: @image.latitude, longitude: @image.longitude, title: @image.title, url: @image.url } }
    end
    assert_redirected_to root_path
  end

  test "non-admin cannot edit" do
    sign_in_as @user
    get edit_image_url(@image)
    assert_redirected_to root_path
  end

  test "non-admin cannot update" do
    sign_in_as @user
    patch image_url(@image), params: { image: { title: "Hacked" } }
    assert_redirected_to root_path
    assert_not_equal "Hacked", @image.reload.title
  end

  test "non-admin cannot destroy" do
    sign_in_as @user
    assert_no_difference("Image.count") do
      delete image_url(@image)
    end
    assert_redirected_to root_path
  end

  test "admin can get new" do
    sign_in_as @admin
    get new_image_url
    assert_response :success
  end

  test "admin can create" do
    sign_in_as @admin
    assert_difference("Image.count") do
      post images_url, params: { image: { latitude: @image.latitude, longitude: @image.longitude, title: @image.title, url: "https://example.com/new.jpg" } }
    end
    assert_redirected_to image_url(Image.last)
  end

  test "admin can edit" do
    sign_in_as @admin
    get edit_image_url(@image)
    assert_response :success
  end

  test "admin can update" do
    sign_in_as @admin
    patch image_url(@image), params: { image: { latitude: @image.latitude, longitude: @image.longitude, title: "Renamed", url: @image.url } }
    assert_redirected_to image_url(@image)
    assert_equal "Renamed", @image.reload.title
  end

  test "admin can destroy" do
    sign_in_as @admin
    assert_difference("Image.count", -1) do
      delete image_url(@image)
    end
    assert_redirected_to images_url
  end
end
