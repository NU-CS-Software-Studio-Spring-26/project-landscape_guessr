# AGENTS.md — landscape_guessr

Guidance for AI agents working in this repository. Every factual claim below is grounded in files present in this repo (paths cited in parentheses).

## What this project is

- **GeoGuessr-style web game** where players guess landscape photo locations on a world map (`README.md`).
- **Stack:** Ruby **4.0.2** (`.ruby-version`, `Gemfile`), Rails **8.1.3** (`Gemfile`), PostgreSQL (`Gemfile` `pg` gem; CI `postgres` service in `.github/workflows/ci.yml`), TailwindCSS (`tailwindcss-rails` in `Gemfile`), Hotwire (Turbo + Stimulus via `turbo-rails`, `stimulus-rails`), importmap-rails (no Node bundler), Active Storage + optional AWS S3 (`Gemfile` `aws-sdk-s3`), MapTiler SDK JS for maps (`README.md` → *Conventions → Maps*).

## Repository layout (where code belongs)

| Area | Path | Test path |
|---|---|---|
| Controllers | `app/controllers/` | `test/controllers/` |
| Models | `app/models/` | `test/models/` |
| Service objects | `app/services/` | `test/services/` |
| Background jobs | `app/jobs/` | `test/jobs/` |
| Stimulus controllers | `app/javascript/controllers/` | *(no JS test runner in repo — cover via integration/controller/service tests)* |
| Shared JS helpers | `app/javascript/lib/` | same as above |
| Views / partials | `app/views/` | assert response body in integration tests |
| Tailwind components | `app/assets/tailwind/application.css` | visual/manual; behavior via integration tests |
| Rake tasks | `lib/tasks/` | `test/lib/tasks/` |
| DB migrations | `db/migrate/` | `test/db/` when migration behavior must be asserted |

The repo currently has **37** Minitest files under `test/` (glob `test/**/*_test.rb`). Follow existing naming: `thing_test.rb` for `Thing`.

---

## Mandatory workflow for every feature

### 1. Implement the smallest correct change

Match surrounding code style. Read neighboring files before editing.

### 2. Add or update tests — no exceptions

**Every feature you add or change MUST ship with tests in the same change.** This is non-negotiable.

| Change type | Required test |
|---|---|
| New/changed controller action | `ActionDispatch::IntegrationTest` in `test/controllers/` |
| New/changed model logic/validation/scope | `ActiveSupport::TestCase` in `test/models/` |
| New/changed service object | `ActiveSupport::TestCase` in `test/services/` |
| New/changed job | `ActiveJob::TestCase` in `test/jobs/` |
| Auth / cross-user access | Integration test proving wrong-owner gets `RecordNotFound` → friendly redirect (pattern in `test/controllers/games_controller_test.rb`, `test/controllers/guesses_controller_test.rb` per `README.md`) |
| Bug fix | Regression test that fails without the fix |

**Test conventions (from `test/test_helper.rb` and existing tests):**

- Framework: **Minitest** (`require "test_helper"`), not RSpec.
- HTTP stubbing: **WebMock** (`WebMock.disable_net_connect!` in `test/test_helper.rb`). Stub external APIs; do not hit Wikidata/Gemini/S3 in tests.
- Fixtures: YAML in `test/fixtures/`. Use `users(:alice)`, `images(:one)`, etc. Fixture load order is FK-safe via `FIXTURE_TABLE_NAMES` in `test/test_helper.rb`.
- Integration auth helper: `sign_in_as(user)` defined in `test/test_helper.rb` (`ActionDispatch::IntegrationTest`).
- Parallel tests enabled (`parallelize(workers: :number_of_processors)` in `test/test_helper.rb`).
- Run locally:

```bash
bin/rails db:test:prepare test          # full suite (same as CI test job)
bin/rails test test/path/to/file_test.rb # single file
bin/rails test test/path/to/file_test.rb:LINE  # single test by line
```

