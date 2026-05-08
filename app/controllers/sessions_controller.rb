class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  skip_before_action :require_username_set, only: :destroy
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    user = User.find_by_login(params[:login])
    if user&.authenticate(params[:password])
      start_new_session_for user
      redirect_to after_authentication_url, notice: "Signed in."
    else
      redirect_to new_session_path, alert: "Try another email/username or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other, notice: "Signed out."
  end
end
