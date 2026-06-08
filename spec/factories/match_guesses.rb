FactoryBot.define do
  factory :match_guess do
    association :match_round
    association :match_player
    latitude { 48.8566 }
    longitude { 2.3522 }
    submitted_at { Time.current }
  end
end
