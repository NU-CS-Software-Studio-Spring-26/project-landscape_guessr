# Phase 2 — Server-side generation (services + job)

Copy everything below this line into a **new Cursor chat**.

---

## Task

Implement **Phase 2 only**: generate hint text server-side via Gemini and store in `image_ai_hints`. Assume **Phases 0–1** exist (`GeminiConfig`, `ImageAiHint`, migration applied).

Do **not** add `PracticeController#hint`, routes, practice UI, or rake backfill yet.

## Project context

- `Image#photo` — Active Storage JPEG after `ProcessImageJob`
- Wikimedia images use `image.url` (see `ApplicationHelper#image_src`)
- **`image.title` is often the landmark name (Wikidata)** — must **never** be sent to Gemini or used as a soft prompt
- Coordinates exist on `Image` but are only for post-filtering on the server, not for client hints
- Existing job pattern: `app/jobs/process_image_job.rb`, `ApplicationJob`, async adapter in production
- MapTiler geocoding exists in JS (`practice_controller.js`); you may use MapTiler or Nominatim from Ruby for blocklists only

## Requirements

### 1. `ImageBytesForHint` service

- Input: `Image`
- Output: JPEG bytes (binary string) + mime type
- If `photo.attached?` → download blob
- Else if `url` present → HTTP GET (follow redirects, reasonable timeout)
- Optionally downscale longest side to ~1024px via `image_processing/vips` (project already uses vips)
- Raise a clear error if no image source

### 2. `HintSafetyFilter` service

- Input: hint text, `Image` (for lat/lng and title)
- Reverse-geocode lat/lng on server (MapTiler with `ENV` key or Nominatim; do not expose coords in return value)
- Reject if hint contains (case-insensitive): country name, common city from geocode if available, or significant tokens from `image.title`
- Return filtered string or `nil` / failure if unsafe (caller may retry or mark failed)

### 3. `GeminiHintGenerator` service

- Use `GeminiConfig.model` (default `gemini-2.5-flash-lite`)
- `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key=...`
- Request: one user message with text prompt + `inline_data` base64 JPEG
- **Prompt version** constant `PROMPT_VERSION = 1` in code
- Tier-specific prompts (1 subtle → 3 stronger); all must forbid country, city, landmark names, and readable place names on signs
- Parse response text from JSON
- Handle HTTP 429 / 5xx with exceptions suitable for job retry
- Use `Net::HTTP` (no new gem unless strongly justified)

### 4. `GenerateAiHintJob`

- `perform(image_id, tier)`
- Find `Image`; skip if no coords and no image bytes source (log and mark failed)
- Find or initialize `ImageAiHint` for `(image_id, tier)`
- Skip if already `ready` with current `PROMPT_VERSION`
- Set `pending`, then generate → filter → save `ready` with `body`, `model`, `prompt_version`
- On failure: `status: failed`, `error_message`
- Idempotent and safe to retry

### 5. Tests

- `test/services/gemini_hint_generator_test.rb` — WebMock stub Gemini response; assert request does not include title
- `test/services/hint_safety_filter_test.rb` — blocklist behavior
- `test/jobs/generate_ai_hint_job_test.rb` — stub generator; assert DB state

## Out of scope

- HTTP endpoint for practice
- Stimulus / ERB UI
- Rake backfill task

## Acceptance criteria

- `GenerateAiHintJob.perform_now(image.id, 1)` creates a `ready` row when Gemini is stubbed
- Title never appears in stubbed request body
- Job tests pass without real API key (stub HTTP)

## Files likely touched

- `app/services/image_bytes_for_hint.rb`
- `app/services/hint_safety_filter.rb`
- `app/services/gemini_hint_generator.rb`
- `app/jobs/generate_ai_hint_job.rb`
- `test/services/...`, `test/jobs/generate_ai_hint_job_test.rb`

Implement Phase 2 only. Do not commit real API keys.
