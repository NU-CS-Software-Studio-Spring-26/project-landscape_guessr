class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]

  def new
    @user = User.new
  end

  def create
    @user = User.new(registration_params)
    if @user.save
      EmailVerificationMailer.verify(@user).deliver_later
      start_new_session_for @user
      redirect_to after_authentication_url
    else
      flash.now[:alert] = @user.errors.full_messages.first
      render :new, status: :unprocessable_entity
    end
  end

  private
    def registration_params
      params.expect(user: [ :email_address, :username, :password, :password_confirmation ])
    end
end
