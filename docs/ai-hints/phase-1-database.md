# Phase 1 — Database and model

Copy everything below this line into a **new Cursor chat**.

---

## Task

Implement **Phase 1 only**: persistence for cached AI hints. Assume **Phase 0** is done (`GeminiConfig` in `config/initializers/gemini.rb`).

Do **not** implement Gemini HTTP calls, jobs, API routes, UI, or rake tasks.

## Project context

- Rails 8.1 app “Landscape Guessr”
- `Image` model: `app/models/image.rb` — `has_one_attached :photo`, `title`, `url`, lat/lng
- Practice hints will be cached per image and **tier** (1=subtle, 2=medium, 3=strong)
- Later phases will store generated text from `gemini-2.5-flash-lite`

## Requirements

1. **Migration** `create_image_ai_hints`:
   - `image_id` — `references :image, null: false, foreign_key: true`
   - `tier` — integer, not null (1–3)
   - `status` — string, not null, default `"pending"` — values: `pending`, `ready`, `failed`
   - `body` — text, nullable (hint text when ready)
   - `model` — string, nullable (e.g. `gemini-2.5-flash-lite`)
   - `prompt_version` — integer, not null, default `1` (bump to regenerate all hints later)
   - `error_message` — text, nullable
   - `timestamps`
   - **Unique index** on `[image_id, tier]`

2. **Model** `ImageAiHint`:
   - `belongs_to :image`
   - Validations: `tier` inclusion 1..3; `status` inclusion in allowed list
   - Scopes: `ready`, `pending`, `failed`, `for_tier(tier)`
   - Constants: `STATUSES`, `TIERS` or similar if useful

3. **Image** association:
   - `has_many :ai_hints, class_name: "ImageAiHint", dependent: :destroy`

4. **Tests** in `test/models/image_ai_hint_test.rb`:
   - Validations
   - Uniqueness of tier per image

5. Run migration and ensure `db/schema.rb` is updated.

## Out of scope

- Services, jobs, controllers, routes, Stimulus, Gemini API

## Acceptance criteria

- `ImageAiHint.create!(image: images(:one), tier: 1, status: "ready", body: "Alpine terrain")` works
- Duplicate `(image_id, tier)` raises at DB level
- Model tests pass: `bin/rails test test/models/image_ai_hint_test.rb`

## Files likely touched

- `db/migrate/..._create_image_ai_hints.rb`
- `app/models/image_ai_hint.rb`
- `app/models/image.rb`
- `test/models/image_ai_hint_test.rb`
- `test/fixtures/image_ai_hints.yml` (if fixtures fit project style)

Implement Phase 1 only.
