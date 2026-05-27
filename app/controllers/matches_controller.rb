class MatchesController < ApplicationController
  before_action :set_match, only: %i[ show join leave start destroy ]

  # GET /matches/new
  def new
    @image_sets = available_image_sets
  end

  # POST /matches
  def create
    image_set = resolve_image_set
    unless image_set
      redirect_to new_match_path, alert: "Pick a valid image set." and return
    end

    rounds_total      = clamp_int(params[:rounds_total],      default: 5,  min: 1,  max: 20)
    seconds_per_round = clamp_int(params[:seconds_per_round], default: 60, min: 15, max: 300)

    @match = Match.new(
      host: Current.user,
      image_set: image_set,
      rounds_total: rounds_total,
      seconds_per_round: seconds_per_round
    )

    Match.transaction do
      @match.save!
      @match.match_players.create!(user: Current.user)
    end

    redirect_to match_path(@match.code), status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.message
    @image_sets = available_image_sets
    render :new, status: :unprocessable_entity
  end

  # GET /matches/:code
  def show
    @joined     = @match.joined_by?(Current.user)
    @is_host    = @match.host?(Current.user)
    @players    = @match.match_players.includes(:user).order(:joined_at).to_a
    @at_capacity = @match.at_capacity?
    @can_start  = @match.startable_by?(Current.user)
    @share_url  = match_url(@match.code)
  end

  # POST /matches/:code/join
  def join
    if @match.joined_by?(Current.user)
      redirect_to match_path(@match.code) and return
    end
    unless @match.status == "lobby"
      redirect_to match_path(@match.code), alert: "This match has already started." and return
    end
    if @match.at_capacity?
      redirect_to match_path(@match.code),
                  alert: "Lobby is full (#{Match::LOBBY_CAPACITY} max)." and return
    end

    begin
      @match.match_players.create!(user: Current.user)
    rescue ActiveRecord::RecordNotUnique
      # raced another join — already a member, fine
    end

    redirect_to match_path(@match.code), status: :see_other
  end

  # POST /matches/:code/leave
  def leave
    player = @match.match_players.find_by(user_id: Current.user.id)
    if player.nil?
      redirect_to root_path and return
    end

    # In the lobby, leaving deletes the row so the seat opens up again.
    # Once the match is active we keep the row and just stamp left_at,
    # because their scoring history needs to survive on the results page.
    if @match.status == "lobby"
      player.destroy!
    else
      player.update!(left_at: Time.current)
    end

    redirect_to root_path, notice: "Left the lobby.", status: :see_other
  end

  # POST /matches/:code/start
  def start
    unless @match.startable_by?(Current.user)
      redirect_to match_path(@match.code),
                  alert: "Only the host can start, and only with 1-#{Match::LOBBY_CAPACITY} players in the lobby." and return
    end

    # Round creation + EndRoundJob land in the next commit (round lifecycle).
    # For now just flip the status so the lobby reflects that the host
    # locked it in.
    @match.update!(status: "active", started_at: Time.current)
    redirect_to match_path(@match.code), status: :see_other
  end

  # DELETE /matches/:code
  def destroy
    unless @match.host?(Current.user)
      redirect_to match_path(@match.code), alert: "Only the host can delete the match." and return
    end
    @match.destroy!
    redirect_to root_path, notice: "Match deleted.", status: :see_other
  end

  private

  def set_match
    @match = Match.find_by!(code: params[:code])
  end

  def available_image_sets
    ImageSet.visible_to(Current.user).order(:name)
  end

  def resolve_image_set
    return ImageSet.default if params[:image_set_id].blank?
    set = ImageSet.find_by(id: params[:image_set_id])
    return nil unless set&.playable_by?(Current.user)
    set
  end

  def clamp_int(raw, default:, min:, max:)
    n = raw.to_i
    n = default if n <= 0
    n.clamp(min, max)
  end
end
