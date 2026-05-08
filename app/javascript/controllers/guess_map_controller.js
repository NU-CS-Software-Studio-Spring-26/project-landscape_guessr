import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails } from "lib/maptiler"

export default class extends Controller {
  static targets = ["container"]
  static values = {
    answer: { type: Array,  default: [] },
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

    // outdoor-v2 paints colored hiking / bicycle / via-ferrata trails on
    // top of everything — useful for hikers, distracting for a guessing
    // game. They all live in source "outdoor", source-layer "trail";
    // hide the whole layer set in one pass after the style loads.
    this.map.on("load", () => hideOutdoorTrails(this.map))

    this.marker = null

    this.map.on("click", (e) => {
      if (this.locked) return

      const { lng, lat } = e.lngLat

      if (this.marker) {
        this.marker.setLngLat([lng, lat])
      } else {
        this.marker = new maptilersdk.Marker({ color: "#ef4444" })
          .setLngLat([lng, lat])
          .addTo(this.map)
      }

      this.dispatch("pinned", { detail: { lat, lng } })
    })
  }

  lock() {
    this.locked = true
  }

  showAnswer(lat, lng) {
    this.lock()

    new maptilersdk.Marker({ color: "#22c55e" })
      .setLngLat([lng, lat])
      .addTo(this.map)

    if (this.marker) {
      const guessLngLat = this.marker.getLngLat()
      this.map.addSource("answer-line", {
        type: "geojson",
        data: {
          type: "Feature",
          geometry: {
            type: "LineString",
            coordinates: [
              [guessLngLat.lng, guessLngLat.lat],
              [lng, lat]
            ]
          }
        }
      })
      this.map.addLayer({
        id: "answer-line",
        type: "line",
        source: "answer-line",
        paint: {
          "line-color": "#6b7280",
          "line-width": 2,
          "line-dasharray": [4, 4]
        }
      })

      const bounds = new maptilersdk.LngLatBounds()
        .extend([guessLngLat.lng, guessLngLat.lat])
        .extend([lng, lat])
      this.map.fitBounds(bounds, { padding: 80 })
    }
  }

  reset() {
    this.locked = false
    if (this.marker) {
      this.marker.remove()
      this.marker = null
    }
    if (this.map.getLayer("answer-line")) {
      this.map.removeLayer("answer-line")
      this.map.removeSource("answer-line")
    }
    this.map.getCanvasContainer().querySelectorAll(".maplibregl-marker").forEach((el) => {
      if (el !== this.marker?._element) el.remove()
    })
  }

  disconnect() {
    this.map?.remove()
  }
}
