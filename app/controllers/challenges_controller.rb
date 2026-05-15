class ChallengesController < ApplicationController
  TOTAL_ROUNDS = 5

  before_action :set_challenge, only: [ :show, :play, :destroy ]

  def index
    created = Current.user.challenges.includes(:image_set, :games)
    joined  = Challenge.joins(:games)
                       .where(games: { user_id: Current.user.id })
                       .where.not(challenger_id: Current.user.id)
                       .includes(:challenger, :image_set, :games)

    @challenges = (created + joined).uniq.sort_by(&:created_at).reverse
  end

  def new
    @image_sets = available_image_sets
  end

  def create
    image_set = resolve_image_set
    items = pick_items_for(image_set)

    if items.size < TOTAL_ROUNDS
      flash.now[:alert] = "Not enough images with coordinates in this set (need #{TOTAL_ROUNDS}, found #{items.size})."
      @image_sets = available_image_sets
      render :new, status: :unprocessable_entity and return
    end

    @challenge = Challenge.new(
      challenger: Current.user,
      image_set:  image_set.is_system_default? ? nil : image_set
    )

    Challenge.transaction do
      @challenge.save!
      items.each_with_index do |item, idx|
        @challenge.challenge_images.create!(
          image_id:         item.image_id,
          position:         idx + 1,
          answer_latitude:  item.answer_lat,
          answer_longitude: item.answer_lng
        )
      end
    end

    redirect_to @challenge, notice: "Challenge created! Share the link below.", status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = e.message
    @image_sets = available_image_sets
    render :new, status: :unprocessable_entity
  end

  def show
    @my_game     = @challenge.game_for(Current.user)
    @completed   = @challenge.completed_games.sort_by { |g| -g.score.to_i }
    @in_progress = @challenge.in_progress_games
    @share_url   = challenge_url(@challenge)
  end

  def play
    existing = @challenge.game_for(Current.user)
    if existing
      redirect_to existing, status: :see_other and return
    end

    challenge_images = @challenge.challenge_images.includes(:image)
    if challenge_images.size < TOTAL_ROUNDS
      redirect_to @challenge, alert: "This challenge doesn't have images set up correctly." and return
    end

    game = nil
    Game.transaction do
      game = Current.user.games.create!(
        status:    "in_progress",
        image_set: @challenge.image_set || ImageSet.default,
        challenge: @challenge
      )
      challenge_images.each do |ci|
        game.game_images.create!(
          image_id:         ci.image_id,
          position:         ci.position,
          answer_latitude:  ci.answer_latitude,
          answer_longitude: ci.answer_longitude
        )
      end
    end

    redirect_to game, status: :see_other
  end

  def destroy
    unless @challenge.challenger_id == Current.user.id
      redirect_to challenges_path, alert: "Only the challenge creator can delete it." and return
    end
    @challenge.destroy!
    redirect_to challenges_path, notice: "Challenge deleted.", status: :see_other
  end

  private

  def set_challenge
    @challenge = Challenge.includes(:challenger, :image_set, :games, :challenge_images).find_by!(token: params[:token])
  end

  def available_image_sets
    ImageSet.visible_to(Current.user).order(:name)
  end

  def resolve_image_set
    if params[:image_set_id].present?
      set = ImageSet.find_by(id: params[:image_set_id])
      return ImageSet.default unless set&.playable_by?(Current.user)
      set
    else
      ImageSet.default
    end
  end

  def pick_items_for(image_set)
    image_set.effective_items
             .with_usable_coords
             .order(Arel.sql("RANDOM()"))
             .limit(TOTAL_ROUNDS)
  end
end