CI runs `bin/rails db:test:prepare test` (`.github/workflows/ci.yml` line 113). A separate CI job also runs `bin/rails db:test:prepare test:system` (line 152), but there is currently **no** `test/system/` directory — prefer unit/integration tests unless you deliberately add system tests.

### 3. Run RuboCop before finishing

**Always lint Ruby with GitHub-format output:**

```bash
bin/rubocop -f github
```

This exact command is what CI runs (`.github/workflows/ci.yml` line 74). Use `bin/rubocop`, not a bare global `rubocop`, so the config from `.rubocop.yml` is picked up (`bin/rubocop` prepends `--config`).

Style inherits **rubocop-rails-omakase** (`.rubocop.yml`). Fix offenses; do not disable cops to greenwash.

`bin/ci` (via `config/ci.rb`) runs `bin/rubocop` without `-f github` — when validating agent work, prefer **`bin/rubocop -f github`** to match CI.

There is **no** JavaScript linter in CI. JS security is scanned via `bin/importmap audit` (CI `scan_js` job).

### 4. Do not commit unless explicitly asked

Only create git commits when the user requests it.

---

## Security-critical conventions (from `README.md` and `app/controllers/application_controller.rb`)

- Scope user-owned records through **`Current.user`**, never bare `Model.find(params[:id])`.
- Use **`Image.visible_to(user)`** for image lists and **`ImageSet#playable_by?(user)`** / `require_owner` for set access.
- Admin-only mutations use **`require_admin`** (`ApplicationController`).
- **`RecordNotFound`** is rescued globally → friendly HTML redirect or JSON `:not_found` (`ApplicationController#render_not_found`).
- Map popup HTML must **`escapeText()`** user-controlled strings before `setHTML()` (`README.md` → *Maps*).

---

## DON'Ts

Read this section carefully. Violations here have caused real bugs or CI failures in Rails apps like this one.

### Git & process

- **DON'T** create commits, push, or open PRs unless the user explicitly asks.
- **DON'T** run destructive git commands (`push --force`, `reset --hard`, etc.) without explicit user approval.
- **DON'T** skip hooks (`--no-verify`) unless the user explicitly requests it.
- **DON'T** amend commits that are already pushed or that you did not create in the current session.
- **DON'T** commit secrets (`.env`, API keys, `credentials` contents). Use `.env` locally (`dotenv-rails` in `Gemfile`); production uses Heroku config (`README.md`).

### Testing

- **DON'T** ship a feature without tests. No "I'll add tests later."
- **DON'T** add tests that only assert the obvious (e.g. `assert true`) — test real behavior and regressions.
- **DON'T** hit the real network in tests. WebMock blocks it (`test/test_helper.rb`); stub HTTP instead.
- **DON'T** rely on `db:seed` data in tests — use fixtures.
- **DON'T** assume superuser PostgreSQL privileges. Fixture loading uses `TRUNCATE` fallback when not superuser (`PostgreSQLFixtureLoading` in `test/test_helper.rb`).
- **DON'T** introduce RSpec or a second test framework.
- **DON'T** leave failing or unrun tests. Always run the affected test file at minimum.

### Linting & CI

- **DON'T** finish Ruby changes without running **`bin/rubocop -f github`**.
- **DON'T** add `# rubocop:disable` broadly to silence new offenses — fix the code or discuss with the team.
- **DON'T** assume green locally if you only ran `bin/ci` style step without `-f github` — match CI.
- **DON'T** ignore Brakeman (`bin/brakeman`) or bundler-audit findings when your change introduces security risk.

### Auth & authorization

- **DON'T** use `Game.find`, `ImageSet.find`, etc. for user-facing actions — use `Current.user.…find` (`README.md`).
- **DON'T** expose other users' games, sets, guesses, or private images. Test the cross-user 404/redirect case.
- **DON'T** bypass `require_email_verified` or `require_username_set` flows without understanding gating (`ApplicationController` before_actions).
- **DON'T** add admin-only routes without `require_admin`.

### Database & migrations

