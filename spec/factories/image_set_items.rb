FactoryBot.define do
  factory :image_set_item do
    association :image_set
    association :image

    # Per-item coord override — nil means fall back to the image's own coords.
    latitude { nil }
    longitude { nil }

    trait :with_usable_coords do
      latitude { 48.8566 }
      longitude { 2.3522 }
    end
  end
end
