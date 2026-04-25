require "test_helper"

class GuessesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @alice_guess = guesses(:one)
    @bob_guess = guesses(:two)
  end

  test "redirects unauthenticated user to login" do
    get guesses_url
    assert_redirected_to new_session_url
  end

  test "index only shows own guesses" do
    sign_in_as @alice
    get guesses_url
    assert_response :success
  end

  test "should create guess on own game" do
    sign_in_as @alice
    assert_difference("Guess.count") do
      post guesses_url, params: { guess: { game_id: @alice_guess.game_id, image_id: @alice_guess.image_id, latitude: 1.0, longitude: 2.0 } }
    end
    assert_redirected_to game_url(@alice_guess.game)
  end

  test "cannot create guess on another user's game" do
    sign_in_as @alice
    assert_no_difference("Guess.count") do
      post guesses_url, params: { guess: { game_id: @bob_guess.game_id, image_id: @bob_guess.image_id, latitude: 1.0, longitude: 2.0 } }
    end
    assert_response :not_found
  end

  test "cannot show another user's guess" do
    sign_in_as @alice
    get guess_url(@bob_guess)
    assert_response :not_found
  end
end
