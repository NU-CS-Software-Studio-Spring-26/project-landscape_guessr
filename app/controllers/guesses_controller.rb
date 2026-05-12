class GuessesController < ApplicationController
  before_action :require_admin, only: %i[ index show new edit update destroy ]
  before_action :set_guess, only: %i[ show edit update destroy ]

  # GET /guesses or /guesses.json
  def index
    @guesses = Guess.includes(:image, game: :user).order(created_at: :desc).limit(100)
  end

  # GET /guesses/1 or /guesses/1.json
  def show
  end

  # GET /guesses/new
  def new
    @guess = Guess.new
  end

  # GET /guesses/1/edit
  def edit
  end

  # POST /guesses or /guesses.json
  def create
    game = Current.user.games.includes(:game_images).find(params.dig(:guess, :game_id))
    image_id = guess_params[:image_id].to_i
    unless game.game_images.any? { |gi| gi.image_id == image_id }
      respond_to do |format|
        format.html { redirect_to game_path(game), alert: "That image isn't part of this game." and return }
        format.json { render json: { error: "image_id not in this game" }, status: :unprocessable_entity and return }
      end
    end

    @guess = game.guesses.new(guess_params.except(:game_id))

    respond_to do |format|
      if @guess.save
        @guess = @guess.game.guesses.includes(:image, game: [ :game_images, :challenge ]).find(@guess.id)
        format.html { redirect_to game_path(@guess.game_id), notice: "Guess recorded." }
        format.json { render :show, status: :created, location: @guess }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @guess.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /guesses/1 or /guesses/1.json
  def update
    respond_to do |format|
      if @guess.update(guess_params)
        format.html { redirect_to @guess, notice: "Guess was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @guess }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @guess.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /guesses/1 or /guesses/1.json
  def destroy
    @guess.destroy!

    respond_to do |format|
      format.html { redirect_to guesses_path, notice: "Guess was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_guess
      @guess = Guess.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def guess_params
      params.expect(guess: [ :game_id, :image_id, :latitude, :longitude ])
    end
end
