import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails, escapeText } from "lib/maptiler"

export default class extends Controller {
  static targets = ["container"]
  static values = {
    answer: { type: Array,  default: [] },
    style:  { type: String, default: "outdoor-v2" },
    // {min_lat, max_lat, min_lng, max_lng} — when set, the map fits to it on
    // load so each round starts focused on the area the set's images cover.
    // Empty object means "no bbox known," in which case we keep the world view.
    bbox:   { type: Object, default: {} }
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
      this.fitToBbox()
    })

    this.marker = null
    this.otherGuessLayers = []

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

  fitToBbox() {
    const { min_lat, max_lat, min_lng, max_lng } = this.bboxValue || {}
    if ([min_lat, max_lat, min_lng, max_lng].some(v => typeof v !== "number")) return
    if (min_lat === max_lat && min_lng === max_lng) {
      // Single point — center on it at a moderate zoom rather than fitBounds
      // (which would zoom in past usefulness on a degenerate rectangle).
      this.map.jumpTo({ center: [min_lng, min_lat], zoom: 5 })
      return
    }
    // Cap maxZoom so a tightly-clustered set (one city) doesn't open zoomed
    // so deep that the user can't move around comfortably.
    this.map.fitBounds(
      [ [min_lng, min_lat], [max_lng, max_lat] ],
      { padding: 60, maxZoom: 6, animate: false }
    )
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

  showOtherGuesses(guesses, answerLat, answerLng) {
    if (!guesses.length) return

    const colors = ["#3b82f6", "#f59e0b", "#a855f7", "#14b8a6", "#f97316"]
    const bounds = new maptilersdk.LngLatBounds()
      .extend([answerLng, answerLat])

    if (this.marker) {
      const p = this.marker.getLngLat()
      bounds.extend([p.lng, p.lat])
    }

    guesses.forEach((g, i) => {
      const color = colors[i % colors.length]
      const lat = parseFloat(g.latitude)
      const lng = parseFloat(g.longitude)

      new maptilersdk.Marker({ color, scale: 0.8 })
        .setLngLat([lng, lat])
        .setPopup(new maptilersdk.Popup({ offset: 8 }).setHTML(
          `<div class="text-xs font-medium">${escapeText(g.username)}'s guess</div>`
        ))
        .addTo(this.map)

      const lineId = `other-guess-${i}`
      this.map.addSource(lineId, {
        type: "geojson",
        data: {
          type: "Feature",
          geometry: { type: "LineString", coordinates: [[lng, lat], [answerLng, answerLat]] }
        }
      })
      this.map.addLayer({
        id: lineId, type: "line", source: lineId,
        paint: { "line-color": color, "line-width": 2, "line-dasharray": [3, 4] }
      })

      this.otherGuessLayers.push(lineId)
      bounds.extend([lng, lat])
    })

    this.map.fitBounds(bounds, { padding: 80 })
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
    this.otherGuessLayers.forEach(id => {
      if (this.map.getLayer(id)) this.map.removeLayer(id)
      if (this.map.getSource(id)) this.map.removeSource(id)
    })
    this.otherGuessLayers = []
    this.map.getCanvasContainer().querySelectorAll(".maplibregl-marker").forEach((el) => {
      if (el !== this.marker?._element) el.remove()
    })
  }

  disconnect() {
    this.map?.remove()
  }
}
