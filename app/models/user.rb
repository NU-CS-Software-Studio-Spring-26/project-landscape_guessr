class User < ApplicationRecord
  USERNAME_FORMAT = /\A[a-zA-Z0-9_-]{3,20}\z/

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :games, dependent: :destroy
  has_many :image_sets, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :username, with: ->(u) { u.to_s.strip }

  validates :email_address, presence: true,
                            uniqueness: { message: "is invalid" },
                            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :username, presence: true,
                       format: { with: USERNAME_FORMAT,
                                 message: "must be 3-20 characters: letters, digits, _ or -" },
                       uniqueness: { case_sensitive: false }
  validates :password, length: { minimum: 8 }, allow_nil: true

  def self.find_by_login(login)
    s = login.to_s.strip
    return nil if s.empty?
    if s.include?("@")
      find_by(email_address: s.downcase)
    else
      where("LOWER(username) = ?", s.downcase).first
    end
  end
end
