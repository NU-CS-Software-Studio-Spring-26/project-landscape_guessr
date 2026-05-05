# landscape_guessr

A GeoGuessr-style web game: players see a landscape photograph (mountain, lake, waterfall, etc.) and guess where it is on a world map. Rails 8 + PostgreSQL + TailwindCSS.

## Heroku deployment: https://landscape-guessr-cc7bc949a622.herokuapp.com/

## Team

- Jay Rao
- Andre Shportko
- Mirai Duintjer Tebbens Nishioka
- Leyla Latifova

## Communication

- Meeting every Friday
- 24 hr response
- Completing milestones 1 day before the deadline
- Reactions to message indicating they have been read
- When stuck
  - Patience
  - Try yourself -> Ask teammates -> Ask the professor
  - Document every trial & error

## Decision-making rules

- Decisions are made only by the people affected by it
- Tie-breaking
  - Discussion round
  - Second vote
  - In case there is still a tie, it is broken by the person with the most expertise in the area
- "Disagree and commit"

## Tech stack

- **Ruby** 4.0.2 (pinned via `.ruby-version`)
- **Rails** 8.1.3
- **PostgreSQL** (dev and production — Heroku-compatible)
- **TailwindCSS** via `tailwindcss-rails`
- **MapLibre GL** + **MapTiler outdoor-v2** vector tiles for all maps (smooth zoom, terrain shading, mountain peak labels with elevations, country/region/city POIs). The bright hiking/cycling/via-ferrata trail layers that ship with `outdoor-v2` are programmatically hidden so the map reads as terrain + POIs, not as a trail map.
- **Active Storage** + **AWS S3** for user uploads
- **libvips** (via `image_processing`) for HEIC -> JPEG conversion, resize, color-space normalization

## Prerequisites

- Ruby 4.0.2 — install via your version manager (rbenv, asdf, mise, rvm). `.ruby-version` is honored by all of them.
- PostgreSQL 14+ running locally. On macOS: `brew install postgresql@16 && brew services start postgresql@16`.
- libvips for image processing. On macOS: `brew install vips`. On Linux: `apt-get install libvips42`. (Heroku gets it via `Aptfile`.)

## Setup

```bash
git clone <this-repo>
cd project-landscape_guessr
bundle install
bin/rails db:create db:migrate db:seed   # creates DB, migrates, fetches ~1400 images from Wikidata, adds demo users (dev only)
bin/dev                                  # starts Puma (port 3000) + Tailwind watcher
```

`bin/dev` uses foreman — if you hit `foreman: not found`, run `gem install foreman`.

To play, sign up at `/registration/new`. Practice mode (`/practice`) and image browsing are available without an account; starting/playing games requires sign-in.

In development, seeds also create three demo accounts so the leaderboard isn't empty: **alice**, **bob**, **charlie** (all with password `password123`). They're never seeded in production — that would mean public, world-readable creds for the deployed app.

To manage the image library or edit past guesses through the UI, you need an admin account. Sign up normally, then promote yourself via `bin/rails c`: `User.find_by(email_address: "you@x").update(admin: true)`. On Heroku: `heroku run rails console`.

### S3 / Active Storage setup (for user uploads)

User-uploaded images go through Active Storage's direct-upload flow. Development defaults to local disk (`storage/`) — no AWS setup required. Production uses S3.

To exercise the S3 path locally (parity testing), flip `config.active_storage.service` to `:amazon` in `config/environments/development.rb` and export:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export S3_BUCKET=landscape-guessr-dev
export AWS_REGION=us-east-2
```

## Data model

| Model | Belongs to | Has many | Key columns |
|---|---|---|---|
| `User` | — | `sessions`, `games`, `image_sets` | `email_address`, `username`, `password_digest`, `admin` |
| `Session` | `User` | — | `ip_address`, `user_agent` |
| `Game` | `User`, `ImageSet?` | `game_images`, `guesses`, `images` (through `game_images`) | `status`, `score`, `completed_at` |
| `GameImage` | `Game`, `Image` | — | `position` (1–5), `answer_latitude`, `answer_longitude` (snapshot at game-creation time) |
| `Image` | — | `guesses`, `game_images`, `image_set_items`, `image_sets` (through items) | `url`, `latitude`, `longitude`, `title`; optional `photo` Active Storage attachment |
| `ImageSet` | `User?` | `image_set_items`, `images` (through items), `games` | `name`, `visibility` (`private`\|`public`), `is_system_default` |
| `ImageSetItem` | `ImageSet`, `Image` | — | `latitude`, `longitude` (per-set override of the image's coords) |
| `Guess` | `Game`, `Image` | — | `latitude`, `longitude` (player's pick) |

`GameImage.answer_latitude/longitude` snapshots the answer at game-creation time, so retroactively editing an image's coordinates doesn't change scores for already-played games.

`ImageSet` partitions the world's images into curated buckets:
- exactly one set has `is_system_default: true` (`Default Landscapes`, seeded from Wikidata) — public, ungated, the default for new games.
- user-created sets are either `private` (only the owner can see/play) or `public` (anyone can play, leaderboard is shared).

The `Image.visible_to(user)` scope (in `app/models/image.rb`) is the canonical way to gate image lists: it returns images that live in *at least one* set the user can see — the system default, any public set, or any set they own. `ImageSet#playable_by?(user)` is the corresponding gate for set-level access.

