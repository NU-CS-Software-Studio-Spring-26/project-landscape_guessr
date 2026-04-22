# landscape_guessr

A GeoGuessr-style web game: players see a landscape photograph (mountain, lake, waterfall, etc.) and guess where it is on a world map. Rails 8 + PostgreSQL + TailwindCSS.

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

Open [http://localhost:3000/images](http://localhost:3000/images) for the list, or [http://localhost:3000/images/map](http://localhost:3000/images/map) for the world map.

`bin/dev` uses foreman — if you hit `foreman: not found`, run `gem install foreman`.

## Data model

```
Image          Game            Guess
-----          ----            -----
url            status          game_id     → Game
latitude       score           image_id    → Image
longitude      completed_at    latitude    (user's guess)
title                          longitude
```

Each guess belongs to one game and one image. A game has many guesses (and, through those, many images). The image holds the "correct answer" lat/lng; the guess holds the player's lat/lng.

## Seed data

`db/seeds.rb` fetches ~1400 landmarks from Wikidata's SPARQL endpoint across 14 landform types (mountains, lakes, waterfalls, volcanoes, canyons, islands, glaciers, valleys, rivers, fjords, cliffs, beaches, capes, lagoons). Each re-seed pulls a fresh random sample. Idempotent — re-running won't duplicate.

**Limitation:** Wikidata's coordinates mark the *subject's* location, not the photographer's. For a mountain photo, this is the mountain's peak — fine for a "where is this thing?" guessing game, but not the exact photo viewpoint.


| Command                     | Effect                                                               |
| --------------------------- | -------------------------------------------------------------------- |
| `bin/rails db:seed`         | Adds new records, skips existing                                     |
| `bin/rails db:reset`        | Destroys DB → recreates → migrates → seeds (wipes Games/Guesses too) |
| `bin/rails db:seed:replant` | Truncates tables, then seeds (keeps schema)                          |


## Routes


| URL                  | Purpose                                     |
| -------------------- | ------------------------------------------- |
| `/images`            | Scaffold list view with thumbnails          |
| `/images/map`        | World map, one dot per image, click to open |
| `/images/:id`        | Individual image details                    |
| `/games`, `/guesses` | Scaffold CRUD (to be replaced by real game) |


## Contributing

- Branch from `main`: `git checkout -b branch-name`
- Keep migrations reversible
- After seed changes, run `bin/rails db:reset` locally to verify a clean setup works
- Open a PR against `main`

## Entity Relationship Diagram

[https://miro.com/app/board/uXjVGjb-zPA=/?share_link_id=966004402068](https://miro.com/app/board/uXjVGjb-zPA=/?share_link_id=966004402068)

## Future features

- Multiplayer
- Player accounts
- Leaderboard
- Adding your own image sets

## Similar products

- [GeoGuessr](https://www.geoguessr.com/)
- [OpenGuessr](https://openguessr.com/)
- [GeoHub](https://www.geohub.gg/)
- [Guess Where You Are](https://guesswhereyouare.com/)
- [Geotastic](https://geotastic.net)

