class Match < ApplicationRecord
  # Cap enforced by the host start gate and the lobby join path. 100 is the
  # product call: small enough to keep round payloads under a few KB even
  # with everyone guessing simultaneously, large enough that classroom /
  # event use cases fit without partitioning.
  LOBBY_CAPACITY = 100

  STATUSES = %w[lobby active finished].freeze

  # Crockford-ish: ambiguous chars (0/O/1/I) removed so people can read the
  # code off a screen-share. 6 chars over a 32-symbol alphabet ≈ 1 billion
  # possibilities, plenty for the active-match table.
  CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".chars.freeze
  CODE_LENGTH = 6

  belongs_to :host, class_name: "User"
  belongs_to :image_set
  has_many :match_players, dependent: :destroy
  has_many :players, through: :match_players, source: :user
  has_many :match_rounds, -> { order(:index) }, dependent: :destroy
  has_many :match_guesses, through: :match_rounds

  validates :code, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :rounds_total,      numericality: { only_integer: true, greater_than: 0 }
  validates :seconds_per_round, numericality: { only_integer: true, greater_than: 0 }

  before_validation :ensure_code

  scope :lobby,    -> { where(status: "lobby") }
  scope :active,   -> { where(status: "active") }
  scope :finished, -> { where(status: "finished") }

  def to_param
    code
  end

  def host?(user)
    user && host_id == user.id
  end

  def joined_by?(user)
    user && match_players.exists?(user_id: user.id)
  end

  # In the lobby AND (already joined OR under capacity).
  def joinable_by?(user)
    return false unless user
    return true  if joined_by?(user)
    status == "lobby" && !at_capacity?
  end

  def startable_by?(user)
    host?(user) &&
      status == "lobby" &&
      match_players.count.between?(1, LOBBY_CAPACITY)
  end

  def at_capacity?
    match_players.count >= LOBBY_CAPACITY
  end

  def current_round
    match_rounds.last
  end

  def self.generate_unique_code
    20.times do
      candidate = Array.new(CODE_LENGTH) { CODE_ALPHABET.sample }.join
      return candidate unless exists?(code: candidate)
    end
    raise "Could not generate unique match code after 20 attempts"
  end

  private

  def ensure_code
    self.code = self.class.generate_unique_code if code.blank?
  end
end
