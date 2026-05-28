# Multiplayer Sketch — Action Cable

A starting blueprint for real-time multiplayer on top of the existing Rails app.
Not a final design; meant to be argued with before any code lands.

## Why Action Cable (not raw WebSockets / a separate service)

- Already shipped with Rails — no new runtime, deploy target, or auth boundary.
- Channels integrate with `current_user` via `ApplicationCable::Connection`.
- Pairs cleanly with existing Stimulus controllers (`@rails/actioncable` client).
- Trade-off: needs a Redis adapter in production for multi-process broadcasting.
  Single-process dev uses the async adapter; no Redis needed locally.

If we ever outgrow it (>thousands of concurrent rooms, sub-50ms tick rate), the
escape hatch is a small Go/Elixir socket server reading from the same Postgres.
Not worth designing for now.

---

## Data model

Three new tables, all DB-authoritative. Action Cable only carries notifications.

```
matches
  id, host_user_id, image_set_id, status (lobby|active|finished),
  rounds_total, seconds_per_round, code (short joinable token),
  started_at, finished_at, created_at

match_players
  id, match_id, user_id, joined_at, left_at, forfeited_at,
  total_score
  unique (match_id, user_id)

match_rounds
  id, match_id, index, image_id,
  started_at, deadline_at, ended_at

match_guesses
  id, match_round_id, match_player_id, lat, lng, distance_m,
  score, submitted_at
  unique (match_round_id, match_player_id)
```

Single-player `Game`/`Guess` stay untouched — multiplayer is a parallel concept
so we don't tangle scoring/leaderboard logic with real-time state.

---

## Channels

### `ApplicationCable::Connection`

Identify by `current_user` (reuse session cookie). Reject unauthenticated.

### `MatchChannel`

```
class MatchChannel < ApplicationCable::Channel
  def subscribed
    @match = Match.find_by(code: params[:code])
    return reject unless @match && @match.joinable_by?(current_user)
    stream_for @match
    MatchPresence.join(@match, current_user)   # broadcasts player_joined
  end

  def unsubscribed
    MatchPresence.leave(@match, current_user)  # broadcasts player_left
  end

  # Client → server actions
  def submit_guess(data)
    SubmitGuess.call(match: @match, user: current_user,
                     lat: data["lat"], lng: data["lng"])
  end

  def ready
    LobbyReady.call(match: @match, user: current_user)
  end
end
```

Action methods are thin — they delegate to service objects that validate,
persist, and broadcast. Keep the channel as a transport layer only.

---

## Server → client events

All broadcast via `MatchChannel.broadcast_to(match, payload)`.
Payloads are explicit so clients can be dumb.

| Event             | When                                  | Payload (shape)                                     |
| ----------------- | ------------------------------------- | --------------------------------------------------- |
| `player_joined`   | new subscription                      | `{ user: {id, username, avatar_url} }`              |
| `player_left`     | disconnect or explicit leave          | `{ user_id }`                                       |
| `match_started`   | host starts, status → active          | `{ rounds_total, seconds_per_round }`               |
| `round_started`   | each round begins                     | `{ index, image_url, deadline_at }`                 |
| `player_guessed`  | someone locks in (no coords leaked)   | `{ user_id }`                                       |
| `round_ended`     | timer hits zero OR everyone guessed   | `{ answer: {lat,lng}, guesses: [{user_id,lat,lng,distance_m,score}], scores: [{user_id,total}] }` |
| `match_finished`  | last round ends                       | `{ final_scores: [...] }`                           |

Critical: `player_guessed` carries **only** the user id, never coordinates.
Coords are revealed atomically in `round_ended`.

---

## Round timing — server-side

Don't trust client clocks. When a round starts:

```
round = match.match_rounds.create!(
  index: i, image: next_image,
  started_at: Time.current,
  deadline_at: Time.current + match.seconds_per_round.seconds,
)
EndRoundJob.set(wait: match.seconds_per_round.seconds).perform_later(round.id)
MatchChannel.broadcast_to(match, type: "round_started", ...)
```

`EndRoundJob` is idempotent: if every player already guessed, the "all submitted"
path calls the same `EndRound.call(round)` service that no-ops on a finished
round. Whichever fires first wins; the other becomes a cheap DB lookup.

---

## Reconnect / snapshot

WebSocket delivers **deltas only**. On page load (or refresh mid-match), the
client first fetches a snapshot via plain HTTP:

```
GET /matches/:code  →  { match, players, current_round, scores, server_now }
```

Then subscribes to the channel. `server_now` lets the client compute the
round deadline as `deadline_at - (server_now - client_now)` to dodge clock skew.

---

## Stimulus controller — client skeleton

```js
// app/javascript/controllers/multiplayer_controller.js
import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static values = { code: String }
  static targets = ["players", "image", "timer", "results"]

  connect() {
    this.subscription = consumer.subscriptions.create(
      { channel: "MatchChannel", code: this.codeValue },
      {
        received: (msg) => this.dispatch(msg.type, { detail: msg }),
      }
    )
  }

  disconnect() { this.subscription?.unsubscribe() }

  // dispatched events → handlers
  onRoundStarted(e) { /* swap image, start countdown */ }
  onPlayerGuessed(e) { /* mark avatar as "locked in" */ }
  onRoundEnded(e) { /* reveal pins on map, show scores */ }
  onMatchFinished(e) { /* navigate to results page */ }

  submitGuess(e) {
    this.subscription.perform("submit_guess",
      { lat: e.detail.lat, lng: e.detail.lng })
  }
}
```

