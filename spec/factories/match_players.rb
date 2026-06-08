FactoryBot.define do
  factory :match_player do
    association :match
    association :user
    joined_at { Time.current }
    total_score { 0 }

    trait :left do
      left_at { 1.minute.ago }
    end

    trait :forfeited do
      forfeited_at { 1.minute.ago }
    end
  end
end
