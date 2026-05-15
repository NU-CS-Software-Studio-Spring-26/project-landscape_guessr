class EmailVerificationsController < ApplicationController
  allow_unauthenticated_access only: :show
  skip_before_action :require_email_verified

  def show
    user = User.find_by_email_verification_token(params[:token])

    if user
      user.update!(email_verified_at: Time.current)
      redirect_to root_path, notice: "Email verified successfully!"
    else
      redirect_to root_path, alert: "Verification link is invalid or has expired."
    end
  end

  def create
    if Current.user.email_verified?
      redirect_to root_path, notice: "Your email is already verified."
    else
      EmailVerificationMailer.verify(Current.user).deliver_later
      redirect_to root_path, notice: "Verification email sent. Check your inbox."
    end
  end
end
