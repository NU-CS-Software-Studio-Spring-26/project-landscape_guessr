class GamesController < ApplicationController
  TOTAL_ROUNDS = 5

  before_action :require_admin, only: %i[ new edit update ]
  before_action :set_game, only: %i[ show edit update destroy results ]

  # GET /games or /games.json
  def index
    @games = Current.user.games.includes(:guesses).order(created_at: :desc)
    @total_rounds = TOTAL_ROUNDS
  end

  # GET /games/leaderboard
  def leaderboard
    @image_set =
      if params[:image_set_id].present?
        set = ImageSet.find_by(id: params[:image_set_id])
        unless set && (set.is_system_default? || set.visibility == "public" || set.owned_by?(Current.user))
          redirect_to image_sets_path, alert: "That set is private." and return
        end
        set
      else
        ImageSet.default
      end
    @games = Game.leaderboard(image_set: @image_set, sort: params[:sort], direction: params[:direction])
    @total_rounds = TOTAL_ROUNDS
  end

  # GET /games/1 or /games/1.json
  def show
    @total_rounds = TOTAL_ROUNDS
    @round = @game.guesses.count + 1
    if @round > @total_rounds
      redirect_to results_game_path(@game) and return
    end

    @image = @game.game_images.includes(:image).find_by(position: @round)&.image

    if @image.nil?
      redirect_to results_game_path(@game) and return
    end
  end

  # GET /games/new
  def new
    @game = Current.user.games.new
  end

  # GET /games/1/edit
  def edit
  end

  # POST /games or /games.json
  def create
    image_set = resolve_image_set
    unless image_set
      redirect_to root_path, alert: "That image set does not exist or is not accessible." and return
    end

    @game = Current.user.games.new(status: "in_progress", image_set: image_set)
    items = image_set.image_set_items.includes(:image).order("RANDOM()").limit(TOTAL_ROUNDS)

    if items.size < TOTAL_ROUNDS
      redirect_to root_path, alert: "Not enough images to start a game (need #{TOTAL_ROUNDS}, set has #{items.size})." and return
    end

    Game.transaction do
      @game.save!
      items.each_with_index do |item, idx|
        @game.game_images.create!(
          image_id: item.image_id,
          position: idx + 1,
          answer_latitude: item.latitude || item.image.latitude,
          answer_longitude: item.longitude || item.image.longitude
        )
      end
    end

    respond_to do |format|
      format.html { redirect_to @game }
      format.json { render :show, status: :created, location: @game }
    end
  rescue ActiveRecord::RecordInvalid
    respond_to do |format|
      format.html { render :new, status: :unprocessable_entity }
      format.json { render json: @game.errors, status: :unprocessable_entity }
    end
  end

  # PATCH/PUT /games/1 or /games/1.json
  def update
    respond_to do |format|
      if @game.update(game_params)
        format.html { redirect_to @game, notice: "Game was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @game }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @game.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /games/1 or /games/1.json
  def destroy
    @game.destroy!

    respond_to do |format|
      format.html { redirect_to games_path, notice: "Game was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  # GET /games/1/results
  def results
    game_images_by_image_id = @game.game_images.index_by(&:image_id)
    guesses = @game.guesses.includes(:image).order(:created_at)

    @rounds = guesses.each_with_index.map do |guess, idx|
      gi = game_images_by_image_id[guess.image_id]
      ans_lat = gi&.answer_lat || guess.image.latitude.to_f
      ans_lng = gi&.answer_lng || guess.image.longitude.to_f
      dist_km = haversine_km(guess.latitude.to_f, guess.longitude.to_f, ans_lat, ans_lng)
      {
        guess: guess,
        distance_km: dist_km,
        answer_lat: ans_lat,
        answer_lng: ans_lng,
        round_number: idx + 1,
        round_score: Game.geoguessr_round_score(dist_km)
      }
    end

    @total_distance_km = @rounds.sum { |r| r[:distance_km] }
    @score = @rounds.sum { |r| r[:round_score] }
    @total_rounds = TOTAL_ROUNDS

    @map_rounds = @rounds.map do |r|
      {
        round: r[:round_number],
        title: r[:guess].image.title,
        guess_lat: r[:guess].latitude.to_f,
        guess_lng: r[:guess].longitude.to_f,
        answer_lat: r[:answer_lat],
        answer_lng: r[:answer_lng],
        distance_label: helpers.format_distance_compact(r[:distance_km])
      }
    end

    if @game.status != "completed"
      @game.update!(status: "completed", score: @score, completed_at: Time.current)
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_game
      @game = Current.user.games.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def game_params
      params.permit(game: [ :status, :score, :completed_at ]).fetch(:game, {})
    end

    def resolve_image_set
      if params[:image_set_id].present?
        set = ImageSet.find_by(id: params[:image_set_id])
        return nil unless set&.playable_by?(Current.user)
        set
      else
        ImageSet.default
      end
    end

    # Great-circle distance in kilometres using the Haversine formula.
    def haversine_km(lat1, lon1, lat2, lon2)
      rad = Math::PI / 180
      dlat = (lat2 - lat1) * rad
      dlon = (lon2 - lon1) * rad
      a = Math.sin(dlat / 2)**2 +
          Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2)**2
      6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end
end
