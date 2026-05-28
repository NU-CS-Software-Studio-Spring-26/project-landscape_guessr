class MatchGuess < ApplicationRecord
  belongs_to :match_round
  belongs_to :match_player

  validates :match_player_id, uniqueness: { scope: :match_round_id }

  before_validation :ensure_submitted_at

  private

  def ensure_submitted_at
    self.submitted_at ||= Time.current
  end
end
