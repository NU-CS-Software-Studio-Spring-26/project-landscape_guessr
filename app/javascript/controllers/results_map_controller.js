import { Controller } from "@hotwired/stimulus"

const MAPLIBRE_CSS = "https://unpkg.com/maplibre-gl@5.5.0/dist/maplibre-gl.css"
const MAPLIBRE_JS  = "https://unpkg.com/maplibre-gl@5.5.0/dist/maplibre-gl.js"

const COLORS = [
  "#3b82f6", "#ef4444", "#22c55e", "#f59e0b", "#a855f7",
  "#14b8a6", "#f97316", "#ec4899", "#6366f1", "#84cc16"
]

function ensureMaplibre() {
  if (window.maplibregl) return Promise.resolve()

  if (!document.querySelector(`link[href="${MAPLIBRE_CSS}"]`)) {
    const link = Object.assign(document.createElement("link"), { rel: "stylesheet", href: MAPLIBRE_CSS })
    document.head.appendChild(link)
  }

  return new Promise((resolve, reject) => {
    const script = Object.assign(document.createElement("script"), { src: MAPLIBRE_JS })
    script.onload = resolve
    script.onerror = reject
    document.head.appendChild(script)
  })
}

export default class extends Controller {
  static targets = ["container"]
  static values  = { rounds: { type: Array, default: [] } }

  async connect() {
    await ensureMaplibre()

    this.map = new maplibregl.Map({
      container: this.containerTarget,
      style: "https://api.maptiler.com/maps/streets-v2/style.json?key=RWz2xTwJMGVfRP9y6hhf",
      center: [0, 20],
      zoom: 1.5
    })

    this.map.on("load", () => this.#renderRounds())
  }

  #renderRounds() {
    const rounds = this.roundsValue
    if (!rounds.length) return

    const bounds = new maplibregl.LngLatBounds()

    rounds.forEach((r, i) => {
      const color = COLORS[i % COLORS.length]
      const label = `Round ${r.round}`

      // Guess marker (hollow circle style via red)
      new maplibregl.Marker({ color: "#ef4444" })
        .setLngLat([r.guess_lng, r.guess_lat])
        .setPopup(new maplibregl.Popup({ offset: 8 }).setHTML(
          `<div class="text-xs font-medium">${label} — your guess</div>` +
          `<div class="text-xs text-gray-500">${r.guess_lat.toFixed(4)}, ${r.guess_lng.toFixed(4)}</div>` +
          `<div class="text-xs text-gray-500">${r.distance_km.toLocaleString()} km off</div>`
        ))
        .addTo(this.map)

      // Answer marker (green)
      new maplibregl.Marker({ color: "#22c55e" })
        .setLngLat([r.answer_lng, r.answer_lat])
        .setPopup(new maplibregl.Popup({ offset: 8 }).setHTML(
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

  disconnect() {
    this.map?.remove()
  }
}
