import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails, escapeText } from "lib/maptiler"

const COLORS = [
  "#3b82f6", "#ef4444", "#22c55e", "#f59e0b", "#a855f7",
  "#14b8a6", "#f97316", "#ec4899", "#6366f1", "#84cc16"
]

export default class extends Controller {
  static targets = ["container"]
  static values  = {
    rounds:  { type: Array,  default: [] },
    style:   { type: String, default: "outdoor-v2" },
    players: { type: Array,  default: [] }
  }

  async connect() {
    await ensureMaptilerSdk()

    this.map = new maptilersdk.Map({
      container: this.containerTarget,
      style: `https://api.maptiler.com/maps/${this.styleValue}/style.json?key=${MAPTILER_KEY}`,
      center: [0, 20],
      zoom: 1.5
    })

    this.map.on("load", () => {
      hideOutdoorTrails(this.map)
      this.#renderRounds()
    })
  }

  #renderRounds() {
    const rounds = this.roundsValue
    if (!rounds.length) return

    const bounds = new maptilersdk.LngLatBounds()

    rounds.forEach((r, i) => {
      const color = COLORS[i % COLORS.length]
      const label = `Round ${r.round}`

      // Guess marker (hollow circle style via red)
      new maptilersdk.Marker({ color: "#ef4444" })
        .setLngLat([r.guess_lng, r.guess_lat])
        .setPopup(new maptilersdk.Popup({ offset: 8 }).setHTML(
          `<div class="text-xs font-medium">${label} — your guess</div>` +
          `<div class="text-xs text-gray-500">${r.guess_lat.toFixed(4)}, ${r.guess_lng.toFixed(4)}</div>` +
          `<div class="text-xs text-gray-500">${r.distance_label} off</div>`
        ))
        .addTo(this.map)

      // Answer marker (green). Escape r.title — it comes from
      // Image#title, which is editable by anyone owning a set the
      // image is in. Without escaping, a crafted title containing
      // `<img src=x onerror=...>` would execute on every viewer's
      // results page.
      const safeTitle = escapeText(r.title)
      new maptilersdk.Marker({ color: "#22c55e" })
        .setLngLat([r.answer_lng, r.answer_lat])
        .setPopup(new maptilersdk.Popup({ offset: 8 }).setHTML(
          `<div class="text-xs font-medium">${label} — ${safeTitle}</div>` +
          `<div class="text-xs text-gray-500">${r.answer_lat.toFixed(4)}, ${r.answer_lng.toFixed(4)}</div>`
        ))
        .addTo(this.map)

      // Line between guess and answer
      const lineId = `line-${i}`
      this.map.addSource(lineId, {
        type: "geojson",
        data: {
          type: "Feature",
          geometry: {
            type: "LineString",
            coordinates: [
              [r.guess_lng, r.guess_lat],
              [r.answer_lng, r.answer_lat]
            ]
          }
        }
      })
      this.map.addLayer({
        id: lineId,
        type: "line",
        source: lineId,
        paint: {
          "line-color": color,
          "line-width": 2,
          "line-dasharray": [4, 3]
        }
      })

      bounds.extend([r.guess_lng, r.guess_lat])
      bounds.extend([r.answer_lng, r.answer_lat])
    })

    this.#renderOtherPlayers(bounds)
    this.map.fitBounds(bounds, { padding: 60, maxZoom: 8 })
  }

  #renderOtherPlayers(bounds) {
    const players = this.playersValue
    if (!players.length) return

    const playerColors = ["#3b82f6", "#f59e0b", "#a855f7", "#14b8a6", "#f97316", "#ec4899"]

    players.forEach((player, pi) => {
      const color = playerColors[pi % playerColors.length]

      player.rounds.forEach((pr) => {
        const myRound = this.roundsValue.find(r => r.round === pr.round)
        if (!myRound) return

        new maptilersdk.Marker({ color, scale: 0.8 })
          .setLngLat([pr.guess_lng, pr.guess_lat])
          .setPopup(new maptilersdk.Popup({ offset: 8 }).setHTML(
            `<div class="text-xs font-medium">${escapeText(player.username)} — Round ${pr.round}</div>`
          ))
          .addTo(this.map)

        const lineId = `player-${pi}-r${pr.round}`
        this.map.addSource(lineId, {
          type: "geojson",
          data: {
            type: "Feature",
            geometry: {
              type: "LineString",
              coordinates: [[pr.guess_lng, pr.guess_lat], [myRound.answer_lng, myRound.answer_lat]]
            }
          }
        })
        this.map.addLayer({
          id: lineId, type: "line", source: lineId,
          paint: { "line-color": color, "line-width": 2, "line-dasharray": [3, 4] }
        })

        bounds.extend([pr.guess_lng, pr.guess_lat])
      })
    })
  }

  // Smooth-pan to a single round's guess+answer pair. Wired up from
  // the per-round thumbnails on /games/:id/results — clicking a round
  // thumbnail dives the map onto that round so the player can see how
  // far off they were. Also scrolls the map element into view since
  // it's typically scrolled past on a results page.
  focus(event) {
    // Bail when the click landed on a real link/button inside the row —
    // we don't want clicking "Details ↗" to also pan the map. Earlier
    // versions used a stopPropagation() handler on the link instead, but
    // that swallowed the click before Turbo Drive's document-level
    // interceptor saw it, forcing a full page reload (and a fresh
    // MapTiler session) on every Details click.
    if (event.target.closest("a, button")) return

    const round = parseInt(event.params?.round, 10)
    const r = this.roundsValue.find((x) => x.round === round)
    if (!r || !this.map) return

    const bounds = new maptilersdk.LngLatBounds()
    bounds.extend([r.guess_lng, r.guess_lat])
    bounds.extend([r.answer_lng, r.answer_lat])
    this.map.fitBounds(bounds, { padding: 80, maxZoom: 14, duration: 700 })

    this.containerTarget.scrollIntoView({ behavior: "smooth", block: "center" })
  }

  disconnect() {
    this.map?.remove()
  }
}
