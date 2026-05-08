class ProfilesController < ApplicationController
  skip_before_action :require_username_set, only: %i[ setup_username update_username ]

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

  private
    def username_params
      params.expect(user: [ :username ])
    end
end
