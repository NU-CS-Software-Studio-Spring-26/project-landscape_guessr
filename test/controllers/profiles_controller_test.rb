require "test_helper"

class ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @bob   = users(:bob)
    @admin = users(:admin)
  end

  # --- show ---

  test "unauthenticated user is redirected from /profile" do
    get profile_url
    assert_redirected_to new_session_url
  end

  test "authenticated user sees their profile with the delete-account form" do
    sign_in_as @alice
    get profile_url
    assert_response :success
    assert_select "form[action=?][method=post]", profile_path do
      assert_select "input[name=_method][value=delete]"
      assert_select "input[name=confirm_email]"
      assert_select "input[name=current_password]"
    end
  end

  # --- destroy: auth ---

  test "unauthenticated DELETE /profile is redirected to login" do
    delete profile_url, params: { confirm_email: "anything@example.com" }
    assert_redirected_to new_session_url
    assert_not_nil User.find_by(id: @alice.id)
  end

  # --- destroy: confirmation checks ---

  test "DELETE without confirm_email is rejected" do
    sign_in_as @alice
    assert_no_difference -> { User.count } do
      delete profile_url, params: { current_password: "password123" }
    end
    assert_redirected_to profile_path
    assert_match(/email/i, flash[:alert])
  end

  test "DELETE with wrong confirm_email is rejected" do
    sign_in_as @alice
    assert_no_difference -> { User.count } do
      delete profile_url, params: {
        confirm_email: "not-alice@example.com",
        current_password: "password123"
      }
    end
    assert_redirected_to profile_path
  end

  test "DELETE with wrong password is rejected" do
    sign_in_as @alice
    assert_no_difference -> { User.count } do
      delete profile_url, params: {
        confirm_email: @alice.email_address,
        current_password: "wrong-password"
      }
    end
    assert_redirected_to profile_path
    assert_match(/password/i, flash[:alert])
  end

  test "confirm_email comparison is case-insensitive and trims whitespace" do
    sign_in_as @alice
    assert_difference -> { User.count } => -1 do
      delete profile_url, params: {
        confirm_email: "  #{@alice.email_address.upcase}  ",
        current_password: "password123"
      }
    end
    assert_redirected_to root_path
  end

  # --- destroy: happy path ---

  test "DELETE with correct password + email destroys account and signs out" do
    sign_in_as @alice
    alice_id = @alice.id
    sessions_before = Session.where(user_id: alice_id).count
    assert_difference -> { User.count } => -1,
                      -> { Session.where(user_id: alice_id).count } => -sessions_before do
      delete profile_url, params: {
        confirm_email: @alice.email_address,
        current_password: "password123"
      }
    end
    assert_redirected_to root_path
    assert_nil User.find_by(id: alice_id)
    # Subsequent request behaves as logged-out
    get profile_url
    assert_redirected_to new_session_url
  end

  test "destroy cascades to games, guesses, game_images, and owned image_sets" do
    sign_in_as @alice
    alice_game_ids = @alice.games.pluck(:id)
    alice_set_ids  = @alice.image_sets.pluck(:id)
    assert alice_game_ids.any?
    assert alice_set_ids.any?

    delete profile_url, params: {
      confirm_email: @alice.email_address,
      current_password: "password123"
    }
    assert_redirected_to root_path

    assert_empty Game.where(id: alice_game_ids)
    assert_empty Guess.where(game_id: alice_game_ids)
    assert_empty GameImage.where(game_id: alice_game_ids)
    assert_empty ImageSet.where(id: alice_set_ids)
  end

  # --- destroy: shared-data preservation ---

  test "destroy preserves the system default image set" do
    sign_in_as @alice
    default_set_id = image_sets(:default).id

    delete profile_url, params: {
      confirm_email: @alice.email_address,
      current_password: "password123"
    }

    assert ImageSet.exists?(default_set_id), "system default ImageSet must survive"
  end

  test "destroy preserves images shared with the system default set" do
    sign_in_as @alice
    # image "one" lives in default + alice_private + alice_public — survives
    shared_image_id = images(:one).id

    delete profile_url, params: {
      confirm_email: @alice.email_address,
      current_password: "password123"
    }

    assert Image.exists?(shared_image_id), "shared image (also in default set) must survive"
  end

  test "destroy removes images that lived only in the deleted user's sets" do
    sign_in_as @alice
    # alice_only image is only in alice_private — orphan-sweep should destroy it
    alice_only_id = images(:alice_only).id

    delete profile_url, params: {
      confirm_email: @alice.email_address,
      current_password: "password123"
    }

    assert_nil Image.find_by(id: alice_only_id),
               "image only in deleted user's set should be cleaned up"
  end

  test "destroy preserves images that also live in another user's set" do
    # Move alice_only into bob's brand-new set so it's shared cross-user
    bob_set = ImageSet.create!(user: @bob, name: "Bob's Set", visibility: "private")
    ImageSetItem.create!(image_set: bob_set, image: images(:alice_only))
    shared_id = images(:alice_only).id

    sign_in_as @alice
    delete profile_url, params: {
      confirm_email: @alice.email_address,
      current_password: "password123"
    }

    assert Image.exists?(shared_id),
           "image shared with another user's set must survive deletion"
  end

  test "destroy preserves another user's games on the deleted user's public set, nullifying image_set_id" do
    alice_public = image_sets(:alice_public)
    bob_game = Game.create!(user: @bob, image_set: alice_public, status: "completed",
                            score: 1234, completed_at: 1.hour.ago)

    sign_in_as @alice
    delete profile_url, params: {
      confirm_email: @alice.email_address,
      current_password: "password123"
    }

    bob_game.reload
    assert_equal @bob.id, bob_game.user_id
    assert_nil bob_game.image_set_id, "ImageSet#dependent: :nullify should clear the FK"
  end

  test "destroy preserves other users' connected services" do
    @bob.connected_services.create!(provider: "google_oauth2", uid: "bob-uid", email: @bob.email_address)
    @alice.connected_services.create!(provider: "google_oauth2", uid: "alice-uid", email: @alice.email_address)

    sign_in_as @alice
    delete profile_url, params: {
      confirm_email: @alice.email_address,
      current_password: "password123"
    }

    assert ConnectedService.exists?(provider: "google_oauth2", uid: "bob-uid")
    assert_not ConnectedService.exists?(provider: "google_oauth2", uid: "alice-uid")
  end

  # --- destroy: admin edge cases ---

  test "sole admin cannot delete their account" do
    sign_in_as @admin
    assert_no_difference -> { User.count } do
      delete profile_url, params: {
        confirm_email: @admin.email_address,
        current_password: "password123"
      }
    end
    assert_redirected_to profile_path
    assert_match(/admin/i, flash[:alert])
  end

  test "admin can delete their account if another admin exists" do
    User.create!(email_address: "second-admin@example.com", username: "secondadmin",
                 password: "password123", admin: true, email_verified_at: 1.day.ago)
    sign_in_as @admin
    assert_difference -> { User.count } => -1 do
      delete profile_url, params: {
        confirm_email: @admin.email_address,
        current_password: "password123"
      }
    end
  end

  # --- destroy: OAuth-only user (no password_digest) ---

  # OAuth users always have an auto-generated random password they never
  # see (see Sessions::OmniAuthsController#build_oauth_user). The delete
  # form skips the password input for users with a ConnectedService and
  # the controller skips the password check.
  test "OAuth-linked user can delete without providing a password" do
    oauth_user = create_oauth_user("oauth@example.com", "oauthuser", uid: "oauth-uid")
    sign_in_as oauth_user

    # No current_password in params — the controller must skip the check
    # since the user has a ConnectedService.
    assert_difference -> { User.count } => -1 do
      delete profile_url, params: { confirm_email: oauth_user.email_address }
    end
    assert_redirected_to root_path
  end

  test "OAuth-linked user with wrong email confirmation is rejected" do
    oauth_user = create_oauth_user("oauth2@example.com", "oauthuser2", uid: "oauth-uid-2")
    sign_in_as oauth_user

    assert_no_difference -> { User.count } do
      delete profile_url, params: { confirm_email: "wrong@example.com" }
    end
    assert_redirected_to profile_path
  end

  private

  # OAuth users in production get an auto-generated password they never
  # see (see Sessions::OmniAuthsController#build_oauth_user); for the
  # test we pick a known one so sign_in_as can POST through the session
  # endpoint, but the "OAuth-linked" branch in the controller fires based
  # on ConnectedService presence, not whether the password is known.
  def create_oauth_user(email, username, uid:)
    user = User.create!(email_address: email, username: username,
                        password: "password123", password_confirmation: "password123",
                        email_verified_at: 1.day.ago)
    user.connected_services.create!(provider: "google_oauth2", uid: uid, email: email)
    user
  end
end
