# Changelog

All notable changes to this project will be documented in this file.

## [milestone-1](https://github.com/NU-CS-Software-Studio-Spring-26/project-landscape_guessr/releases/tag/milestone-1) — 2026-05-05

First public release. Replaces the milestone-0 anonymous prototype with a multi-user MVP.

- **User accounts**: sign up, sign in, password reset, profile, admin role. Login endpoints are rate-limited and don't leak which emails exist.
- **Image sets**: per-user collections of images with private / public / system-default visibility. Each set has a gallery, a manage page (upload + edit + remove), and a map view.
- **Bulk image upload**: pick hundreds of files at once. Browser uploads originals straight to S3, then a background job converts them (HEIC → JPEG, resize, color correction). Tab-close safe.
- **GeoGuessr scoring**: each round scores `round(5000 × exp(-km/1492.7))`, max 25,000 across 5 rounds. Replaces the milestone-0 binary win/lose outcome.
- **Per-set leaderboard**: top 20 games per image set, sortable by score or completion date.
- **Results page**: per-round breakdown with thumbnails + summary map showing every guess and answer.
- **Maps**: all on MapLibre + MapTiler `outdoor-v2` vector tiles — smooth zoom, terrain shading, mountain peaks with elevations, contour lines.
- **Polish**: friendly 404s (no stack traces in dev or prod), empty / error states on every page, consistent flash + navigation styling.

CI runs Brakeman + bundler-audit + RuboCop + the full test suite (95 tests) on every push.

## [milestone-0](https://github.com/NU-CS-Software-Studio-Spring-26/project-landscape_guessr/releases/tag/milestone-0)

Initial MVP: anonymous play (no accounts), single global pool of Wikidata-seeded images, binary win/lose outcome, no leaderboard, no uploads.
