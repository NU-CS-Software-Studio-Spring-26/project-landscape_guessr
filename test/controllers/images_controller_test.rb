require "test_helper"

class ImagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @image      = images(:one)
    # alice owns alice_private + alice_public, both of which contain
    # @image — so alice is a set-owner of the image (non-admin but
    # editable_by? returns true). bob owns no sets, so he's the
    # non-admin / non-owner case.
    @owner      = users(:alice)
    @nonowner   = users(:bob)
    @admin      = users(:admin)
  end

  test "should get index without auth" do
    get images_url
    assert_response :success
  end

  test "should show image without auth" do
    get image_url(@image)
    assert_response :success
  end

  test "admin sees New image on index" do
    # Edit / Destroy moved to /images/:id; only "New image" remains
    # on the gallery header.
    sign_in_as @admin
    get images_url
    assert_select "a", text: "New image"
  end

  test "non-admin does not see New image on index" do
    sign_in_as @nonowner
    get images_url
    assert_select "a", text: "New image", count: 0
  end

  test "non-admin cannot get new" do
    sign_in_as @nonowner
    get new_image_url
    assert_redirected_to root_path
  end

  test "non-admin cannot create" do
    sign_in_as @nonowner
    assert_no_difference("Image.count") do
      post images_url, params: { image: { latitude: @image.latitude, longitude: @image.longitude, title: @image.title, url: @image.url } }
    end
    assert_redirected_to root_path
  end

  test "non-owner cannot edit" do
    # bob owns no sets containing @image → editable_by? is false →
    # redirected to the detail page with a flash, not root.
    sign_in_as @nonowner
    get edit_image_url(@image)
    assert_redirected_to image_url(@image)
  end

  test "non-owner cannot update" do
    sign_in_as @nonowner
    patch image_url(@image), params: { image: { title: "Hacked" } }
    assert_redirected_to image_url(@image)
    assert_not_equal "Hacked", @image.reload.title
  end

  test "set-owner can edit" do
    # alice owns alice_private which contains @image → editable_by?
    # returns true even though she's not admin.
    sign_in_as @owner
    get edit_image_url(@image)
    assert_response :success
  end

  test "set-owner can update title and coords" do
    sign_in_as @owner
    patch image_url(@image), params: { image: { title: "Renamed by owner", latitude: 1.23, longitude: 4.56 } }
    assert_redirected_to image_url(@image)
    @image.reload
    assert_equal "Renamed by owner", @image.title
    assert_equal 1.23.to_d, @image.latitude
    assert_equal 4.56.to_d, @image.longitude
  end

  test "set-owner cannot change url (admin-only field)" do
    # image_params strips :url for non-admins so a set-owner can't
    # silently swap the underlying source out from under other set
    # members. Other fields still update.
    sign_in_as @owner
    original_url = @image.url
    patch image_url(@image), params: { image: { title: "Title change", url: "https://evil.example.com/x.jpg" } }
    assert_redirected_to image_url(@image)
    @image.reload
    assert_equal "Title change", @image.title
    assert_equal original_url, @image.url
  end

  test "non-admin cannot destroy" do
    sign_in_as @nonowner
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
