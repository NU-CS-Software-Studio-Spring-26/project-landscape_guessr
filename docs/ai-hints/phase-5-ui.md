# Phase 5 — Practice UI (Visual hints)

Copy everything below this line into a **new Cursor chat**.

---

## Task

Implement **Phase 5 only**: practice mode UI for AI visual hints, wired to `GET /practice/hint`. Assume **Phases 0–3** are done (API + DB + job). Phase 4 backfill is optional for testing (you can stub ready hints in DB).

Do **not** change legal copy or README deploy docs (Phase 6).

## Project context

- Practice view: `app/views/practice/show.html.erb`
- Stimulus: `app/javascript/controllers/practice_controller.js` (~800+ lines)
- Existing hint types: `off`, `radius`, `location` with URL params `hint_type`, `hint_radius`, `hint_location`
- Hint readout target: `hintReadout`
- `data-practice-check-url-value` points to practice check path
- Add `data-practice-hint-url-value` for hint endpoint (or derive from check URL)
- `GeminiConfig.enabled?` — hide Visual hint UI when false (pass `@ai_hints_enabled` from controller)

## Requirements

### ERB (`practice/show.html.erb`)

1. When `@ai_hints_enabled` (from `PracticeController#show`):
   - New hint type button: **Visual** (`data-practice-type-param="visual"`)
   - Sub-panel: tier buttons **Subtle / Medium / Strong** (tiers 1–3), similar styling to location hint options
   - Readout for visual hint text (reuse `hintReadout` or add `hintVisualReadout` — avoid duplicate visible readouts)

2. When disabled: no Visual button (existing hints unchanged)

### Controller (`practice_controller.rb` `#show`)

- Set `@ai_hints_enabled = GeminiConfig.enabled?`

### Stimulus (`practice_controller.js`)

1. State: `hintType === "visual"`, `hintVisualTier` (1–3)
2. URL sync: `hint_type=visual`, `hint_tier=1|2|3` in `#syncPracticeInUrl` / `#initializeHintStateFromUrl`
3. `#applyHintSelection` branch for visual:
   - Hide map circle; clear location message
   - `fetch(hintUrl + ?image_id=&tier=)` with `Accept: application/json`
   - `ready` → show hint in readout
   - `pending` → show “Generating hint…” and **poll every 2s** until ready/failed (max attempts or stop on disconnect)
   - `failed` → show friendly error
4. On `next` round / `#resetHintForNextAttempt`: reset visual state like other hints
5. New static values/targets as needed (`hintUrl`, `hintVisualOption`, etc.)

### Tests

- `practice_controller_test.rb`: when enabled, response body includes Visual hint controls; when disabled, does not
- Optional system test skipped if none exist

## Out of scope

- Rake task changes
- Legal page
- Games mode (practice only)

## Acceptance criteria

- Selecting Visual + Subtle fetches hint and displays text when API returns ready
- Polling works when API returns pending then ready (manual or integration test)
- URL params restore visual hint type on reload
- No regression to radius/location hints

## Files likely touched

- `app/views/practice/show.html.erb`
- `app/controllers/practice_controller.rb`
- `app/javascript/controllers/practice_controller.js`
- `test/controllers/practice_controller_test.rb`

Match existing Tailwind/button patterns (`btn-primary`, `btn-secondary`). Implement Phase 5 only.