- **DON'T** write irreversible migrations. `README.md` Contributing section requires reversible migrations.
- **DON'T** change seed logic without running `bin/rails db:reset` locally to verify clean setup (`README.md`).
- **DON'T** use `ORDER BY RAND()` in Wikidata queries — use `SERVICE bd:sample` (`README.md` → *Wikidata seeder*).

### Active Storage & uploads

- **DON'T** decode/process large HEIC uploads synchronously in the web request — that path uses direct upload + `ProcessImageJob` (`README.md` → *Direct upload*).
- **DON'T** attach blobs without going through the established direct-upload → `attach_blob` flow for user uploads.

### Maps & frontend

- **DON'T** add a raw `<script>` tag for MapTiler — use `ensureMaptilerSdk()` from `app/javascript/lib/maptiler.js` (`README.md`).
- **DON'T** use `data-turbo="false"` to "fix" map bugs — Turbo keeps the SDK warm (`README.md`).
- **DON'T** pass unescaped `Image#title` or other user input into map `setHTML()` popups.
- **DON'T** add npm/webpack/vite — assets go through **importmap-rails** and Stimulus.
- **DON'T** inline large Tailwind utility strings when a component class exists in `app/assets/tailwind/application.css` (`btn-primary`, `form-input`, `page-container`, etc.).

### Background jobs

- **DON'T** assume jobs survive dyno restarts — production uses in-memory `:async` adapter (`config/environments/production.rb`); jobs are lost on restart (`README.md` → *Background-processing caveats*).
- **DON'T** enqueue heavy image work on the request thread.

### AI / external APIs

- **DON'T** call Gemini in tests without stubbing. `GEMINI_API_KEY` is set to a placeholder in `test/test_helper.rb` so classes load; stub the HTTP layer (see `test/services/gemini_hint_generator_test.rb`, `test/services/ai_image_set_generator_test.rb`).
- **DON'T** commit real `GEMINI_API_KEY`, Google OAuth secrets, or AWS keys.
- **DON'T** enable AI hints in tests without `with_ai_hints_config`-style toggles when testing both enabled/disabled paths (see `test/controllers/practice_controller_test.rb`).

### Code quality & scope

- **DON'T** refactor unrelated code in the same change as a feature fix.
- **DON'T** over-engineer (extra abstractions, premature concerns, one-line wrapper classes).
- **DON'T** add verbose comments for self-explanatory code.
- **DON'T** create markdown/doc files the user did not ask for (`README.md`, `CHANGELOG.md`, this file excepted).
- **DON'T** disable CSRF protection outside the test environment.
- **DON'T** use `Model.find_by(...)` for authorization — find through scoped relations so wrong IDs raise `RecordNotFound`.

### Pagination & params

- **DON'T** hand-roll pagination — use `ApplicationController#paginate` and `shared/pagination` partial (`README.md` → *Pagination*).
- **DON'T** accept arbitrary `per_page` values — only `PER_PAGE_OPTIONS` (`ApplicationController`).

### Deployment assumptions

- **DON'T** assume Redis/Solid Queue — commented out in CI; `:async` is the current job backend.
- **DON'T** break Heroku deploy (`Procfile` release migrate + web server; `Aptfile` for libvips/geos per `README.md`).

---

## Quick reference commands

```bash
# Dev server (Puma + Tailwind watcher)
bin/dev

# Full local CI-ish pipeline
bin/ci

# Lint (required format for agents)
bin/rubocop -f github

# Tests
bin/rails db:test:prepare test

# Security scans (also in CI)
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

## CI jobs (`.github/workflows/ci.yml`)

| Job | Command |
|---|---|
| `scan_ruby` | `bin/brakeman`, `bin/bundler-audit` |
| `scan_js` | `bin/importmap audit` |
| `lint` | `bin/rubocop -f github` |
| `test` | `bin/rails db:test:prepare test` |
| `system-test` | `bin/rails db:test:prepare test:system` |

## Further reading

- **`README.md`** — setup, data model, routes, scoring, maps, pagination, contributing rules.
- **`CHANGELOG.md`** — release notes.
- **Existing tests** — best examples of project patterns; read the test closest to your change before writing new ones.
