require "test_helper"

class Sessions::OmniAuthsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
  end

  def mock_google(uid:, email:, email_verified: true)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, email_verified: email_verified, name: "Test" }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]
  end

  test "existing connected_service signs in that user" do
    user = users(:alice)
    user.connected_services.create!(provider: "google_oauth2", uid: "google-123")
    mock_google(uid: "google-123", email: "alice@example.com")

    get "/auth/google_oauth2/callback"
    assert_redirected_to root_url
    follow_redirect!
    assert_response :success
  end

  test "auto-links Google identity to existing user when email_verified is true" do
    user = users(:alice)
    assert_equal 0, user.connected_services.count
    mock_google(uid: "google-NEW", email: "alice@example.com", email_verified: true)

    assert_difference -> { ConnectedService.count }, 1 do
      get "/auth/google_oauth2/callback"
    end
    assert_redirected_to root_url
    assert_equal user, ConnectedService.find_by(provider: "google_oauth2", uid: "google-NEW").user
  end

  test "refuses to auto-link when email_verified is false" do
    users(:alice)
    mock_google(uid: "google-XYZ", email: "alice@example.com", email_verified: false)

    assert_no_difference -> { ConnectedService.count } do
      get "/auth/google_oauth2/callback"
    end
    assert_redirected_to new_session_path
    assert_match(/confirm/i, flash[:alert])
  end

  test "creates new user with no username and redirects to setup" do
    mock_google(uid: "google-NEW2", email: "newperson@example.com", email_verified: true)

    assert_difference -> { User.count }, 1 do
      assert_difference -> { ConnectedService.count }, 1 do
        get "/auth/google_oauth2/callback"
      end
    end

    user = User.find_by(email_address: "newperson@example.com")
    assert_nil user.username
    assert_redirected_to setup_username_profile_path
  end

  test "missing email is rejected" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "no-email", info: { email: nil, email_verified: true }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]

    get "/auth/google_oauth2/callback"
    assert_redirected_to new_session_path
  end

  test "failure path redirects with alert" do
    get "/auth/failure"
    assert_redirected_to new_session_path
    assert flash[:alert].present?
  end
end
