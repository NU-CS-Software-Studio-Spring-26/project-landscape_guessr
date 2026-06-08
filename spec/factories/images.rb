FactoryBot.define do
  factory :image do
    sequence(:url) { |n| "https://example.com/image#{n}.jpg" }
    sequence(:title) { |n| "Test Image #{n}" }
    latitude { 48.8566 }
    longitude { 2.3522 }
  end
end
