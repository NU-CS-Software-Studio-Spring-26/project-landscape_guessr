FactoryBot.define do
  factory :challenge_image do
    association :challenge
    association :image
    position { 1 }
    answer_latitude { 48.8566 }
    answer_longitude { 2.3522 }
  end
end
