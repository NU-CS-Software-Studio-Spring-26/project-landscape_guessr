FactoryBot.define do
  factory :image_set do
    association :user
    sequence(:name) { |n| "Image Set #{n}" }
    visibility { "private" }
    map_style { "outdoor-v2" }
    is_system_default { false }

    trait :public do
      visibility { "public" }
      # Public visibility requires ai_generated or admin-owned; use ai_query to satisfy the validation.
      sequence(:ai_query) { |n| "SELECT * WHERE { ?item wdt:P31 wd:Q#{n} }" }
    end

    trait :system_default do
      is_system_default { true }
      user { nil }
      sequence(:name) { |n| "System Default #{n}" }
    end
  end
end
