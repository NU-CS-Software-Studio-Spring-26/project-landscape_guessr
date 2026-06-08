FactoryBot.define do
  factory :game do
    association :user
    association :image_set
    status { "in_progress" }
    challenge { nil }
    completed_at { nil }
    score { nil }

    trait :completed do
      status { "completed" }
      completed_at { 1.hour.ago }
      score { 14_000 }
    end
  end
end