The existing `guess_map_controller.js` stays single-player-aware. Multiplayer
mode is a sibling controller on the same page that listens for the map's
`guess:submitted` event and forwards it over the socket.

---

## Open decisions (worth pinning down before coding)

1. **Lockstep vs. async reveal.** End the round the moment the last player
   guesses, or always wait for the timer? Lockstep feels snappier; timer-only
   tolerates abandons gracefully. Probably: **end early if all *connected*
   players have guessed, otherwise wait for timer.**

2. **Disconnect policy.** If a player tabs out, do their unsubmitted rounds
   score 0, or do they get a grace period? Suggest: 15s reconnect window before
   marking `forfeited_at`.

3. **Spectators.** Can non-players watch? If yes, they subscribe to a
   read-only stream that filters out `player_guessed` until `round_ended`.

4. **Bots / fill.** Out of scope for v1 — keep human-only.

5. **Anti-cheat (low priority).** Server already enforces deadline + computes
   distance. Only remaining vector is screen-sharing between players, which is
   a social problem, not a technical one.

---

## Suggested build order

1. **Schema + models** (`Match`, `MatchPlayer`, `MatchRound`, `MatchGuess`)
   with associations + validations, no realtime yet.
2. **Lobby flow over plain HTTP**: create match, share code, join, list players.
   Verify model logic before introducing async surprises.
3. **MatchChannel + presence broadcasts** (`player_joined` / `player_left`).
   Simplest possible payloads, just to wire the transport.
4. **Round lifecycle**: `match_started` → `round_started` → `round_ended` with
   server-side timer job. Coords reveal only on round end.
5. **Stimulus controller** with snapshot fetch + subscription. Hook into the
   existing map controller.
6. **Scoring + final leaderboard.** Reuse single-player scoring math.
7. **Reconnect polish + forfeit timer.** Last because it's tuning, not core.

Each step ships behind a feature flag (or just a route gate) until step 7.

---

## Alternative: Tier 3 — Polling, no WebSockets

If Action Cable / Redis is more infrastructure than the project wants, the same
data model and controller actions work with plain HTTP polling. Ship this first;
upgrade to channels later without touching the schema.

### What stays the same

- All four tables (`matches`, `match_players`, `match_rounds`, `match_guesses`).
- Service objects (`SubmitGuess`, `EndRound`, etc.) and their validation logic.
- Server-side round timing (still need `EndRoundJob` so the round closes even
  when no one is polling).

### What changes

- **No `MatchChannel`, no broadcasts, no Redis.**
- **One JSON endpoint** that returns the full client-visible state:

  ```
  GET /matches/:code/state.json
    → {
        server_now: "...",
        match: { status, round_index, rounds_total },
        current_round: { index, image_url, deadline_at, my_guess_submitted },
        players: [{ id, username, avatar_url, locked_in, total_score }],
        last_round_result: null | { answer:{lat,lng}, guesses:[...], scores:[...] }
      }
  ```

  Same payload shape as the "snapshot + deltas" approach, just delivered every
  tick instead of once on load. **Never leak unguessed coords** — the controller
  filters `last_round_result` to `null` until the round has actually ended.

- **Submits stay POST:** `POST /matches/:code/guesses` with `{lat,lng}`.

### Client — two options, both tiny

**(a) Turbo Frame auto-refresh** — zero JS:

```erb
<%= turbo_frame_tag "match_state", src: match_state_path(@match),
                                   refresh: "2s" %>
```

The frame re-fetches every 2 seconds and swaps its contents. Good when the
"changing" region of the page is a contained block (player list, scoreboard).
Awkward when you also need to drive a Leaflet map — Turbo replaces the DOM and
you lose the map instance.

**(b) Stimulus controller with `setInterval`** — ~20 lines:

```js
// app/javascript/controllers/match_poll_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String, intervalMs: { type: Number, default: 2000 } }

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), this.intervalMsValue)
  }

  disconnect() { clearInterval(this.timer) }

  async tick() {
    const res = await fetch(this.urlValue, { headers: { Accept: "application/json" }})
    if (!res.ok) return
    const state = await res.json()
    this.dispatch("update", { detail: state })  // map/scoreboard listen
  }
}
```

The map controller listens for `match-poll:update` and reconciles pins / round
state itself. Keeps Leaflet instance alive across polls.

### Tuning

- **Interval:** 2s feels real-time enough for a guessing game; 1s if you want
  snappier "X locked in" badges. Don't go below 1s — server load scales
  linearly.
- **Backoff:** pause polling when `document.hidden` (tab in background) to
  avoid wasted requests.
- **ETag the endpoint** so unchanged polls return `304 Not Modified` and skip
  rendering. One line in the controller; halves server CPU.
- **Conditional polling cadence:** poll every 2s during a round, every 5s in
  the lobby, stop entirely after `match_finished`.

### When to upgrade to Action Cable

Concrete signals, not vibes:

- Polling traffic > a noticeable fraction of total request volume in logs.
- Players complain about reveal lag (>2s feels sluggish on a fast round).
- You want server-pushed events the client can't predict the timing of
  (e.g. host kicks a player mid-round).

Upgrade is mechanical: keep the JSON endpoint as the snapshot route, add
`MatchChannel` for deltas, swap the Stimulus `setInterval` for a subscription.
Service objects and schema don't move.
