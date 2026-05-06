class GamesController < ApplicationController
  TOTAL_ROUNDS = 5

  before_action :require_admin, only: %i[ new edit update ]
  before_action :set_game, only: %i[ show edit update destroy results ]

  # GET /games or /games.json
  GAMES_INDEX_SORTS = %w[created_at score].freeze
  GAMES_INDEX_STATUSES = %w[all in_progress completed].freeze

  def index
    @sort      = GAMES_INDEX_SORTS.include?(params[:sort]) ? params[:sort] : "created_at"
    @direction = params[:direction] == "asc" ? "asc" : "desc"
    @status    = GAMES_INDEX_STATUSES.include?(params[:status]) ? params[:status] : "all"

    games = Current.user.games.includes(:guesses, :image_set)
    games = games.where(status: "in_progress") if @status == "in_progress"
    games = games.where.not(completed_at: nil) if @status == "completed"

    @games = games.order(@sort => @direction)
    @total_rounds = TOTAL_ROUNDS
  end

  # GET /games/leaderboard
  def leaderboard
    @image_set =
      if params[:image_set_id].present?
        set = ImageSet.find_by(id: params[:image_set_id])
        unless set&.playable_by?(Current.user)
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

    # Skip image_set_items where no answer location is available — without
    # this we'd silently include them and every guess for that round would
    # be scored against (0, 0). The COALESCE checks the per-item override
    # *or* the underlying image's coords (item.latitude falls back to
    # item.image.latitude in our model).
    items = image_set.image_set_items
              .joins(:image)
              .where("COALESCE(image_set_items.latitude,  images.latitude)  IS NOT NULL")
              .where("COALESCE(image_set_items.longitude, images.longitude) IS NOT NULL")
              .preload(:image)
              .order(Arel.sql("RANDOM()"))
              .limit(TOTAL_ROUNDS)

    if items.size < TOTAL_ROUNDS
      redirect_to root_path, alert: "Not enough images with coordinates to start a game (need #{TOTAL_ROUNDS}, this set has #{items.size}). Set lat/lng on more images first." and return
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
      dist_km = Game.haversine_km(guess.latitude.to_f, guess.longitude.to_f, ans_lat, ans_lng)
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

    # If the user owns the set this game was played on, build a
    # image_id -> image_set_item_id map so the view can render a
    # "Remove from set" button next to each round. Empty map (no
    # buttons rendered) when there's no editable set.
    @set_item_id_by_image = if @game.image_set&.owned_by?(Current.user)
      @game.image_set.image_set_items
           .where(image_id: guesses.map(&:image_id))
           .pluck(:image_id, :id).to_h
    else
      {}
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
end
