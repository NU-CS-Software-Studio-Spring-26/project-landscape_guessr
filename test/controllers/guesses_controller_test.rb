require "test_helper"

class GuessesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob   = users(:bob)
    @admin = users(:admin)
    @alice_guess = guesses(:one)
    @bob_guess   = guesses(:two)
  end

  test "redirects unauthenticated user to login" do
    get guesses_url
    assert_redirected_to new_session_url
  end

  test "non-admin redirected from /guesses index" do
    sign_in_as @alice
    get guesses_url
    assert_redirected_to root_path
  end

  test "admin can view /guesses index" do
    sign_in_as @admin
    get guesses_url
    assert_response :success
  end

  test "should create guess on own game" do
    sign_in_as @alice
    # Use a fresh (game, image) — fixture :one already guessed image one,
    # and Guess uniqueness on (game_id, image_id) blocks duplicates.
    assert_difference("Guess.count") do
      post guesses_url, params: { guess: { game_id: @alice_guess.game_id, image_id: images(:two).id, latitude: 1.0, longitude: 2.0 } }
    end
    assert_redirected_to game_url(@alice_guess.game)
  end

  test "rejects guess with missing latitude" do
    sign_in_as @alice
    assert_no_difference("Guess.count") do
      post guesses_url, params: { guess: { game_id: @alice_guess.game_id, image_id: images(:two).id, latitude: "", longitude: 2.0 } }
    end
  end

  test "rejects duplicate guess for same (game, image)" do
    sign_in_as @alice
    assert_no_difference("Guess.count") do
      post guesses_url, params: { guess: { game_id: @alice_guess.game_id, image_id: @alice_guess.image_id, latitude: 1.0, longitude: 2.0 } }
    end
  end

  test "cannot create guess on another user's game" do
    sign_in_as @alice
    assert_no_difference("Guess.count") do
      post guesses_url, params: { guess: { game_id: @bob_guess.game_id, image_id: @bob_guess.image_id, latitude: 1.0, longitude: 2.0 } }
    end
    # Current.user.games.find(other_user.game) raises RecordNotFound, which is
    # rescued globally in ApplicationController and turned into a redirect.
    assert_redirected_to root_path
  end

  test "non-admin redirected from another user's guess show" do
    sign_in_as @alice
    get guess_url(@bob_guess)
    assert_redirected_to root_path
  end

  test "non-admin cannot edit own guess" do
    sign_in_as @alice
    get edit_guess_url(@alice_guess)
    assert_redirected_to root_path
  end

  test "non-admin cannot destroy own guess" do
    sign_in_as @alice
    assert_no_difference("Guess.count") do
      delete guess_url(@alice_guess)
    end
    assert_redirected_to root_path
  end
end
