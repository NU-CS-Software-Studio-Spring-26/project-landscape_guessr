require "test_helper"

class GamesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob   = users(:bob)
    @admin = users(:admin)
    @alice_game = games(:one)
    @bob_game   = games(:two)
  end

  test "redirects unauthenticated user to login" do
    get games_url
    assert_redirected_to new_session_url
  end

  test "should get index when signed in" do
    sign_in_as @alice
    get games_url
    assert_response :success
  end

  test "index honors valid ?per_page=" do
    sign_in_as @alice
    get games_url(per_page: 25)
    assert_response :success
    # Custom dropdown shows current per_page in the label
    assert_select "span[data-dropdown-target='label']", text: "25"
    # Dropdown buttons have per_page=25 in their URLs
    assert_select "button[data-action='dropdown#pick'][data-url*='per_page=25']"
  end

  test "index falls back to default for out-of-allowlist ?per_page=" do
    sign_in_as @alice
    get games_url(per_page: 999)
    assert_response :success
    # Should fall back to 100 (default), shown in dropdown label
    assert_select "span[data-dropdown-target='label']", text: "100"
    # Dropdown buttons have per_page=100 in their URLs
    assert_select "button[data-action='dropdown#pick'][data-url*='per_page=100']"
  end

  test "index filter chips preserve per_page" do
    sign_in_as @alice
    get games_url(per_page: 50)
    assert_response :success
    assert_select "a.rounded-full[href*='per_page=50']"
  end

  test "non-admin redirected from /games/new" do
    sign_in_as @alice
    get new_game_url
    assert_redirected_to root_path
  end

  test "admin can get /games/new" do
    sign_in_as @admin
    get new_game_url
    assert_response :success
  end

  test "should create game and materialize 5 game_images" do
    sign_in_as @alice
    assert_difference -> { Game.count } => 1, -> { GameImage.count } => 5 do
      post games_url
    end
    game = Game.last
    assert_equal @alice, game.user
    assert_equal (1..5).to_a, game.game_images.order(:position).pluck(:position)
    assert_redirected_to game_url(game)
  end

  test "should show own game" do
    sign_in_as @alice
    get game_url(@alice_game)
    assert_response :success
  end

  test "should not show another user's game" do
    sign_in_as @alice
    get game_url(@bob_game)
    # ApplicationController#rescue_from ActiveRecord::RecordNotFound rewrites
    # `Current.user.games.find(other_users_game)` into a friendly redirect with
    # a flash, instead of letting the bare 404 leak out.
    assert_redirected_to root_path
    assert_match(/couldn't find/i, flash[:alert])
  end

  test "non-admin cannot edit own game" do
    sign_in_as @alice
    get edit_game_url(@alice_game)
    assert_redirected_to root_path
  end

  test "non-admin cannot update own game's score" do
    sign_in_as @alice
    original_score = @alice_game.score
    patch game_url(@alice_game), params: { game: { score: 0 } }
    assert_redirected_to root_path
    assert_equal original_score, @alice_game.reload.score
  end

  test "should destroy own game" do
    sign_in_as @alice
    assert_difference("Game.count", -1) do
      delete game_url(@alice_game)
    end
    assert_redirected_to games_url
  end

  test "should not destroy another user's game" do
    sign_in_as @alice
    assert_no_difference("Game.count") do
      delete game_url(@bob_game)
    end
    # See above — RecordNotFound is rescued globally and rendered as a redirect.
    assert_redirected_to root_path
  end

  test "admin can edit own game" do
    sign_in_as @admin
    admin_game = @admin.games.create!(status: "in_progress")
    get edit_game_url(admin_game)
    assert_response :success
  end

  test "create game uses default image set when no image_set_id given" do
    sign_in_as @alice
    post games_url
    game = Game.order(:created_at).last
    assert game.image_set.is_system_default?
  end

  test "create game uses specified public set" do
    sign_in_as @alice
    set = image_sets(:alice_public)
    assert_difference -> { Game.count } => 1 do
      post games_url, params: { image_set_id: set.id }
    end
    assert_redirected_to game_url(Game.last)
    assert_equal set, Game.last.image_set
  end

  test "create game rejects private set owned by another user" do
    sign_in_as @bob
    set = image_sets(:alice_private)
    assert_no_difference("Game.count") do
      post games_url, params: { image_set_id: set.id }
    end
    assert_redirected_to root_path
  end

  test "game_images store answer snapshot coords" do
    sign_in_as @alice
    post games_url
    game = Game.order(:created_at).last
    game.game_images.each do |gi|
      assert_not_nil gi.answer_latitude
      assert_not_nil gi.answer_longitude
    end
  end

  test "create skips items missing coords and refuses if too few remain" do
    # Regression: previously we'd silently include no-coord items and every
    # round's "answer" would be (0, 0). Now we filter at the DB level and
    # refuse to start if fewer than TOTAL_ROUNDS items have coordinates.
    sign_in_as @alice
    set = @alice.image_sets.create!(name: "Sparse", visibility: "private")
    no_coord = Image.create!(title: "No coords")
    set.image_set_items.create!(image: no_coord)
    4.times do |i|
      img = Image.create!(title: "With coords #{i}", latitude: 10 + i, longitude: 20 + i)
      set.image_set_items.create!(image: img, latitude: 10 + i, longitude: 20 + i)
    end

    assert_no_difference("Game.count") do
      post games_url, params: { image_set_id: set.id }
    end
    assert_redirected_to root_path
    assert_match(/coordinates/i, flash[:alert])
  end
end
