# Changelog

All notable changes to **Landscape Guessr** are summarized here. This project is a GeoGuessr-style Rails app: landscape photos pulled from Wikidata, guess positions on an interactive map, scoring, multiplayer-style leaderboards for signed-in players, and an admin-maintained image library.

Entries are grouped by recurring merge themes and approximate release windows reflected in Git history (`main` line of development, Spring 2026). Older items appear toward the bottom.

---

## [Unreleased]

### Fixed

- **2026-05-04** — Reverted accidental hardcoding of PostgreSQL user/host in `config/database.yml` so local and hosted environments can continue to use standard configuration (e.g. `DATABASE_URL` on Heroku).

---

## Milestone 1 — image library & admin workflows (2026-05-04)

### Added

- **Image sets** — Curated sets of images with admin routes for managing locations, adding single images, and bulk upload.
- **Results map** — Richer visualization of results alongside gameplay completion flows (aligned with the “image sets, file uploads, and results map” integration).

### Changed

- Merged parallel feature branches (`jay_mvp`, `andre`) into the milestone-1 line so image-set work and related UI live on the same integration branch as the rest of the app.

---

## Milestone 1 — scoring & leaderboard (2026-05-01 to 2026-05-03)

### Added

- **Scoring tests** — Unit coverage around scoring logic to lock in GeoGuessr-style distance-based behavior.
- **Leaderboard** — Collection route (`/games/leaderboard`) and sorting so completed games rank predictably.

### Changed

- **Scoring algorithm** — Switched toward GeoGuessr-style scoring (great-circle distance with tuned points) rather than naive total-distance-only presentation.
- **Leaderboard ordering** — Fixed ordering bugs so rankings match the intended sort (higher scores / better performance surface correctly).

---

## Accounts, admin hardening & security (2026-04-24 to 2026-04-28)

### Added

- **User accounts** — Sign up, sessions, passwords, and per-user game ownership aligned with Rails 8 conventions (`Current.user` scoping).
- **Admin role** — `User#admin`; promotion via console for operational control on Heroku and locally.
- **Authorization** — Image library mutations, destructive or sensitive game/guess edits, and similar actions restricted to admins; ordinary players scoped to their own records (404 when crossing users).

### Changed

- **Per-game image sets** — Each game materializes a fixed sequence of five images (`game_images` with positions 1–5) so replays and challenges use an identical round list.
- **README** — Documented auth, practice vs signed-in flows, admin setup, and security conventions (no `Model.find` for user-owned rows).

### Fixed

- **Auth-related UI** — Follow-up fixes after the accounts landing (flash on successful login/logout, assorted UI bugs from the first auth pass).

---

## Milestone 0 — playable game on Heroku (2026-04-22)

### Added

- **Landing & game shell** — `home#start` as root: start a new game, list previous games, link to practice.
- **Game lifecycle** — Status tracking, score persisted on completion, results member route for finished games.
- **Integrated map in play** — Shared MapLibre-based guess map on the game screen; per-round results shown on the map after each guess.
- **Model tests** — Unit tests for `Image`, `Game`, and `Guess`.

### Changed

- **Heroku deployment** — Production database configuration aligned with Heroku Postgres; replaced Solid Cache / Queue / Cable stack with in-memory-friendly alternatives so the app boots and runs within common free-tier constraints.
- **Ruby & gems** — Ruby and lockfile updates on the path to a stable Heroku build.

### Fixed

- **Turbo & long requests** — Disabled Turbo on game-creation buttons to avoid timeout/hang behavior when starting a game on Heroku.
- **Review round** — Nil-image guard, clearer error feedback, round numbering, and documentation (WIKI) updates for milestone requirements.
- **CI** — Repaired fixtures, stale assertions, and Brakeman configuration so the pipeline stays green.

---

## Early gameplay & results (2026-04-20 to 2026-04-21)

### Added

- **Game view** — First pass at playing through rounds in the browser.
- **Results** — Games `results` action and total-distance scoring on completion.
- **Practice polish** — Map tile experiments (OpenFreeMap Liberty, then MapTiler Streets), open photo in a new tab, space bar to submit or advance, centered image with preserved aspect ratio.

### Changed

- **README / WIKI** — Milestone-oriented documentation updates.

---

## Foundations — data, browse, practice (2026-04-17 to 2026-04-20)

### Added

- **Rails app skeleton** — Initial commit, Ruby version pinning, core models.
- **Wikidata seeding** — SPARQL-driven import of landscape-type entities with coordinates and representative images; randomized sampling via `SERVICE bd:sample`; filters to reduce non-photo noise.
- **Image index** — Browse seeded photos at `/images`.
- **Image map** — Geo view of the catalog.
- **Practice mode** — `/practice` with MapLibre GL for trying the map interaction without a full scored game.

### Changed

- **Seeding** — Iterative improvements to randomization, deduplication on re-seed, and robustness of the sampler.

---

## Project metadata

- **Repository name:** `landscape_guessr` (team: Jay Rao, Andre Shportko, Mirai Duintjer Tebbens Nishioka, Leyla Latifova).
- **Stack (current direction):** Ruby 4.0.x, Rails 8.1.x, PostgreSQL, Tailwind via `tailwindcss-rails`, MapLibre GL in the browser.
- **Public demo:** See `README.md` for the Heroku URL when the deployment is live.

---

## How to read this file

- **“Added”** — New user-visible features, models, routes, or operational capabilities.
- **“Changed”** — Behavior or implementation adjustments that are not purely fixes.
- **“Fixed”** — Bug fixes, regressions, or broken deployment/CI issues.

For low-level file-by-file history, use `git log`. For setup, data model, and contributor rules, prefer `README.md`.