## Routes (high-level)

| Route | Purpose |
|---|---|
| `/` | Landing page; primary CTA = "Start new game" on the system-default set |
| `/registration/new`, `/session/new`, `/passwords/new` | Sign up, sign in, password reset |
| `/profile` | Current user's profile |
| `/games` | List of your games (filter by status, sort by date or score) |
| `/games/:id` | Play the next round of an in-progress game |
| `/games/:id/results` | Per-round breakdown + summary map after game finishes |
| `/games/leaderboard?image_set_id=N` | Top-20 leaderboard scoped to an image set |
| `/image_sets` | Your sets + the public catalog |
| `/image_sets/:id` | Read-only gallery view of a set |
| `/image_sets/:id/locations` | Owner-only: upload, edit titles/coords, remove items |
| `/image_sets/:id/map` | Map of all located images in a set |
| `/images`, `/images/map` | Images list / world map (admins see all; everyone else sees `Image.visible_to`) |
| `/practice` | Single-image guessing without saving a game (no auth required) |

## Scoring

Per-round score follows the classic GeoGuessr formula:

`round_score = round(5000 * exp(-distance_km / 1492.7))`, clamped to `[0, 5000]`.

A game has 5 rounds, so the maximum total score is 25,000. Distances in the UI use `format_distance_compact` (helper at `app/helpers/games_helper.rb`): sub-kilometre guesses render as "847 m", 1-10 km as "1.5 km", farther as "47 km". The same formatting runs client-side in `app/javascript/controllers/game_controller.js`.

## Seed data

`db/seeds.rb` fetches ~1400 landmarks from Wikidata's SPARQL endpoint across 14 landform types (mountains, lakes, waterfalls, volcanoes, canyons, islands, glaciers, valleys, rivers, fjords, cliffs, beaches, capes, lagoons). Each re-seed pulls a fresh random sample. Idempotent — re-running won't duplicate.

In development only, three demo users (alice / bob / charlie) are also seeded with 1-2 completed games each so the leaderboard demos out of the box.

| Command                    | Effect                                                              |
| -------------------------- | ------------------------------------------------------------------- |
| `bin/rails db:seed`        | Adds new records, skips existing                                    |
| `bin/rails db:reset`       | Destroys DB -> recreates -> migrates -> seeds (wipes Games/Guesses too) |
| `bin/rails db:seed:replant`| Truncates tables, then seeds (keeps schema)                         |

## Deploying to Heroku

The live deployment uses Heroku's Basic dyno + Heroku Postgres + a separate AWS S3 bucket for image storage. To replicate:

```bash
heroku create your-app-name
heroku addons:create heroku-postgresql:essential-0
heroku buildpacks:add --index 1 heroku-community/apt   # pulls libvips42 via Aptfile
heroku buildpacks:add heroku/ruby
heroku config:set AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... S3_BUCKET=... AWS_REGION=...
heroku config:set MALLOC_ARENA_MAX=2 ACTIVE_JOB_ASYNC_MAX_THREADS=1   # caps glibc heap fragmentation + concurrent libvips decodes; needed on 512MB dynos
git push heroku main:main
heroku run rails db:migrate db:seed
heroku run rails console   # then: User.find_by(email_address: "...").update!(admin: true)
```

### Background-processing caveats (`:async` queue)

Image conversion (HEIC -> JPEG, resize, ICC) runs in `ProcessImageJob` via Active Job's in-memory `:async` adapter. **Jobs queued in memory are dropped on dyno restart** (deploys, daily cycles, OOMs). To recover:

- `bin/rails images:reprocess_pending` — re-enqueue any Image whose attached blob isn't yet processed (idempotent — finished images skip themselves).
- `bin/rails images:purge_unattached[hours]` — delete S3 blobs that were direct-uploaded but never attached (e.g. user closed the tab mid-upload). Default is 24h.

If milestone-2 needs jobs to survive restarts, swap `:async` for `solid_queue` (Rails 8 built-in, DB-backed; ~30 min including Puma plugin so no separate worker dyno is needed).

## Conventions

A few patterns that aren't obvious from the code but are easy to break.

### Auth scoping (security-critical)

Any controller action touching a user-owned record must scope through `Current.user`, never `Model.find` directly. So:

