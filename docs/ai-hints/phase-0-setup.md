# Phase 0 — Gemini account and configuration

Copy everything below this line into a **new Cursor chat**.

---

## Task

Implement **Phase 0 only** of AI visual hints for the Landscape Guessr Rails 8 app: Gemini API setup and configuration. Do **not** add database tables, jobs, routes, or UI yet.

## Project context

- Rails 8.1, PostgreSQL, Stimulus, practice mode at `/practice`
- Existing hints: circle radius + continent/country (client-side geocoding in `app/javascript/controllers/practice_controller.js`)
- Images: `Image` has `title`, `url`, `latitude`, `longitude`, optional `photo` (Active Storage)
- Dev env uses `dotenv-rails` (see README for `GOOGLE_CLIENT_ID` pattern)
- Deploy target may include Heroku

## Requirements

1. Document how to obtain a **Gemini API key** from [Google AI Studio](https://aistudio.google.com/apikey) (this is **not** the same as Google OAuth client credentials used for sign-in).

2. Add environment variables (document in README, do not commit secrets):
   - `GEMINI_API_KEY` — required when AI hints are enabled
   - `GEMINI_MODEL` — default `gemini-2.5-flash-lite`
   - `AI_HINTS_ENABLED` — set to `1` to turn the feature on

3. Add `config/initializers/gemini.rb` (or equivalent) that:
   - Reads `ENV["GEMINI_API_KEY"]`, `ENV["GEMINI_MODEL"]`, `ENV["AI_HINTS_ENABLED"]`
   - Exposes a small module or constants, e.g. `GeminiConfig.api_key`, `GeminiConfig.model`, `GeminiConfig.enabled?`
   - `enabled?` is true only when `AI_HINTS_ENABLED` is truthy **and** API key is present
   - Does not raise at boot if the key is missing (feature is optional)

4. Add a `.env.example` entry (or extend existing example) for the three variables with short comments.

5. Update README.md with a short “AI practice hints (optional)” section: how to get the key, env vars, and that billing/rate limits are on the free Gemini tier unless upgraded.

## Out of scope (later phases)

- No migrations, models, jobs, controllers, routes, JavaScript, or rake tasks
- No HTTP calls to Gemini yet

## Acceptance criteria

- App boots with no `GEMINI_API_KEY` set
- `GeminiConfig.enabled?` returns false without key or without `AI_HINTS_ENABLED=1`
- README documents setup clearly
- No secrets committed to git

## Files likely touched

- `config/initializers/gemini.rb` (new)
- `README.md`
- `.env.example` (if present; create minimal entries if not)

Implement Phase 0 completely and run any relevant checks (e.g. `bin/rails runner 'puts GeminiConfig.enabled?'`).
