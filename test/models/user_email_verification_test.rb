require "test_helper"

class UserEmailVerificationTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
  end

  test "email_verified? is true when email_verified_at is set" do
    @user.email_verified_at = Time.current
    assert @user.email_verified?
  end

  test "email_verified? is true when user has connected services (OAuth)" do
    @user.email_verified_at = nil
    @user.connected_services.build(provider: "google_oauth2", uid: "123")
    assert @user.email_verified?
  end

  test "email_verified? is false when no verification and no connected services" do
    @user.email_verified_at = nil
    @user.connected_services.clear
    assert_not @user.email_verified?
  end

  test "generates and finds by email verification token" do
    @user.update!(email_verified_at: nil)
    token = @user.generate_token_for(:email_verification)
    assert_equal @user, User.find_by_email_verification_token(token)
  end

  test "token invalidates after email_verified_at changes" do
    @user.update!(email_verified_at: nil)
    token = @user.generate_token_for(:email_verification)
    @user.update!(email_verified_at: Time.current)
    assert_nil User.find_by_email_verification_token(token)
  end

  test "bogus token returns nil" do
    assert_nil User.find_by_email_verification_token("not-a-real-token")
  end
end
