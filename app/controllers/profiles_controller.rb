class ProfilesController < ApplicationController
  skip_before_action :require_username_set, only: %i[ setup_username update_username destroy ]
  skip_before_action :require_email_verified

  def show
    @user = Current.user
    completed = @user.games.where.not(completed_at: nil)
    @games_played = completed.count
    @best_score   = completed.maximum(:score)
    @avg_score    = completed.average(:score)&.round
  end

  def setup_username
    redirect_to(profile_path) and return if Current.user.username.present?
    @user = Current.user
  end

  def update_username
    redirect_to(profile_path) and return if Current.user.username.present?
    @user = Current.user
    if @user.update(username_params)
      redirect_to after_authentication_url, notice: "Username saved."
    else
      flash.now[:alert] = @user.errors.full_messages.first
      render :setup_username, status: :unprocessable_entity
    end
  end

  # Permanently delete the current user's account and everything they own.
  # Sessions, games (and their guesses), image sets, and connected services
  # cascade via dependent: :destroy. ImageSet#sweep_orphan_images cleans up
  # the underlying Images (and S3 blobs) for items that were only in this
  # user's sets; images shared with other users' sets or the system-default
  # set are preserved. Other users' games on this user's (now-deleted)
  # public set survive with image_set_id = nil via ImageSet's
  # dependent: :nullify on :games.
  def destroy
    user = Current.user

    typed_email = params[:confirm_email].to_s.strip.downcase
    if typed_email != user.email_address.to_s.downcase
      redirect_to profile_path, alert: "Type your email address to confirm deletion."
      return
    end

    # OAuth-linked users have an auto-generated password they never see
    # (see Sessions::OmniAuthsController#build_oauth_user), so requiring it
    # would lock them out of deleting their own account. Email confirmation
    # plus their authenticated session is the auth factor in that case.
    if user.connected_services.empty? && !user.authenticate(params[:current_password].to_s)
      redirect_to profile_path, alert: "Incorrect password."
      return
    end

    if user.admin? && !User.where(admin: true).where.not(id: user.id).exists?
      redirect_to profile_path, alert: "You're the only admin — promote another admin from the Rails console before deleting your account."
      return
    end

    User.transaction { user.destroy! }

    cookies.delete(:session_id)
    Current.session = nil
    redirect_to root_path, notice: "Your account has been deleted."
  end

  private
    def username_params
      params.expect(user: [ :username ])
    end
end
