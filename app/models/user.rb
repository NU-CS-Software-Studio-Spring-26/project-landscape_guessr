class User < ApplicationRecord
  USERNAME_FORMAT = /\A[a-zA-Z0-9_-]{3,20}\z/

  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :games, dependent: :destroy
  has_many :image_sets, dependent: :destroy
  has_many :connected_services, dependent: :destroy
  has_many :challenges, foreign_key: :challenger_id, dependent: :destroy
  has_many :ai_generations, dependent: :destroy
  has_many :saved_practice_items, class_name: "SavedPracticeImage", dependent: :destroy
  has_many :saved_practice_images, through: :saved_practice_items, source: :image

  generates_token_for :email_verification, expires_in: 24.hours do
    email_verified_at
  end

  def email_verified?
    email_verified_at.present? || connected_services.any?
  end

  def email_verification_token
    generate_token_for(:email_verification)
  end

  def self.find_by_email_verification_token(token)
    find_by_token_for(:email_verification, token)
  end

  normalizes :email_address, with: ->(e) { e.strip.downcase }
  normalizes :username, with: ->(u) { u.present? ? u.to_s.strip : nil }

  validates :email_address, presence: true,
                            uniqueness: { message: "is invalid" },
                            format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :username, presence: true, unless: :pending_username_setup?
  validates :username, format: { with: USERNAME_FORMAT,
                                 message: "must be 3-20 characters: letters, digits, _ or -" },
                       uniqueness: { case_sensitive: false },
                       allow_blank: true
  validates :password, length: { minimum: 8 }, allow_nil: true

  def pending_username_setup?
    username.blank? && connected_services.any?
  end

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
