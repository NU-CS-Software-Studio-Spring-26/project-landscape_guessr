FactoryBot.define do
  factory :user do
    sequence(:email_address) { |n| "user#{n}@example.com" }
    sequence(:username) { |n| "user#{n}" }
    password { "password123" }
    email_verified_at { 1.day.ago }
    admin { false }

    trait :admin do
      admin { true }
      sequence(:email_address) { |n| "admin#{n}@example.com" }
      sequence(:username) { |n| "admin#{n}" }
    end

    trait :unverified do
      email_verified_at { nil }
    end
  end
end
