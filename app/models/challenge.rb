class Challenge < ApplicationRecord
  belongs_to :challenger, class_name: "User"
  belongs_to :image_set, optional: true
  has_many :challenge_images, -> { order(:position) }, dependent: :destroy
  has_many :games, dependent: :nullify

  before_create :generate_token

  def to_param = token

  def game_for(user)  = games.find { |g| g.user_id == user.id }
  def completed_games = games.select { |g| g.completed_at.present? }
  def in_progress_games = games.select { |g| g.completed_at.nil? }

  private

  def generate_token
    loop do
      self.token = SecureRandom.alphanumeric(8).downcase
      break unless Challenge.exists?(token: token)
    end
  end
end
