FactoryBot.define do
  factory :match_round do
    association :match
    association :image
    index { 1 }
    answer_latitude { 48.8566 }
    answer_longitude { 2.3522 }
    started_at { 1.minute.ago }
    deadline_at { 29.seconds.from_now }

    trait :ended do
      ended_at { 1.second.ago }
      deadline_at { 30.seconds.ago }
    end

    trait :expired do
      deadline_at { 1.second.ago }
    end
  end
end