```ruby
# Right — wrong-owner request raises RecordNotFound, which
# ApplicationController#rescue_from rewrites into a friendly redirect
@game = Current.user.games.find(params[:id])

# Wrong — silently exposes other users' games
@game = Game.find(params[:id])
```

Same for nested writes: `Current.user.games.find(...).guesses.create!(...)`. Tests cover the cross-user 404 case in `test/controllers/games_controller_test.rb` and `guesses_controller_test.rb`.

For image-set access, the canonical gates are `ImageSet#playable_by?(user)` (read access — owner / public / system default) and the `require_owner` before-action in `ImageSetsController` (write access). For the image library, use `Image.visible_to(user)`; admins bypass the visibility scope entirely (see `ImagesController#index`).

Mutating the image library, editing past guesses, and editing game metadata are admin-only. Game `score`, `status`, and `completed_at` are written by the backend during gameplay (results action) — the `/games/:id/edit` form exists only as an admin debug tool. Users can still destroy their own games. Use the `require_admin` before-action in `ApplicationController` for any future controller action that should be restricted to admins.

### Friendly 404s

`ApplicationController` catches `ActiveRecord::RecordNotFound` globally and redirects to either `redirect_back` or `root_path` with a flash, instead of letting the bare 404 page or a dev stack trace leak out. JSON requests still get a `:not_found` status.

### Direct upload + background processing

User-uploaded images go through Active Storage's direct-upload flow:
1. Browser PUTs the original (HEIC/JPEG/...) straight to S3 via `DirectUpload`. The web dyno never sees the original bytes.
2. JS calls `POST /image_sets/:id/attach_blob` per file, attaching the blob to a freshly-created `Image` and adding it to the set.
3. `ProcessImageJob` runs in the `:async` queue: downloads the blob, extracts EXIF GPS, resizes + re-encodes to JPEG, replaces the attachment.
4. Locations page polls `GET /image_sets/:id/processing_status` every 2s and swaps placeholders for thumbnails as items finish.

This avoids R14 OOMs on Heroku Basic (which would happen if the dyno tried to receive + decode large HEICs synchronously) and lets bulk uploads of hundreds of files survive a tab close mid-upload.

### Maps

All maps use **MapLibre GL JS** with **MapTiler outdoor-v2** vector tiles. Three Stimulus controllers — `image_map`, `guess_map`, `results_map` — share a single MapTiler key, a small lazy-loader for the MapLibre script, and a `hideOutdoorTrails(map)` helper that runs on `style.load` to suppress the layers in `source: "outdoor", source-layer: "trail"` (the bright hiking/cycling/via-ferrata overlays ship with the style and would otherwise clutter the guessing UX). Mountain peaks, contours, terrain shading, and POI labels (country / region / city / village) all stay. Adding a new map page = include `shared/_maplibre_assets` in `content_for(:head)` plus one of the controllers. No inline `<script>` tags, so Turbo navigation works without `data-turbo="false"` workarounds.

### Component classes (Tailwind)

Reusable styles live in `app/assets/tailwind/application.css` as `@apply` component classes. Reach for these before stringing utilities together — keeps things consistent and means a re-theme is one edit, not a grep-and-replace.

- Buttons: `btn-primary` / `btn-secondary` / `btn-danger` / `btn-ghost` (subtle inline links)
- Forms: `form-input` (and `form-input-error` for validation states), `select-with-arrow` (custom chevron — pair with `pr-8`)
- Layout: `page-container` (max-width wrapper for top-level pages)
- Typography: `heading-hero` / `heading-page` / `heading-section`, `eyebrow` (small all-caps label), `muted` (gray caption text)

### Wikidata seeder

`db/seeds.rb` uses **`SERVICE bd:sample`** for random sampling — not `ORDER BY RAND()` or hashed orderings, both of which time out at scale when unioning multiple landform types. `bd:sample` accepts only a single triple pattern, so the seeder samples by `wdt:P31` (instance-of) inside the `SERVICE` block and joins `wdt:P18`/`wdt:P625` outside. Over-sampling (`limit 2000`) is intentional — only ~5–20% of any landform type has both an image and coordinates. Filenames are filtered for non-photo contamination (satellite imagery, maps); when adding new landform types, spot-check for new junk patterns.

## Contributing

- Branch from `main`: `git checkout -b branch-name`
- Keep migrations reversible
- After seed changes, run `bin/rails db:reset` locally to verify a clean setup works
- Open a PR against `main`

See [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

## Entity Relationship Diagram

[ERD on Miro](https://miro.com/app/board/uXjVGjb-zPA=/?share_link_id=966004402068)

## Similar products

- [GeoGuessr](https://www.geoguessr.com/)
- [OpenGuessr](https://openguessr.com/)
- [GeoHub](https://www.geohub.gg/)
- [Guess Where You Are](https://guesswhereyouare.com/)
- [Geotastic](https://geotastic.net)
