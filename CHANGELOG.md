# Changelog

All notable changes to this project will be documented in this file.

## [milestone-1] — 2026-05-XX

### Added

- **User accounts**: sign up / sign in / sign out, password reset, profile page, session-based auth with `has_secure_password`, rate-limited credential endpoints. Email + username supported as login identifiers.
- **Admin role** on `User` (`admin: boolean`). Admin-only mutations on the image library, guess scaffold, and game metadata.
- **Image sets**: per-user collections of images with `private` / `public` / system-default visibility. Sets have their own gallery (`/image_sets/:id`), owner-only manage page (`/image_sets/:id/locations`), and map view (`/image_sets/:id/map`).
- **Bulk image upload** via Active Storage direct-upload: browser uploads originals straight to S3, then `ProcessImageJob` resizes + re-encodes (HEIC -> JPEG, libvips). Tab-close-safe (each file attaches as soon as its upload finishes), with monotonic progress, retry-once on failure, and a beforeunload guard. Supports batches of hundreds.
- **Add by URL**: secondary path for adding external images (e.g. Wikimedia) without uploading bytes.
- **Per-game image-set selection**: each `Game` records its source set so the leaderboard can be scoped per-set.
- **GeoGuessr-style scoring**: `round(5000 * exp(-distance_km / 1492.7))`, max 25,000 across 5 rounds. Replaced the milestone-0 binary "win/lose" outcome.
- **Per-game leaderboard** (`/games/leaderboard?image_set_id=N`): top-20, sortable by score or completion date.
- **Results page redesign**: per-round breakdown with thumbnails, summary map (MapLibre) showing all guesses + answers, total distance + total score, "Play Again" / "Leaderboard" / "Back to Games" CTAs.
- **In-round distance feedback**: as soon as you submit a guess, the page shows the great-circle distance with the same `format_distance_compact` formatting used on the results page (no more "0 km" for sub-kilometre guesses).
- **Image set map view**: map at `/image_sets/:id/map` showing every located image in the set, with auto-fit bounds and per-marker popup.
- **Friendly 404s**: `ActiveRecord::RecordNotFound` is caught globally and turned into a redirect with a flash, instead of leaking a stack trace (dev) or showing the bare `public/404.html` (prod).
- **Background-processing rake tasks**: `images:reprocess_pending`, `images:purge_unattached`, `images:destroy_orphans`, `images:mark_legacy_processed`. Recover stuck jobs after a dyno restart drops the `:async` queue.
- **Live processing banner**: locations page polls `processing_status` every 2s and swaps placeholders for real thumbnails as `ProcessImageJob` finishes each image. No full-page reloads.
- **Empty / error states** across games index, leaderboard, image sets index, and locations page.
- **CI workflow** (`.github/workflows/ci.yml`): Brakeman, bundler-audit, importmap audit, RuboCop, full test suite, system tests.
- **Tests** for new model validations, set visibility, leaderboard scoping, GeoGuessr scoring, cross-user authorization, admin gates.

### Changed

- Game results no longer recompute scores from the live `Image.latitude/longitude` — they read `GameImage.answer_latitude/longitude` snapshotted at game-creation time, so retroactively editing an image's coordinates doesn't change scores for already-played games.
- The home page CTA now respects the user's pinned default set (system default, by default; switchable via `/image_sets`).
- New image sets land on the manage-images page (was: gallery view) so the user can immediately upload.
- The bulk-upload UX is the primary path for adding images. The "Add by URL" form is collapsed by default. The single-file form was removed (titles and coords are now editable inline on the manage page after upload).
- `Image.visible_to(user)` now derives from set membership instead of being a flat scope; admins bypass visibility entirely.
- All maps consolidated onto **MapLibre + MapTiler** vector tiles (smooth zoom). Replaces Leaflet on `/images/map` and `/image_sets/:id/map`. Style choice differentiates: `streets-v2` on the in-game and results maps (city/country POIs matter for guessing), `outdoor-v2` on the image-set / all-images maps (terrain shading shows where landscape photos were taken).

### Fixed

- `/images` and `/images/map` now scope to images visible to the current user (was: leaking all images regardless of set visibility).
- Concurrent libvips decodes no longer OOM the 512MB Heroku Basic dyno (`MALLOC_ARENA_MAX=2`, `ACTIVE_JOB_ASYNC_MAX_THREADS=1`, `Vips.cache_set_max(0)`).
- Games index sort dropdown's chevron is always visible (was: invisible on initial render under some browser/Turbo combos).
- Distance < 0.5 km no longer renders as "0 km" — uses `format_distance_compact` everywhere (server and client).

### Removed

- `WIKI.md` (stale milestone-0 README copy)
- `test.txt` (stray test file)
- `app/javascript/controllers/hello_controller.js` (Stimulus scaffold leftover)
- Unused `ImageSet.system_default` and `ImageSet.visible_to` scopes
- Duplicate `haversine_km` definitions in two controllers (now `Game.haversine_km`)
- **Leaflet** dependency (CSS + JS bundle) — superseded by MapLibre across all maps

## [milestone-0] — 2026-04-XX

Initial MVP: anonymous play (no accounts), single global pool of Wikidata-seeded images, binary win/lose outcome, no leaderboard, no uploads.
