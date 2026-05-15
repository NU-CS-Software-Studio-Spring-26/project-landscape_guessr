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

    @games = paginate(games.order(@sort => @direction), per_page: 100)
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

    # bbox of all images in the set, used to fit the guess map at round start
    # so the user starts looking at the relevant region (e.g., a US-only set
    # opens centered on the US instead of the world). One COALESCE'd SQL pass
    # — much cheaper than loading the items into Ruby.
    @set_image_bbox = compute_set_image_bbox(@game.image_set)
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
    items = image_set.effective_items
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
      # 303 (not 302) so Turbo follows the redirect after a button_to POST.
      # Without :see_other, Turbo drops the redirect and the request hangs.
      format.html { redirect_to @game, status: :see_other }
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

    if @game.status != "completed"
      @game.update!(status: "completed", score: @score, completed_at: Time.current)
    end

    if @game.challenge
      @challenge_games = @game.challenge.games
                              .where.not(completed_at: nil)
                              .includes(:user)
                              .order(score: :desc)

      other_games = @game.challenge.games
                         .where.not(id: @game.id)
                         .where.not(completed_at: nil)
                         .includes(:user, :guesses, :game_images)

      @challenge_players = other_games.map do |g|
        pos_by_img = g.game_images.each_with_object({}) { |gi, h| h[gi.image_id] = gi.position }
        rounds = g.guesses.order(:created_at).filter_map do |guess|
          pos = pos_by_img[guess.image_id]
          next unless pos
          { round: pos, guess_lat: guess.latitude.to_f, guess_lng: guess.longitude.to_f }
        end
        { username: g.user.username, rounds: rounds }
      end
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

    # Returns { min_lat:, max_lat:, min_lng:, max_lng: } over the set's items,
    # or nil if the set has no item with coords. Image lat/lng falls back to
    # the underlying image's GPS via COALESCE. One scan over the set's items.
    def compute_set_image_bbox(image_set)
      return nil unless image_set
      row = image_set.image_set_items
                     .joins(:image)
                     .pick(
                       Arel.sql("MIN(COALESCE(image_set_items.latitude,  images.latitude))  AS min_lat"),
                       Arel.sql("MAX(COALESCE(image_set_items.latitude,  images.latitude))  AS max_lat"),
                       Arel.sql("MIN(COALESCE(image_set_items.longitude, images.longitude)) AS min_lng"),
                       Arel.sql("MAX(COALESCE(image_set_items.longitude, images.longitude)) AS max_lng")
                     )
      return nil unless row && row.compact.any?
      min_lat, max_lat, min_lng, max_lng = row
      return nil unless min_lat && max_lat && min_lng && max_lng
      { min_lat: min_lat.to_f, max_lat: max_lat.to_f, min_lng: min_lng.to_f, max_lng: max_lng.to_f }
    end
end
