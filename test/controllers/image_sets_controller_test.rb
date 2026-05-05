require "test_helper"

class ImageSetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob   = users(:bob)
    sign_in_as @alice
  end

  test "index shows my sets and public sets" do
    get image_sets_path
    assert_response :success
  end

  test "create makes a new set for current user" do
    assert_difference("ImageSet.count", 1) do
      post image_sets_path, params: { image_set: { name: "New Set", visibility: "private" } }
    end
    set = ImageSet.last
    assert_equal @alice, set.user
    # New sets land on the manage-images page so the user can immediately
    # upload — see ImageSetsController#create.
    assert_redirected_to locations_image_set_path(set)
  end

  test "show is accessible for public set by any logged-in user" do
    get image_set_path(image_sets(:alice_public))
    assert_response :success
  end

  test "show redirects for private set owned by other user" do
    sign_in_as @bob
    get image_set_path(image_sets(:alice_private))
    assert_redirected_to image_sets_path
  end

  test "edit is forbidden for non-owner of private set" do
    sign_in_as @bob
    # set_image_set denies access to private sets not owned by the user
    get edit_image_set_path(image_sets(:alice_private))
    assert_redirected_to image_sets_path
  end

  test "edit is forbidden for non-owner of public set" do
    sign_in_as @bob
    get edit_image_set_path(image_sets(:alice_public))
    assert_redirected_to image_set_path(image_sets(:alice_public))
  end

  test "locations edit screen is accessible to owner" do
    get locations_image_set_path(image_sets(:alice_private))
    assert_response :success
  end

  test "update_locations saves new coords for owner" do
    item = image_set_items(:alice_private_one)
    put locations_image_set_path(image_sets(:alice_private)),
        params: { image_set_items: { item.id.to_s => { latitude: "10.5", longitude: "20.5" } } }
    assert_redirected_to locations_image_set_path(image_sets(:alice_private))
    assert_equal 10.5, item.reload.latitude.to_f
  end

  test "destroy deletes the set" do
    set = @alice.image_sets.create!(name: "Temp", visibility: "private")
    assert_difference("ImageSet.count", -1) do
      delete image_set_path(set)
    end
    assert_redirected_to image_sets_path
  end

  test "remove_item destroys the item and redirects with a flash" do
    # Regression: the remove_item route nests under :image_set_id, not :id,
    # so set_image_set used to read params[:id] and raise RecordNotFound.
    item = image_set_items(:alice_private_one)
    assert_difference("ImageSetItem.count", -1) do
      delete image_set_remove_item_path(image_sets(:alice_private), item),
             headers: { "Referer" => locations_image_set_path(image_sets(:alice_private)) }
    end
    assert_redirected_to locations_image_set_path(image_sets(:alice_private))
    assert_match(/removed/i, flash[:notice])
  end

  test "update_locations saves a new title (delegating to Image)" do
    item = image_set_items(:alice_private_one)
    original = item.image.title
    put locations_image_set_path(image_sets(:alice_private)),
        params: { image_set_items: { item.id.to_s => { title: "Renamed", latitude: item.latitude.to_s, longitude: item.longitude.to_s } } }
    assert_redirected_to locations_image_set_path(image_sets(:alice_private))
    assert_equal "Renamed", item.image.reload.title
  ensure
    item&.image&.update(title: original) if original
  end
end
