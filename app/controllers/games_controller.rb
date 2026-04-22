class GamesController < ApplicationController
  before_action :set_game, only: %i[ show edit update destroy results ]

  # GET /games or /games.json
  def index
    @games = Game.includes(:guesses).order(created_at: :desc)
    @total_rounds = 5
  end

  # GET /games/1 or /games/1.json
  def show
    @total_rounds = 5
    @round = @game.guesses.count + 1
    if @round > @total_rounds
      redirect_to results_game_path(@game) and return
    end
    guessed_ids = @game.guesses.pluck(:image_id)
    @image = Image.where.not(id: guessed_ids).order("RANDOM()").first
  end

  # GET /games/new
  def new
    @game = Game.new
  end

  # GET /games/1/edit
  def edit
  end

  # POST /games or /games.json
  def create
    @game = Game.new(status: "in_progress")

    respond_to do |format|
      if @game.save
        format.html { redirect_to @game }
        format.json { render :show, status: :created, location: @game }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @game.errors, status: :unprocessable_entity }
      end
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
    total_rounds = 5
    guesses = @game.guesses.includes(:image).order(:created_at)

    @rounds = guesses.map do |guess|
      dist_km = haversine_km(
        guess.latitude.to_f,  guess.longitude.to_f,
        guess.image.latitude.to_f, guess.image.longitude.to_f
      )
      { guess: guess, distance_km: dist_km.round }
    end

    @total_distance_km = @rounds.sum { |r| r[:distance_km] }
    @total_rounds = total_rounds

    if @game.status != "completed"
      @game.update!(status: "completed", score: @total_distance_km, completed_at: Time.current)
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_game
      @game = Game.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def game_params
      params.permit(game: [ :status, :score, :completed_at ]).fetch(:game, {})
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
