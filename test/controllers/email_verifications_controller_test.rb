require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alice)
  end

  # --- show (clicking the verification link) ---

  test "valid token verifies the user" do
    @user.update!(email_verified_at: nil)
    token = @user.generate_token_for(:email_verification)

    get email_verification_url(token: token)
    assert_redirected_to root_path
    assert_equal "Email verified successfully!", flash[:notice]
    assert_not_nil @user.reload.email_verified_at
  end

  test "expired or invalid token shows error" do
    get email_verification_url(token: "bogus")
    assert_redirected_to root_path
    assert_equal "Verification link is invalid or has expired.", flash[:alert]
  end

  test "token becomes invalid after user is already verified" do
    @user.update!(email_verified_at: nil)
    token = @user.generate_token_for(:email_verification)
    @user.update!(email_verified_at: Time.current)

    get email_verification_url(token: token)
    assert_redirected_to root_path
    assert_match /invalid or has expired/, flash[:alert]
  end

  # --- create (resend verification email) ---

  test "resend sends email for unverified user" do
    @user.update!(email_verified_at: nil)
    sign_in_as @user

    assert_enqueued_emails 1 do
      post email_verification_url
    end
    assert_redirected_to root_path
    assert_match /Verification email sent/, flash[:notice]
  end

  test "resend skips sending for already-verified user" do
    sign_in_as @user

    assert_no_enqueued_emails do
      post email_verification_url
    end
    assert_redirected_to root_path
    assert_match /already verified/, flash[:notice]
  end

  test "resend requires authentication" do
    post email_verification_url
    assert_redirected_to new_session_url
  end
end
