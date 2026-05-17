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

  test "home links directly to saved practice image set when it exists" do
    alice = users(:alice)
    sign_in_as alice
    set = alice.image_sets.create!(
      name: ImageSet::SAVED_FOR_PRACTICE_NAME,
      visibility: "private",
      map_style: "outdoor-v2"
    )

    get root_url
    assert_response :success
    assert_select "a[href=?]", image_set_path(set) do
      assert_select "p", text: "Saved for Practice Set"
      assert_select "p", text: "Image set for practice mistakes"
    end
  end

  test "home links to saved-practice flow when image set is not created yet" do
    sign_in_as users(:alice)

    get root_url
    assert_response :success
    assert_select "a[href=?]", practice_saved_path do
      assert_select "p", text: "Saved for Practice Set"
      assert_select "p", text: "Image set for practice mistakes"
    end
  end
end
