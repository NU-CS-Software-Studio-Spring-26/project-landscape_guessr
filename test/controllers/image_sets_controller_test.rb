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

  test "update_locations preserves page and per_page on save" do
    # Regression: the form's hidden :page / :per_page fields feed back
    # into the redirect so the user lands on the same slice they were
    # editing. Without the hidden fields the redirect dropped them and
    # bounced the user to page 1 / default size.
    item = image_set_items(:alice_private_one)
    put locations_image_set_path(image_sets(:alice_private)),
        params: {
          page: "2", per_page: "25",
          image_set_items: { item.id.to_s => { latitude: "10.5", longitude: "20.5" } }
        }
    assert_redirected_to locations_image_set_path(image_sets(:alice_private), page: "2", per_page: "25")
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
    # alice_only image is NOT in the default set, so the editable_by?
    # guard lets the title propagate. (The previous version of this
    # test used alice_private_one — image_one — which is in the
    # default set and is now correctly locked from non-admin edits.)
    item = image_set_items(:alice_private_alice_only)
    original = item.image.title
    put locations_image_set_path(image_sets(:alice_private)),
        params: { image_set_items: { item.id.to_s => { title: "Renamed", latitude: item.latitude.to_s, longitude: item.longitude.to_s } } }
    assert_redirected_to locations_image_set_path(image_sets(:alice_private))
    assert_equal "Renamed", item.image.reload.title
  ensure
    item&.image&.update(title: original) if original
  end

  test "update_locations rejects title change on default-set image" do
    # Vandalism guard: image_one is in the default set AND in alice's
    # private set. Without the editable_by? check on the bulk-edit
    # path, alice could rename it here and propagate the change to
    # every default-set game. Coords still update (those are per-set
    # overrides on ImageSetItem, not on the canonical Image).
    item = image_set_items(:alice_private_one)
    original_title = item.image.title
    put locations_image_set_path(image_sets(:alice_private)),
        params: { image_set_items: { item.id.to_s => { title: "Vandalized", latitude: "1.5", longitude: "2.5" } } }
    assert_response :unprocessable_entity
    assert_match(/locked.*default set/i, flash.now[:alert].to_s)
    assert_equal original_title, item.image.reload.title
  end

  test "add_image creates item with validated https URL and coordinates" do
    set = image_sets(:alice_private)
    url = "https://example.com/unique-#{SecureRandom.hex(4)}.jpg"

    assert_difference("ImageSetItem.count", 1) do
      post add_image_image_set_path(set),
           params: {
             url: url, title: "New spot",
             latitude: "46.2", longitude: "7.1"
           },
           headers: { "Referer" => locations_image_set_path(set) }
    end

    item = set.image_set_items.joins(:image).find_by!(images: { url: url })
    assert_in_delta 46.2, item.latitude.to_f
    assert_in_delta 7.1, item.longitude.to_f
    assert_equal "New spot", item.image.title
  end

  test "add_image rejects http URL and missing coordinates" do
    set = image_sets(:alice_private)

    assert_no_difference("ImageSetItem.count") do
      post add_image_image_set_path(set),
           params: { url: "http://example.com/bad.jpg", title: "X" },
           headers: { "Referer" => locations_image_set_path(set) }
    end
    assert_match(/https/i, flash[:alert])

    assert_no_difference("ImageSetItem.count") do
      post add_image_image_set_path(set),
           params: {
             url: "https://example.com/ok.jpg", title: "X",
             latitude: "", longitude: "7.0"
           },
           headers: { "Referer" => locations_image_set_path(set) }
    end
    assert_match(/required/i, flash[:alert])
  end
end
