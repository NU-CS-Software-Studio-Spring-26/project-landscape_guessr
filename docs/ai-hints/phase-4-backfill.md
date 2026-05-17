# Phase 4 — Rake backfill task

Copy everything below this line into a **new Cursor chat**.

---

## Task

Implement **Phase 4 only**: a rake task to pre-generate cached AI hints for many images, respecting Gemini **free-tier rate limits**. Assume **Phases 0–3** exist.

Do **not** change practice UI (Phase 5).

## Project context

- ~1400 seeded images in default set (Wikimedia URLs)
- `GenerateAiHintJob` writes `ImageAiHint` rows
- `GeminiConfig.enabled?` must be true to run
- Free tier: low RPM/RPD — task must throttle (e.g. sleep 4s between enqueues ≈ 15 RPM, or configurable `sleep`)
- `Image.visible_to` not needed for backfill — operate on images with lat/lng in default set and/or all located images

## Requirements

1. **Rake task** in `lib/tasks/images.rake` (or `ai_hints.rake`):

   ```bash
   bin/rails images:generate_ai_hints[tier,limit,sleep_seconds]
   ```

   - `tier` — 1, 2, or 3 (required)
   - `limit` — optional max images (default: all)
   - `sleep_seconds` — optional delay between job enqueues (default: 4)

2. **Scope** (document in task description):
   - Default: images in system default `ImageSet` with non-null lat/lng
   - Option: `SCOPE=all` env for all located images

3. **Logic per image**:
   - Skip if `ImageAiHint` already `ready` for `(image_id, tier)` and `prompt_version` matches `GeminiHintGenerator::PROMPT_VERSION` (or constant on model)
   - Skip if `pending` (optional: don’t duplicate enqueue)
   - Else `GenerateAiHintJob.perform_later(image.id, tier)` and sleep

4. **Guardrails**:
   - Abort with message if `!GeminiConfig.enabled?`
   - Print progress: `enqueued N, skipped M`
   - Idempotent — safe to re-run

5. **Optional**: `images:generate_ai_hints:stats` — count ready/pending/failed per tier

6. **README** snippet (small): how to run backfill locally and on Heroku (`heroku run rails images:generate_ai_hints[1,100,4]`)

## Out of scope

- Practice UI
- Changing generator prompts (unless fixing a bug)
- Automatic enqueue from `ProcessImageJob` (optional nice-to-have — only if trivial; otherwise skip)

## Acceptance criteria

- Task runs in development without error when Gemini disabled → clear abort message
- With stubbed job in test, task enqueues expected count (unit test optional but appreciated)
- Document estimated time for full backfill (e.g. 1400 × 4s ≈ 93 minutes per tier at 15 RPM)

## Files likely touched

- `lib/tasks/images.rake` or `lib/tasks/ai_hints.rake`
- `README.md` (short subsection)
- Optional `test/lib/tasks/...` if project tests rake tasks

Implement Phase 4 only.
