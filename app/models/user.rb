class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :games, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true,
                            uniqueness: { message: "is invalid" },
                            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, allow_nil: true
end
