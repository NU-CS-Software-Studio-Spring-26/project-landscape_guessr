class ProfilesController < ApplicationController
  def show
    @user = Current.user
    completed = @user.games.where.not(completed_at: nil)
    @games_played = completed.count
    @best_score   = completed.maximum(:score)
    @avg_score    = completed.average(:score)&.round
  end
end
