# landscape_guessr

A GeoGuessr-style web game: players see a landscape photograph (mountain, lake, waterfall, etc.) and guess where it is on a world map. Rails 8 + PostgreSQL + TailwindCSS.

## Heroku deployment: [https://landscape-guessr-cc7bc949a622.herokuapp.com/](https://landscape-guessr-cc7bc949a622.herokuapp.com/)

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
- **MapTiler SDK JS** (wraps MapLibre GL) for all maps, with session-based tile billing and per-`ImageSet` basemap (`outdoor-v2` default; streets / bright / topo / satellite / hybrid). See *Conventions → Maps* for the loader, trail-hiding, and Turbo gotchas.
- **Active Storage** + **AWS S3** for user uploads
- **Stripe Checkout** for the footer "Support us" donation flow (test mode friendly)
- **libvips** (via `image_processing`) for HEIC -> JPEG conversion, resize, color-space normalization
- **rgeo** for point-in-polygon checks when materializing filtered image sets
- **PostgreSQL extensions** (`pg_trgm`, `unaccent`) for typo-tolerant region search; **GeoNames** + **Nominatim** as data sources for the regions tree (continent → country → admin1 → admin2 → city)

## Prerequisites

- Ruby 4.0.2 — install via your version manager (rbenv, asdf, mise, rvm). `.ruby-version` is honored by all of them.
- PostgreSQL 14+ running locally. On macOS: `brew install postgresql@16 && brew services start postgresql@16`.
- libvips for image processing. On macOS: `brew install vips`. On Linux: `apt-get install libvips42`. (Heroku gets it via `Aptfile`.)
- libgeos for region polygon operations (used by `regions:seed_all` and the filter-set matcher). On macOS: `brew install geos`. On Linux: `apt-get install libgeos-dev`. The `rgeo` gem compiles its C extension against libgeos at install time, so make sure libgeos is present **before** running `bundle install`. (Heroku gets it via `Aptfile`.)

## Setup

```bash
git clone <this-repo>
cd project-landscape_guessr
bundle install
bin/rails db:create db:migrate db:seed   # creates DB, migrates, fetches ~1400 images from Wikidata, adds demo users (dev only)
bin/rails regions:seed_all               # ~10 min: seeds the GeoNames regions tree (~200k rows). Optional — needed only for filtered-set creation.
bin/dev                                  # starts Puma (port 3000) + Tailwind watcher
```

`bin/dev` uses foreman — if you hit `foreman: not found`, run `gem install foreman`.

To play, sign up at `/registration/new`. Practice mode (`/practice`) and image browsing are available without an account; starting/playing games requires sign-in.

In development, seeds also create three demo accounts so the leaderboard isn't empty: **alice**, **bob**, **charlie** (all with password `password123`). They're never seeded in production — that would mean public, world-readable creds for the deployed app.

To manage the image library or edit past guesses through the UI, you need an admin account. Sign up normally, then promote yourself via `bin/rails c`: `User.find_by(email_address: "you@x").update(admin: true)`. On Heroku: `heroku run rails console`.

### Google sign-in (optional)

Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in `.env` (loaded by `dotenv-rails` in dev). Get them from Google Cloud Console → Google Auth Platform → Clients → Web application; add `http://localhost:3000/auth/google_oauth2/callback` as an authorized redirect URI. Without them, the "Sign in with Google" button errors but password sign-in still works.

### AI practice hints (optional)

