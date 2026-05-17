# Phase 3 — Practice hint API

Copy everything below this line into a **new Cursor chat**.

---

## Task

Implement **Phase 3 only**: JSON endpoint for practice to fetch cached AI hints. Assume **Phases 0–2** are complete (`GeminiConfig`, `ImageAiHint`, `GenerateAiHintJob`, services).

Do **not** build practice UI (Phase 5) or rake backfill (Phase 4) except minimal manual testing instructions.

## Project context

- Routes: `config/routes.rb` — practice routes under `practice`, `practice/check`
- `PracticeController#check` — returns `answer_lat`, `answer_lng` with `Image.visible_to(Current.user)` gate (see `app/controllers/practice_controller.rb`)
- `allow_unauthenticated_access only: %i[ show check ]` — decide if `hint` should be public like `check` or require sign-in (prefer **same as check**: allow unauthenticated for public/default-set images)
- Feature flag: `GeminiConfig.enabled?`

## Requirements

1. **Route**
   - `get "practice/hint", to: "practice#hint", as: :practice_hint`

2. **`PracticeController#hint`**
   - Params: `image_id` (required), `tier` (1–3, default 1)
   - If `!GeminiConfig.enabled?` → `503` or `404` JSON `{ error: "ai_hints_disabled" }`
   - Load image: `Image.visible_to(Current.user).where.not(latitude: nil, longitude: nil).find_by(id: ...)`
   - Not found → `404` `{ error: "image_not_found" }`
   - Find `ImageAiHint` for `(image, tier)`
   - If `ready` → `200` `{ status: "ready", hint: body, tier: tier }`
   - If `pending` → `200` `{ status: "pending", tier: tier }`
   - If `failed` → optionally retry: enqueue job again and return `pending`, or return `{ status: "failed", error: ... }` (document choice)
   - If missing → create `ImageAiHint` with `status: pending`, enqueue `GenerateAiHintJob.perform_later(image.id, tier)`, return `{ status: "pending" }`
   - **Never** return `answer_lat`, `answer_lng`, or `image.title` in this response

3. **Tests** `test/controllers/practice_controller_test.rb` (or dedicated file):
   - Disabled when `AI_HINTS_ENABLED` off (stub env in test)
   - Returns ready hint when fixture exists
   - Returns pending when no row / pending row
   - Private image not visible to anonymous user → 404
   - Response JSON does not include coordinates

4. **Fixture** `test/fixtures/image_ai_hints.yml` if needed

## Out of scope

- ERB/Stimulus changes
- Rake backfill
- Legal/README (Phase 6)

## Acceptance criteria

- `get practice_hint_path(image_id: @public_image.id, tier: 1), as: :json` works in tests
- Enqueue job on first request (assert enqueued job in test)
- No coordinate leak in response body

## Files likely touched

- `config/routes.rb`
- `app/controllers/practice_controller.rb`
- `test/controllers/practice_controller_test.rb`
- `test/fixtures/image_ai_hints.yml`

Implement Phase 3 only.
