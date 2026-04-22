import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]
  static values = {
    answer: { type: Array, default: [] } // [lat, lng] — set after guess to show the answer
  }

  connect() {
    this.map = new maplibregl.Map({
      container: this.containerTarget,
      style: "https://api.maptiler.com/maps/streets-v2/style.json?key=RWz2xTwJMGVfRP9y6hhf",
      center: [0, 20],
      zoom: 1.5
    })

    this.marker = null

    this.map.on("click", (e) => {
      if (this.locked) return

      const { lng, lat } = e.lngLat

      if (this.marker) {
        this.marker.setLngLat([lng, lat])
      } else {
        this.marker = new maplibregl.Marker({ color: "#ef4444" })
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

    new maplibregl.Marker({ color: "#22c55e" })
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

      const bounds = new maplibregl.LngLatBounds()
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
