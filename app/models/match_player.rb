class MatchPlayer < ApplicationRecord
  belongs_to :match
  belongs_to :user
  has_many :match_guesses, dependent: :destroy

  validates :user_id, uniqueness: { scope: :match_id }

  before_validation :ensure_joined_at

  scope :active, -> { where(left_at: nil, forfeited_at: nil) }

  private

  def ensure_joined_at
    self.joined_at ||= Time.current
  end
end
