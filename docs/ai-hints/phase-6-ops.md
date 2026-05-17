# Phase 6 — Ops, legal, fallbacks, documentation

Copy everything below this line into a **new Cursor chat**.

---

## Task

Implement **Phase 6 only**: production polish for AI visual hints. Assume **Phases 0–5** are implemented.

Do **not** re-architect generation or UI unless fixing gaps found during this pass.

## Project context

- Feature flag: `GeminiConfig.enabled?`
- Practice falls back to circle/location hints when AI fails
- Deploy: Heroku mentioned in README
- Legal page: `app/views/home/legal.html.erb`
- Privacy: user-uploaded photos may be sent to Google Gemini when hints are requested/generated

## Requirements

### 1. Legal / privacy

- Add a short subsection to `legal.html.erb` (or existing privacy section):
  - Optional AI hints in practice may send the landscape photo to Google’s Gemini API for analysis
  - Only when the feature is enabled and the user requests a visual hint (or when admins backfill)
  - Link to Google’s privacy/terms as appropriate
  - No marketing fluff; plain language

### 2. Fallbacks and UX hardening

- Practice UI: if hint endpoint returns `ai_hints_disabled`, `failed`, or network error — show clear message; do not break other hint types
- `PracticeController#hint`: consistent JSON error shapes; consider retry once on `failed` rows older than N minutes
- Log failures in `GenerateAiHintJob` with `[GenerateAiHintJob]` prefix (match `ProcessImageJob` style)

### 3. README

- Consolidate AI hints documentation:
  - Env vars (`GEMINI_API_KEY`, `GEMINI_MODEL`, `AI_HINTS_ENABLED`)
  - Enable locally, run backfill `bin/rails images:generate_ai_hints[1,,4]`
  - Heroku: `heroku config:set GEMINI_API_KEY=... AI_HINTS_ENABLED=1`
  - Free tier limits: recommend backfill + cache; link to AI Studio rate limits
  - Model: `gemini-2.5-flash-lite`

### 4. Security checklist (verify in code, fix if missing)

- Hint API never returns lat/lng/title
- `Image.visible_to` on hint endpoint
- API key only server-side (never in JS)
- `image.title` not in Gemini prompt (add comment in generator if not present)

### 5. Optional small improvements (only if quick)

- `images:generate_ai_hints:stats` rake mentioned in Phase 4 — document or add if missing
- Rate limit note in README for concurrent practice users (cache makes this rare)

## Out of scope

- New hint tiers or game mode integration
- Billing / paid Gemini tier setup
- Committing `.env` or API keys

## Acceptance criteria

- Legal page mentions AI hint processing
- README gives a complete enable → backfill → use path
- Failed hint path is user-friendly in practice
- No secrets in repo

## Files likely touched

- `app/views/home/legal.html.erb`
- `README.md`
- `app/controllers/practice_controller.rb` (error handling only)
- `app/javascript/controllers/practice_controller.js` (error messages only)
- `app/jobs/generate_ai_hint_job.rb` (logging only)

Implement Phase 6 only. Run relevant tests.
