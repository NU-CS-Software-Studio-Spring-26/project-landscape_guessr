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

## Data model

```
Image          Game            Guess
-----          ----            -----
url            status          game_id     -> Game
latitude       score           image_id    -> Image
longitude      completed_at    latitude    (user's guess)
title                          longitude
```

Each guess belongs to one game and one image. A game has many guesses (and, through those, many images). The image holds the "correct answer" lat/lng; the guess holds the player's lat/lng.

## Seed data

`db/seeds.rb` fetches ~1400 landmarks from Wikidata's SPARQL endpoint across 14 landform types (mountains, lakes, waterfalls, volcanoes, canyons, islands, glaciers, valleys, rivers, fjords, cliffs, beaches, capes, lagoons). Each re-seed pulls a fresh random sample. Idempotent — re-running won't duplicate.

| Command                    | Effect                                                              |
| -------------------------- | ------------------------------------------------------------------- |
| `bin/rails db:seed`        | Adds new records, skips existing                                    |
| `bin/rails db:reset`       | Destroys DB -> recreates -> migrates -> seeds (wipes Games/Guesses too) |
| `bin/rails db:seed:replant`| Truncates tables, then seeds (keeps schema)                         |

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

