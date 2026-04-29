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
- **MapLibre GL** for interactive maps

## Prerequisites

- Ruby 4.0.2 — install via your version manager (rbenv, asdf, mise, rvm). `.ruby-version` is honored by all of them.
- PostgreSQL 14+ running locally. On macOS: `brew install postgresql@16 && brew services start postgresql@16`.

## Setup

```bash
git clone <this-repo>
cd project-landscape_guessr
bundle install
bin/rails db:create db:migrate db:seed   # creates DB, runs migrations, fetches ~1400 images from Wikidata
bin/dev                                  # starts Puma (port 3000) + Tailwind watcher
```

`bin/dev` uses foreman — if you hit `foreman: not found`, run `gem install foreman`.

To play, sign up at `/registration/new`. Practice mode (`/practice`) and image browsing are available without an account; starting/playing games requires sign-in.

To manage the image library or edit past guesses through the UI, you need an admin account. Sign up normally, then promote yourself via `bin/rails c`: `User.find_by(email_address: "you@x").update(admin: true)`. On Heroku: `heroku run rails console`.

## Data model

| Model | Belongs to | Has many | Key columns |
|---|---|---|---|
| `User` | — | `sessions`, `games` | `email_address`, `password_digest`, `admin` |
| `Session` | `User` | — | `ip_address`, `user_agent` |
| `Game` | `User` | `game_images`, `guesses`, `images` (through `game_images`) | `status`, `score`, `completed_at` |
| `GameImage` | `Game`, `Image` | — | `position` (1–5) |
| `Image` | — | `guesses`, `game_images` | `url`, `latitude`, `longitude`, `title` |
| `Guess` | `Game`, `Image` | — | `latitude`, `longitude` (player's pick) |

Each game materializes a fixed 5-image set on creation (`game_images` rows with positions 1–5), so the same game can later be replayed by a challenger against the identical image sequence. The `Image` row holds the correct answer; the `Guess` row holds the player's pick.

## Seed data

`db/seeds.rb` fetches ~1400 landmarks from Wikidata's SPARQL endpoint across 14 landform types (mountains, lakes, waterfalls, volcanoes, canyons, islands, glaciers, valleys, rivers, fjords, cliffs, beaches, capes, lagoons). Each re-seed pulls a fresh random sample. Idempotent — re-running won't duplicate.

| Command                    | Effect                                                              |
| -------------------------- | ------------------------------------------------------------------- |
| `bin/rails db:seed`        | Adds new records, skips existing                                    |
| `bin/rails db:reset`       | Destroys DB -> recreates -> migrates -> seeds (wipes Games/Guesses too) |
| `bin/rails db:seed:replant`| Truncates tables, then seeds (keeps schema)                         |

## Conventions

A few patterns that aren't obvious from the code but are easy to break.

### Auth scoping (security-critical)

Any controller action touching a user-owned record must scope through `Current.user`, never `Model.find` directly. So:

```ruby
# Right — wrong-owner request returns 404 because the scope filters it out
@game = Current.user.games.find(params[:id])

# Wrong — silently exposes other users' games
@game = Game.find(params[:id])
```

Same for nested writes: `Current.user.games.find(...).guesses.create!(...)`. Tests cover the cross-user 404 case in `test/controllers/games_controller_test.rb` and `guesses_controller_test.rb`.

Mutating the image library, editing past guesses, and editing game metadata are admin-only. Game `score`, `status`, and `completed_at` are written by the backend during gameplay (results action) — the `/games/:id/edit` form exists only as an admin debug tool. Users can still destroy their own games. Use the `require_admin` before_action in `ApplicationController` for any future controller action that should be restricted to admins.

### Turbo + inline `<script>` tags

Turbo Drive swaps the body in place on link clicks, which means inline scripts that initialize JS libraries (e.g., MapLibre on `/images/map`) don't re-run. Links pointing to such pages need `data: { turbo: false }` to force a full page load.

### Wikidata seeder

`db/seeds.rb` uses **`SERVICE bd:sample`** for random sampling — not `ORDER BY RAND()` or hashed orderings, both of which time out at scale when unioning multiple landform types. `bd:sample` accepts only a single triple pattern, so the seeder samples by `wdt:P31` (instance-of) inside the `SERVICE` block and joins `wdt:P18`/`wdt:P625` outside. Over-sampling (`limit 2000`) is intentional — only ~5–20% of any landform type has both an image and coordinates. Filenames are filtered for non-photo contamination (satellite imagery, maps); when adding new landform types, spot-check for new junk patterns.

## Contributing

- Branch from `main`: `git checkout -b branch-name`
- Keep migrations reversible
- After seed changes, run `bin/rails db:reset` locally to verify a clean setup works
- Open a PR against `main`

## Entity Relationship Diagram

[ERD on Miro](https://miro.com/app/board/uXjVGjb-zPA=/?share_link_id=966004402068)

## Similar products

- [GeoGuessr](https://www.geoguessr.com/)
- [OpenGuessr](https://openguessr.com/)
- [GeoHub](https://www.geohub.gg/)
- [Guess Where You Are](https://guesswhereyouare.com/)
- [Geotastic](https://geotastic.net)

