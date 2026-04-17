# landscape_guessr

A GeoGuessr-style web game: players are shown a landscape/nature photograph (mountain, lake, waterfall, island, etc.) and guess where it is on a world map. Built with Rails 8 + PostgreSQL + TailwindCSS.

## Tech stack

- **Ruby** 4.0.2 (pinned via `.ruby-version`)
- **Rails** 8.1.3
- **PostgreSQL** (for both development and production — Heroku-compatible)
- **TailwindCSS** (via `tailwindcss-rails`)
- **Leaflet.js** for the world map view (loaded via CDN; OpenStreetMap tiles)

## Prerequisites

- [rbenv](https://github.com/rbenv/rbenv) (or another Ruby version manager)
- Ruby 4.0.2 — install with `rbenv install 4.0.2`
- PostgreSQL 14+ running locally (`brew install postgresql@16 && brew services start postgresql@16` on macOS)
- Node is **not** required — the asset pipeline uses Propshaft + importmaps

## Setup

```bash
git clone <this-repo>
cd project-landscape_guessr
bundle install
bin/rails db:create db:migrate db:seed   # creates DB, runs migrations, fetches ~1400 images from Wikidata
bin/dev                                  # starts Puma (port 3000) + Tailwind watcher
```

Then open http://localhost:3000/images for the list, or http://localhost:3000/images/map for the world map.

`bin/dev` uses foreman to run both processes together — if you hit `foreman: not found`, install it with `gem install foreman`.

## Data model

Three ActiveRecord models, one join table:

```
Image        Game          Guess
-----        ----          -----
url          status        game_id     → Game
latitude     score         image_id    → Image
longitude    completed_at  latitude    (user's guess)
title                      longitude
```

Associations (see `app/models/*.rb`):

```ruby
class Image < ApplicationRecord
  has_many :guesses, dependent: :destroy
end

class Game < ApplicationRecord
  has_many :guesses, dependent: :destroy
  has_many :images, through: :guesses
end

class Guess < ApplicationRecord
  belongs_to :game
  belongs_to :image
end
```

A `Game` has many `Guesses`. Each `Guess` references one `Image` (the prompt) and stores the player's lat/lng. Through the join, a `Game` `has_many :images` (the ones it has shown).

## Seed data

`db/seeds.rb` fetches landmarks from Wikidata's public SPARQL endpoint. Highlights:

- Queries 14 landform types: mountains, lakes, waterfalls, volcanoes, canyons, islands, glaciers, valleys, rivers, fjords, cliffs, beaches, capes, lagoons
- Uses BlazeGraph's native `bd:sample` service for **true random sampling** (~4s for ~1400 records)
- Filters out non-JPG files, known satellite-imagery filename patterns (ASTER, MODIS, Landsat, Sentinel), and map/diagram patterns
- Idempotent via `find_or_create_by!(url:)` — re-running won't duplicate rows
- Each re-seed pulls a fresh random sample

**Limitation:** Wikidata's `P625` (coordinates) is the _subject's_ location, not the photographer's. For a mountain photo, this is the mountain's peak — fine for a guessing game where the goal is "where is this thing?" but it's not the exact photo viewpoint. See git history for the full investigation into camera-location sources (Commons GeoData, SDC P1259, EXIF — all too sparse or noisy to be worth the complexity).

Re-seed with fresh random data:

```bash
bin/rails db:seed              # idempotent — adds new, skips existing
bin/rails db:reset             # destroys DB, recreates, runs migrations + seeds (wipes Games/Guesses too)
bin/rails db:seed:replant      # truncates tables then seeds (keeps schema)
```

## Routes

| URL                  | Purpose                                     |
| -------------------- | ------------------------------------------- |
| `/images`            | Scaffold list view with thumbnails          |
| `/images/map`        | World map, one dot per image, click to open |
| `/images/:id`        | Individual image details                    |
| `/games`, `/guesses` | Scaffold CRUD (to be replaced by real game) |

## Development notes

- `.ruby-version` pins to `4.0.2`. rbenv reads it automatically; just `cd` into the repo.
- Tailwind classes are compiled by `tailwindcss-rails`; `bin/dev` runs the watcher. If styles look stale, restart `bin/dev`.
- The `/images/map` page loads Leaflet from CDN and embeds the image data as inline JSON to avoid an extra round-trip. The "Map view" link uses `data: { turbo: false }` to force a full page reload (inline scripts don't re-execute cleanly through Turbo navigation).

## Contributing

- Branch from `main`: `git checkout -b feat/your-thing`
- Keep migrations reversible (`change` method, or explicit `up`/`down`)
- Seed data changes: run `bin/rails db:reset` locally to verify a clean setup works end-to-end
- Open a PR against `main`

## License

TBD.
