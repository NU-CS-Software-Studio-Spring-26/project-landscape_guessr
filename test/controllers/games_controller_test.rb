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

  test "should get new when signed in" do
    sign_in_as @alice
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
    assert_response :not_found
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
    assert_response :not_found
  end

  test "admin can edit own game" do
    sign_in_as @admin
    admin_game = @admin.games.create!(status: "in_progress")
    get edit_game_url(admin_game)
    assert_response :success
  end
end
