class MatchesController < ApplicationController
  before_action :set_match, only: %i[ show join leave start destroy state guess results ]

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

    Match.transaction do
      @match.update!(status: "active", started_at: Time.current)
      round = MatchStartRound.call(match: @match)
      unless round
        # No reachable images in the set — bail out, keep the lobby usable.
        raise ActiveRecord::Rollback
      end
    end

    if @match.match_rounds.empty?
      redirect_to match_path(@match.code),
                  alert: "This image set doesn't have enough usable images to start a match." and return
    end

    redirect_to match_path(@match.code), status: :see_other
  end

  # GET /matches/:code/state.json
  def state
    player = @match.match_players.find_by(user_id: Current.user.id)
    current_round = @match.current_round

    payload = {
      server_now: Time.current.iso8601(3),
      match: {
        code:          @match.code,
        status:        @match.status,
        rounds_total:  @match.rounds_total,
        round_index:   current_round&.index
      },
      you: {
        user_id: Current.user.id,
        joined:  player.present?,
        is_host: @match.host?(Current.user)
      },
      current_round:     build_current_round_payload(current_round, player),
      last_round_result: build_last_round_result(current_round),
      players:           build_players_payload(current_round)
    }

    render json: payload
  end

  # POST /matches/:code/guess
  def guess
    player = @match.match_players.active.find_by(user_id: Current.user.id)
    return render json: { error: "not_in_match" }, status: :forbidden unless player

    round = @match.current_round
    if round.nil? || round.ended?
      return render json: { error: "no_active_round" }, status: :conflict
    end
    if Time.current >= round.deadline_at
      return render json: { error: "round_expired" }, status: :conflict
    end

    lat = params[:lat].to_f
    lng = params[:lng].to_f
    unless lat.between?(-90, 90) && lng.between?(-180, 180)
      return render json: { error: "bad_coords" }, status: :unprocessable_entity
    end

    begin
      MatchGuess.create!(
        match_round:  round,
        match_player: player,
        latitude:     lat,
        longitude:    lng
      )
    rescue ActiveRecord::RecordNotUnique
      # Two clicks in the same millisecond — the first one stuck, we're fine.
    end

    # Early-end: if every active player has now submitted, close the round
    # immediately instead of waiting for the timer. The job is idempotent
    # so the lingering perform_later becomes a no-op when it fires.
    active_count  = @match.match_players.active.count
    guessed_count = round.match_guesses.count
    MatchEndRound.call(round: round) if guessed_count >= active_count && active_count.positive?

    render json: { ok: true }
  end

  # GET /matches/:code/results
  def results
    @rounds = @match.match_rounds
                    .includes(:image, match_guesses: { match_player: :user })
                    .order(:index)
    @players = @match.match_players.includes(:user).to_a

    # Final standings: rank by total_score desc, then by earliest joined_at
    # to make ties stable (whoever sat down first ranks higher).
    @standings = @players.sort_by { |p| [ -p.total_score.to_i, p.joined_at.to_i ] }

    # Per-round breakdown keyed by [round_id, player_id] so the view can
    # render an N×R table without per-cell DB hits.
    @guess_index = @match.match_guesses.each_with_object({}) do |g, h|
      h[[ g.match_round_id, g.match_player_id ]] = g
    end
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

  # Per-round payload while the round is still live. Critical: NEVER include
  # the answer coords here, and don't echo other players' guess coords —
  # those reveal atomically in build_last_round_result once the round ends.
  def build_current_round_payload(round, player)
    return nil if round.nil? || round.ended?
    {
      index:        round.index,
      image_url:    helpers.image_src(round.image, width: 1600),
      image_title:  round.image.title,
      started_at:   round.started_at.iso8601(3),
      deadline_at:  round.deadline_at.iso8601(3),
      my_guess_submitted: player.present? &&
                          round.match_guesses.exists?(match_player_id: player.id)
    }
  end

  # Reveals the most recently *ended* round in full: answer, every player's
  # pin, per-player score. Polling clients diff this against what they've
  # already shown to decide when to flip to "round over" UI.
  def build_last_round_result(round)
    return nil if round.nil? || !round.ended?

    guesses = round.match_guesses.includes(match_player: :user).map do |g|
      {
        user_id:     g.match_player.user_id,
        username:    g.match_player.user.username,
        lat:         g.latitude.to_f,
        lng:         g.longitude.to_f,
        distance_km: g.distance_km&.to_f,
        score:       g.score.to_i
      }
    end

    {
      round_index: round.index,
      answer: { lat: round.answer_latitude.to_f, lng: round.answer_longitude.to_f },
      guesses: guesses
    }
  end

  def build_players_payload(current_round)
    host_id = @match.host_id
    @match.match_players.includes(:user).order(:joined_at).map do |p|
      locked_in = current_round && !current_round.ended? &&
                  current_round.match_guesses.exists?(match_player_id: p.id)
      {
        user_id:     p.user_id,
        username:    p.user.username,
        avatar_url:  p.user.gravatar_url(size: 80),
        is_host:     p.user_id == host_id,
        locked_in:   locked_in,
        total_score: p.total_score,
        left:        p.left_at.present?
      }
    end
  end
end