AI-generated visual hints for practice mode use the [Gemini API](https://ai.google.dev/). This is separate from Google OAuth sign-in credentials. The same key powers [AI-generated image sets](#ai-generated-image-sets-optional) below.

1. Create an API key at [Google AI Studio](https://aistudio.google.com/apikey) (sign in with a Google account; no Cloud project required for the free tier).
2. Copy `.env.example` to `.env` (or add to your existing `.env`) and set:


| Variable           | Required          | Default                 | Purpose                                                                                           |
| ------------------ | ----------------- | ----------------------- | ------------------------------------------------------------------------------------------------- |
| `GEMINI_API_KEY`   | When hints are on | —                       | API key from AI Studio                                                                            |
| `GEMINI_MODEL`     | No                | `gemini-2.5-flash-lite` | Model id sent to the Gemini API (hints only — image-set generation pins its own Flash/Pro models) |
| `AI_HINTS_ENABLED` | No                | off                     | Set to `1` (or `true`) to enable when a key is present                                            |


The app boots fine without these variables. `GeminiConfig.enabled?` is `true` only when `AI_HINTS_ENABLED` is truthy **and** `GEMINI_API_KEY` is set. Later phases call the API only when enabled.

Billing and rate limits follow [Google AI pricing](https://ai.google.dev/pricing) for your key; the free tier applies unless you upgrade the project. See [AI Studio rate limits](https://ai.google.dev/gemini-api/docs/rate-limits) for RPM/TPM caps — pre-generate hints with the backfill task so practice mostly reads the cache. Concurrent practice users rarely hit the API unless many request uncached hints at once. Do not commit API keys — use `.env` locally and `heroku config:set` in production.

**Backfill cached hints** (optional, after enabling Gemini): enqueue `GenerateAiHintJob` for located images in the default set, throttled for free-tier RPM. Skips rows already `ready` at the current prompt version or `pending`.

```bash
# tier 1, first 100 images, 4s between enqueues (~15 RPM)
bin/rails "images:generate_ai_hints[1,100,4]"

# all default-set images, tier 1, default 4s sleep (~93 min for ~1400 images)
bin/rails "images:generate_ai_hints[1,,4]"

# every located image (not only the default set)
SCOPE=all bin/rails "images:generate_ai_hints[2]"

bin/rails images:generate_ai_hints:stats
```

On Heroku (quote the task name so the shell does not glob brackets):

```bash
heroku run 'rails images:generate_ai_hints[1,100,4]'
```

Run a worker dyno or `bin/jobs` locally so enqueued jobs actually execute.

### AI-generated image sets (optional)

Signed-in users can build an image set from a natural-language prompt ("volcanoes in Japan", "streets near the Eiffel Tower", "Mount Fuji photos") at `/image_sets/ai_new`. A Gemini agent (`AiImageSetGenerator`) picks one of three image sources, resolves any Q-IDs / region names via tool calls, the pipeline counts and previews matches, and the user confirms before the import job creates the set.

**Sources** (`image_sets.ai_image_source`):

- `wikidata` — default for topic+region prompts (`churches in Paris`, `lakes in Massachusetts`). One canonical Commons photo per Wikidata item, via `WikidataImporter`.
- `commons` — high-volume / single-subject prompts (`Mount Fuji photos`, `many photos of buildings in Boston`). Topic Q-ID → P373 → Commons category, then CirrusSearch `deepcategory:` + `nearcoord:` via `CommonsImporter`. For topic+region it builds the region-anchored category (`Buildings in Boston`); region-less subjects are anchored on the topic's own P625 coordinate. Only geotagged files are kept (the `coordinates` prop is paged with `colimit` so it isn't capped at 10 per request), and display URLs are `Special:FilePath/<file>` (thumb size applied by `image_src ?width`) — not server-rendered thumbnails, which would break pagination.
- `mapillary` — street-level imagery (`streets in Chicago`, `driving through Sweden`, `streets around the world`). `MapillaryImporter` picks one of three scales by region size: **small** (≤ a z=14 fetch budget — a neighbourhood, radius, or most cities) fetches every z=14 `image` tile; **medium** (metro → country) builds a coverage map from low-zoom `sequence` tiles — fetching every tile that tiles the region up to a cap (a city ≈ z11, a country ≈ z6) to learn which z=14 tiles have imagery — then fetches z=14 tiles only at covered locations within the region polygon, **round-robin-filling the budget across the covered cells** so a dense centre inside a large bbox (e.g. Beijing's municipality) isn't starved; **large** (continent / world / huge country like the USA — where the `image` layer doesn't exist below z14 and the `sequence` probe is too sparse) uses the globally-decimated z=4/5 `overview` POINT layer (≈150 z4 tiles blanket the world) for an even global spread. Results are spatially thinned and panoramas excluded. Requires `MAPILLARY_TOKEN` in env.

**Sub-region modes** (consumed by `RegionResolver`):

- *Mode A* — in-DB named region (`world` / continent / country / admin1 / admin2 / city). `world` ("streets around the world") returns the global bbox; the rest trigger a Nominatim boundary fetch (point-bbox seeds **and** countries/states, so Commons/Mapillary refine against the real polygon instead of leaking into neighbours sharing the bbox). The boundary lookup drops a duplicated admin1 part (`Tokyo, Tokyo, Japan` → `Tokyo, Japan`, which otherwise returns a street address → a reverse-geocode sliver), picks among up to 5 candidates the polygon that *contains the place's centroid* (so a Point #1 result doesn't sink Istanbul/Cusco), and — **for cities only** — clips far-flung islands from the result (Tokyo's Pacific chain, Shanghai's offshore islets) while keeping contiguous metro pieces (Staten Island, Chongming).
- *Mode B* — POI hull / single landmark. Geocodes the names via OpenStreetMap Nominatim (`GeocoderService`).
- Optional `region_radius_meters` recenters a bbox of that radius on the resolved base — used for `near X` and `Nkm around Y` prompts. The radius is enforced as a circular polygon (not just the square bbox), so importers drop points beyond the radius. Ambiguous city names resolve to the most-populous match — both with no `parent_name` (`Paris` → France, not Paris, Ontario) and when a country-level `parent_name` matches several same-named cities (`Brooklyn, United States` → NYC's Brooklyn, not Brooklyn, Indiana).

Directional sub-region splits (`north half of Chicago`), multi-region prompts, and named routes are refused with a redirect to the existing filter-by-area workflow. Regions whose geometry crosses the 180° meridian (Russia, New Zealand, Fiji, Kiribati) resolve to a degenerate ~360°-wide bbox that corrupts the tile/probe math, so they're refused with a "pick a more specific sub-region" message rather than importing almost nothing.

**Count accuracy.** Each source estimates "Up to N" to match what the import will actually deliver: Wikidata caps the `COUNT(*)` scan with a `LIMIT HARD_CAP` subquery (an uncapped P279* count over a country — `castles in Germany` ≈ 232k — otherwise times out) and skips the SERVICE box entirely for global regions; Commons counts the *same* probes the import fetches, concurrently, clamped to the import ceiling (the old uniform-stride extrapolation reported 0 for `churches in France`); Mapillary clamps to its 4,000-image cap. A completed import that yields zero images is surfaced as a clear "no coverage" message, never a silent empty set.

A completed proposal is **single-use**: importing it stamps `ai_generations.imported_at`, so the same proposal can't be replayed to trigger repeated (uncapped) imports — re-importing requires a new generation.

- **Enabled when `GEMINI_API_KEY` is set** — no separate flag (independent of `AI_HINTS_ENABLED`, which only gates practice hints).
- `MAPILLARY_TOKEN` (a Mapillary Access Token, not Client Secret) is required only when users invoke Mapillary-source prompts. See `.env.example`.
- Capped at **20 generations per user per day** (`AI_DAILY_LIMIT` in `ImageSetsController`); counter persists in the `ai_usages` table so it survives dyno restarts.
- Agent loop and import run inside `AiGenerationJob` / `AiImportImagesJob` on the `:async` queue, so the browser polls `/ai_generations/:id/status` while it works — see the dyno-restart caveat under *Background-processing caveats* below.

### Stripe support button (optional)

The footer has a **Support us** button that starts a Stripe Checkout session for a one-time **$3 USD** demo donation toward hosting costs. It is wired for Stripe test mode: set `STRIPE_SECRET_KEY` to a Stripe test secret key locally or in Heroku config. If the key is missing, the button redirects home with "Donations are not available right now." instead of calling Stripe.

Checkout returns to `/donation/success` after payment and `/donation/cancel` if the user backs out. The button is available to signed-in and signed-out visitors.

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


| Model              | Belongs to                    | Has many                                                                                        | Key columns                                                                                                                                                                                                                                                                                                |
| ------------------ | ----------------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `User`             | —                             | `sessions`, `games`, `image_sets`, `connected_services`                                         | `email_address`, `username` (nullable while OAuth users pick one), `password_digest`, `admin`                                                                                                                                                                                                              |
| `Session`          | `User`                        | —                                                                                               | `ip_address`, `user_agent`                                                                                                                                                                                                                                                                                 |
| `ConnectedService` | `User`                        | —                                                                                               | `provider`, `uid`, `email` (unique on `[provider, uid]`; maps OAuth identities to users)                                                                                                                                                                                                                   |
| `Game`             | `User`, `ImageSet?`           | `game_images`, `guesses`, `images` (through `game_images`)                                      | `status`, `score`, `completed_at`                                                                                                                                                                                                                                                                          |
| `GameImage`        | `Game`, `Image`               | —                                                                                               | `position` (1–5), `answer_latitude`, `answer_longitude` (snapshot at game-creation time)                                                                                                                                                                                                                   |
| `Image`            | —                             | `guesses`, `game_images`, `image_set_items`, `image_sets` (through items)                       | `url`, `latitude`, `longitude`, `title`; AI-source provenance (`external_source` ∈ {`wikidata`, `commons`, `mapillary`}, `external_id`, `author`, `license`); optional `photo` Active Storage attachment                                                                                                                                                                                                                        |
| `ImageSet`         | `User?`, `ImageSet?` (parent) | `image_set_items`, `images` (through items), `games`, `filtered_sets`, `image_set_tags`, `tags` | `name`, `visibility` (`private`|`public`), `is_system_default`, `map_style`, `parent_image_set_id`, `region_ids` (bigint[]), `custom_areas` (jsonb), AI-import bookkeeping (`ai_prompt`, `ai_query`, `ai_model`, `ai_image_source`, `ai_source_params` (jsonb — `topic_qid`, `commons_intitle_fallback`, `mapillary_min_year`, …), `ai_region_filter` (jsonb descriptor: Mode A/B + optional radius), `import_state`, `import_progress`, `import_total`, `import_warnings`) |
| `ImageSetItem`     | `ImageSet`, `Image`           | —                                                                                               | `latitude`, `longitude` (per-set override of the image's coords)                                                                                                                                                                                                                                           |
| `Region`           | `Region?` (parent)            | `children` (self-join)                                                                          | `name`, `admin_level` (`continent`|`country`|`admin1`|`admin2`|`city`), `iso_code`, `boundary` (jsonb GeoJSON), `population`, `min_lat`/`max_lat`/`min_lng`/`max_lng`, `normalized_name`                                                                                                                   |
| `Tag`              | —                             | `image_set_tags`, `image_sets`                                                                  | `name`, `slug` (parameterized lowercase value used for default case-insensitive filters)                                                                                                                                                                                                                   |
| `ImageSetTag`      | `ImageSet`, `Tag`             | —                                                                                               | join table with uniqueness on `[image_set_id, tag_id]`                                                                                                                                                                                                                                                     |
| `Guess`            | `Game`, `Image`               | —                                                                                               | `latitude`, `longitude` (player's pick)                                                                                                                                                                                                                                                                    |
| `AiGeneration`     | `User`                        | —                                                                                               | `user_message`, `conversation_json`, `status` (`pending`/`running`/`completed`/`failed`/`canceled`), `phase`, `progress_message`, `result_json` + `result_count` + `preview_json` (filled as the job runs), `error`, `model_used`, `imported_at` (set on import → single-use proposal)                       |
| `AiUsage`          | `User`                        | —                                                                                               | `day`, `count` (unique on `[user_id, day]`) — daily counter for the AI image-set rate limit                                                                                                                                                                                                                |


`GameImage.answer_latitude/longitude` snapshots the answer at game-creation time, so retroactively editing an image's coordinates doesn't change scores for already-played games.

`ImageSet` partitions the world's images into curated buckets:

- exactly one set has `is_system_default: true` (`Default Landscapes`, seeded from Wikidata) — public, ungated, the default for new games.
- user-created sets are either `private` (only the owner can see/play) or `public` (anyone can play, leaderboard is shared).

The `Image.visible_to(user)` scope (in `app/models/image.rb`) is the canonical way to gate image lists: it returns images that live in *at least one* set the user can see — the system default, any public set, or any set they own. `ImageSet#playable_by?(user)` is the corresponding gate for set-level access; the matching `ImageSet.visible_to(user)` scope is used wherever a controller needs to list visible sets.

**Filtered sets.** A regular `ImageSet` *owns* its image_set_items directly. A *filtered set* is a child `ImageSet` (set via `parent_image_set_id`) whose items are computed from the parent's images intersected with `region_ids` (rows from the `Region` tree) and/or `custom_areas` (user-drawn circles stored as JSONB). `ImageSet#filtered?` is the predicate; `#effective_items` returns either the directly-owned items (regular sets) or the materialized items (filtered sets). `#materialize_filtered_items!` runs the point-in-polygon match and persists the result; `RematerializeFilteredSetsJob` is enqueued asynchronously whenever the parent changes (add_image, remove_item, locations update) so children stay in sync.

**Tags and catalog filters.** Image sets can be tagged from the create/edit form with a comma-separated `tag_list`. Tags are normalized into reusable `Tag` rows and displayed as pills on set cards. `/image_sets` filters both **My Sets** and **Public Sets** by one or more tags, supports **All tags** vs **Any tag** matching, and defaults to case-insensitive slug matching with an `Aa` toggle for exact-case matching. Active filter chips can remove individual tags, "Clear all" resets the tag filter, and clicking a tag pill appends that tag to the current filters.

The same catalog page can sort by name (A-Z / Z-A), creation date (newest / oldest), last update (recently updated / least recently updated), or image count (most / fewest images). Sort choices preserve the active tag filters and match/case mode in the URL.

## Routes (high-level)


| Route                                                                                     | Purpose                                                                                                                                    |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `/`                                                                                       | Landing page; primary CTA = "Start new game" on the system-default set                                                                     |
| `/donation`, `/donation/success`, `/donation/cancel`                                      | Stripe Checkout support flow launched by the footer "Support us" button                                                                    |
| `/registration/new`, `/session/new`, `/passwords/new`                                     | Sign up, sign in, password reset                                                                                                           |
| `/auth/google_oauth2`, `/auth/google_oauth2/callback`                                     | OAuth sign-in entry + callback                                                                                                             |
| `/profile/setup_username`                                                                 | Where OAuth-created users pick a username before they can do anything else                                                                 |
| `/profile`                                                                                | Current user's profile (also exposes account deletion — `DELETE /profile`)                                                                 |
| `/games`                                                                                  | Paginated list of your games (filter by status, sort by date or score)                                                                     |
| `/games/:id`                                                                              | Play the next round of an in-progress game                                                                                                 |
| `/games/:id/results`                                                                      | Per-round breakdown + summary map after game finishes                                                                                      |
| `/games/leaderboard?image_set_id=N`                                                       | Top-20 leaderboard scoped to an image set                                                                                                  |
| `/image_sets`                                                                             | Your sets + the public catalog, with tag filtering and sort controls                                                                       |
| `/image_sets/:id`                                                                         | Read-only gallery view of a set                                                                                                            |
| `/image_sets/:id/locations`                                                               | Owner-only: upload, edit titles/coords, remove items (rejected for filtered sets — edit the filter instead)                                |
| `/image_sets/:id/map`                                                                     | Map of all located images in a set                                                                                                         |
| `/image_sets/:id/new_filtered`, `/edit_filter`, `/update_filter`, `/preview_filter_count` | Build/edit a filtered set: pick regions, draw circle areas, live-preview match count                                                       |
| `/image_sets/ai_new`, `/ai_generate`, `/ai_create`                                        | Build a set from a natural-language prompt via Gemini + Wikidata; browser polls `/ai_generations/:id/status` while the background job runs |
| `/regions/search.json?q=...`                                                              | Typeahead region search (trigram + diacritic-folded; ranks by population, similarity, optional map-center distance)                        |
| `/regions/boundaries.json?ids[]=...`                                                      | Batch GeoJSON for selected regions; lazy-fetches missing polygons from Nominatim                                                           |
| `/regions/resolve.json`                                                                   | POST a Nominatim candidate (from the JS-side reverse geocode) → find-or-create the region row + ancestors                                  |
| `/images`, `/images/map`                                                                  | Paginated images list / world map (admins see all; everyone else sees `Image.visible_to`)                                                  |
| `/images/:id`                                                                             | Image detail: photo (scroll-zoom), edit form (anyone owning a set with the image), set memberships, "Open in Google Maps"                  |
| `/practice`                                                                               | Single-image guessing without saving a game (no auth required)                                                                             |


## Scoring

Per-round score follows the classic GeoGuessr formula:

`round_score = round(5000 * exp(-distance_km / 1492.7))`, clamped to `[0, 5000]`.

A game has 5 rounds, so the maximum total score is 25,000. Distances in the UI use `format_distance_compact` (helper at `app/helpers/games_helper.rb`): sub-kilometre guesses render as "847 m", 1-10 km as "1.5 km", farther as "47 km". The same formatting runs client-side in `app/javascript/controllers/game_controller.js`.

## Seed data

`db/seeds.rb` fetches ~1400 landmarks from Wikidata's SPARQL endpoint across 14 landform types (mountains, lakes, waterfalls, volcanoes, canyons, islands, glaciers, valleys, rivers, fjords, cliffs, beaches, capes, lagoons). Each re-seed pulls a fresh random sample. Idempotent — re-running won't duplicate.

In development only, three demo users (alice / bob / charlie) are also seeded with 1-2 completed games each so the leaderboard demos out of the box.


| Command                     | Effect                                                                  |
| --------------------------- | ----------------------------------------------------------------------- |
| `bin/rails db:seed`         | Adds new records, skips existing                                        |
| `bin/rails db:reset`        | Destroys DB -> recreates -> migrates -> seeds (wipes Games/Guesses too) |
| `bin/rails db:seed:replant` | Truncates tables, then seeds (keeps schema)                             |


## Deploying to Heroku

The live deployment uses Heroku's Basic dyno + Heroku Postgres + a separate AWS S3 bucket for image storage. To replicate:

```bash
heroku create your-app-name
heroku addons:create heroku-postgresql:essential-0
heroku buildpacks:add --index 1 heroku-community/apt   # pulls libvips42 via Aptfile
heroku buildpacks:add heroku/ruby
heroku config:set AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... S3_BUCKET=... AWS_REGION=...
heroku config:set GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=...   # required for Sign in with Google in prod
heroku config:set GEMINI_API_KEY=... AI_HINTS_ENABLED=1             # optional: AI image-set generation (key alone) + AI practice hints (key + flag)
heroku config:set MAPILLARY_TOKEN='MLY|...'                          # optional: enables street-imagery AI sets (Mapillary access token, not client secret)
heroku config:set STRIPE_SECRET_KEY=sk_test_...                    # optional: enables the Support us checkout flow in Stripe test mode
heroku config:set MALLOC_ARENA_MAX=2 ACTIVE_JOB_ASYNC_MAX_THREADS=1   # caps glibc heap fragmentation + concurrent libvips decodes; needed on 512MB dynos
git push heroku main:main
# `Procfile` runs `release: bundle exec rails db:migrate` automatically on every deploy — no manual migrate step.
heroku run rails db:seed                  # one-time: ~1400 Wikidata images
heroku run rake regions:seed_all          # one-time, ~10 min: GeoNames regions tree (needed for filtered-set creation)
heroku run rails console                  # then: User.find_by(email_address: "...").update!(admin: true)
```

`config.force_ssl` + `assume_ssl` are on in production. Heroku terminates TLS at the router and forwards HTTP to the dyno; `assume_ssl` makes Rails see the original scheme so cookies are marked `Secure` and HSTS is sent.

### Background-processing caveats (`:async` queue)

Image conversion (HEIC -> JPEG, resize, ICC) runs in `ProcessImageJob` via Active Job's in-memory `:async` adapter. **Jobs queued in memory are dropped on dyno restart** (deploys, daily cycles, OOMs). To recover:

- `bin/rails images:reprocess_pending` — re-enqueue any Image whose attached blob isn't yet processed (idempotent — finished images skip themselves).
- `bin/rails images:purge_unattached[hours]` — delete S3 blobs that were direct-uploaded but never attached (e.g. user closed the tab mid-upload). Default is 24h.

`RematerializeFilteredSetsJob` is queued on the same `:async` adapter when a parent set's images change, so a deploy mid-edit can leave child filtered sets stale until the next parent mutation. Acceptable for now (the materialization runs anyway the next time someone clicks Save on the filter); revisit if it becomes noticeable.

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

All maps load the **MapTiler SDK** (which wraps MapLibre GL) and render an `ImageSet#map_style`-configurable basemap (default `outdoor-v2`). The three Stimulus controllers — `image_map`, `guess_map`, `results_map` — share `app/javascript/lib/maptiler.js` for the API key, the lazy SDK loader (`ensureMaptilerSdk()`), the `hideOutdoorTrails(map)` `style.load` hook, and an `escapeText()` helper for popup HTML. The trail-hiding hook is scoped to `source: "outdoor", source-layer: "trail"` so non-outdoor styles (streets-v2's footpaths, etc.) keep their pedestrian detail. Mountain peaks, contours, terrain shading, and POI labels all stay on outdoor.

Adding a new map page = pick one of the controllers, pass `style:` if the page has a per-set basemap, and **don't** add a `<script>` tag for the SDK (the loader handles it). Don't use `data-turbo="false"` to "fix" map issues either — Turbo Drive keeps `window.maptilersdk` warm across navs, which is what makes the per-visitor billing work. If a same-URL Turbo navigation flashes the previous round's photo, add `<meta name="turbo-cache-control" content="no-preview">` (see `games/show.html.erb`).

Popup HTML in map controllers uses `setHTML()`, which executes embedded markup — escape any user-controlled string going in there with `escapeText()`. `Image#title` in particular is editable by anyone owning a set the image is in (see `Image#editable_by?`), so it must always go through `escapeText()` before reaching `setHTML`.

### Pagination

Long lists (`/images`, `/image_sets/:id`, `/image_sets/:id/locations`, `/games`) page through `ApplicationController#paginate(scope, per_page:)`. It clamps `?page=` to `[1, total_pages]`, honors `?per_page=` against the `PER_PAGE_OPTIONS` allowlist (default `[25, 50, 100, 250, 500]`, fallback to the caller's `per_page:`), sets `@page / @total_pages / @total_items / @per_page`, and returns the windowed scope. Render the controls with `<%= render "shared/pagination", page_url: ->(opts) { route_path(opts) }, page: @page, total_pages: @total_pages, total_items: @total_items, per_page: @per_page %>`. `page_url` is a lambda receiving `{ page:, per_page: }` so the partial works for any route and any persistent filters (sort, status, etc., merged into the lambda).

### Component classes (Tailwind)

Reusable styles live in `app/assets/tailwind/application.css` as `@apply` component classes. Reach for these before stringing utilities together — keeps things consistent and means a re-theme is one edit, not a grep-and-replace.

- Buttons: `btn-primary` / `btn-secondary` / `btn-danger` / `btn-ghost` (subtle inline links)
- Forms: `form-input` (and `form-input-error` for validation states), `select-with-arrow` (custom chevron — pair with `pr-8`)
- Layout: `page-container` (max-width wrapper for top-level pages)
- Typography: `heading-hero` / `heading-page` / `heading-section`, `eyebrow` (small all-caps label), `muted` (gray caption text)

### Wikidata seeder

`db/seeds.rb` uses `**SERVICE bd:sample`** for random sampling — not `ORDER BY RAND()` or hashed orderings, both of which time out at scale when unioning multiple landform types. `bd:sample` accepts only a single triple pattern, so the seeder samples by `wdt:P31` (instance-of) inside the `SERVICE` block and joins `wdt:P18`/`wdt:P625` outside. Over-sampling (`limit 2000`) is intentional — only ~5–20% of any landform type has both an image and coordinates. Filenames are filtered for non-photo contamination (satellite imagery, maps); when adding new landform types, spot-check for new junk patterns.

## Contributing

- Branch from `main`: `git checkout -b branch-name`
- Keep migrations reversible
- After seed changes, run `bin/rails db:reset` locally to verify a clean setup works
- Open a PR against `main`

See `[CHANGELOG.md](./CHANGELOG.md)` for release notes.

## Entity Relationship Diagram

[ERD on Miro](https://miro.com/app/board/uXjVGjb-zPA=/?share_link_id=966004402068)

## Similar products

- [GeoGuessr](https://www.geoguessr.com/)
- [OpenGuessr](https://openguessr.com/)
- [GeoHub](https://www.geohub.gg/)
- [Guess Where You Are](https://guesswhereyouare.com/)
- [Geotastic](https://geotastic.net)

