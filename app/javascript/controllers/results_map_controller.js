import { Controller } from "@hotwired/stimulus"

// See guess_map_controller.js for why we use MapTiler SDK over raw MapLibre.
const MAPTILER_SDK_CSS = "https://cdn.maptiler.com/maptiler-sdk-js/v4.0.2/maptiler-sdk.css"
const MAPTILER_SDK_JS  = "https://cdn.maptiler.com/maptiler-sdk-js/v4.0.2/maptiler-sdk.umd.min.js"
const MAPTILER_KEY     = "biJMFiy9HEvnGGS540u4"

const COLORS = [
  "#3b82f6", "#ef4444", "#22c55e", "#f59e0b", "#a855f7",
  "#14b8a6", "#f97316", "#ec4899", "#6366f1", "#84cc16"
]

function hideOutdoorTrails(map) {
  for (const layer of map.getStyle()?.layers || []) {
    if (layer.source === "outdoor" && layer["source-layer"] === "trail") {
      map.setLayoutProperty(layer.id, "visibility", "none")
    }
  }
}

function ensureMaptilerSdk() {
  if (window.maptilersdk) return Promise.resolve()

  if (!document.querySelector(`link[href="${MAPTILER_SDK_CSS}"]`)) {
    const link = Object.assign(document.createElement("link"), { rel: "stylesheet", href: MAPTILER_SDK_CSS })
    document.head.appendChild(link)
  }

  return new Promise((resolve, reject) => {
    const script = Object.assign(document.createElement("script"), { src: MAPTILER_SDK_JS })
    script.onload = () => {
      window.maptilersdk.config.apiKey = MAPTILER_KEY
      resolve()
    }
    script.onerror = reject
    document.head.appendChild(script)
  })
}

export default class extends Controller {
  static targets = ["container"]
  static values  = {
    rounds: { type: Array,  default: [] },
    style:  { type: String, default: "outdoor-v2" }
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

      // Answer marker (green)
      new maptilersdk.Marker({ color: "#22c55e" })
        .setLngLat([r.answer_lng, r.answer_lat])
        .setPopup(new maptilersdk.Popup({ offset: 8 }).setHTML(
          `<div class="text-xs font-medium">${label} — ${r.title}</div>` +
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

    this.map.fitBounds(bounds, { padding: 60, maxZoom: 8 })
  }

  // Smooth-pan to a single round's guess+answer pair. Wired up from
  // the per-round thumbnails on /games/:id/results — clicking a round
  // thumbnail dives the map onto that round so the player can see how
  // far off they were. Also scrolls the map element into view since
  // it's typically scrolled past on a results page.
  focus(event) {
    const round = parseInt(event.params?.round, 10)
    const r = this.roundsValue.find((x) => x.round === round)
    if (!r || !this.map) return

    const bounds = new maptilersdk.LngLatBounds()
    bounds.extend([r.guess_lng, r.guess_lat])
    bounds.extend([r.answer_lng, r.answer_lat])
    this.map.fitBounds(bounds, { padding: 80, maxZoom: 14, duration: 700 })

    this.containerTarget.scrollIntoView({ behavior: "smooth", block: "center" })
  }

  // Wired up on the per-row "Details ↗" link in the round breakdown.
  // The whole row is clickable for map-focus, so without this the
  // click on the inner link would bubble up and trigger #focus before
  // the browser navigates. stopPropagation keeps the row's action from
  // firing; the link itself still navigates normally.
  stopRowClick(event) {
    event.stopPropagation()
  }

  disconnect() {
    this.map?.remove()
  }
}
