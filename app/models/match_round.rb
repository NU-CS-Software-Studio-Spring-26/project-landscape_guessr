class MatchRound < ApplicationRecord
  belongs_to :match
  belongs_to :image
  has_many :match_guesses, dependent: :destroy

  validates :index, presence: true, uniqueness: { scope: :match_id }

  def ended?
    ended_at.present?
  end

  def expired?
    deadline_at && Time.current >= deadline_at
  end
end
