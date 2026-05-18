import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails, escapeText, shorterLineCoords } from "lib/maptiler"

export default class extends Controller {
  static targets = ["container", "loader"]
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

    // outdoor-v2 paints colored hiking / bicycle / via-ferrata trails on
    // top of everything — useful for hikers, distracting for a guessing
    // game. They all live in source "outdoor", source-layer "trail";
    // hide the whole layer set in one pass after the style loads.
    this.map.on("load", () => {
      hideOutdoorTrails(this.map)
      this.#hideLoader()
    })
    this.map.on("error", () => this.#hideLoader())

    this.marker = null
    this.otherGuessLayers = []

    this.map.on("click", (e) => {
      if (this.locked) return

      // Wrap longitude into [-180, 180] before doing anything else.
      // MapLibre returns unwrapped lngLat when the user has panned past
      // the antimeridian (e.g. lng=-184.93 after panning west past the
      // date line). The server-side Guess validates longitude is in
      // [-180, 180] and would 422 otherwise; flat-coord line draws
      // would also take the long way around the world.
      const { lng, lat } = e.lngLat.wrap()
      this.placePin(lat, lng)

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

  placePin(lat, lng) {
    if (this.marker) {
      this.marker.setLngLat([lng, lat])
    } else {
      this.marker = new maptilersdk.Marker({ color: "#ef4444" })
        .setLngLat([lng, lat])
        .addTo(this.map)
    }
  }

  lock() {
    this.locked = true
  }

  showAnswerHintCircle(lat, lng, radiusKm = 4000) {
    if (!this.map) return
    if (!this.map.isStyleLoaded()) {
      this.map.once("load", () => this.showAnswerHintCircle(lat, lng, radiusKm))
      return
    }

    const sourceId = "answer-hint-circle"
    const fillLayerId = "answer-hint-circle-fill"
    const outlineLayerId = "answer-hint-circle-outline"

    if (this.map.getLayer(fillLayerId)) this.map.removeLayer(fillLayerId)
    if (this.map.getLayer(outlineLayerId)) this.map.removeLayer(outlineLayerId)
    if (this.map.getSource(sourceId)) this.map.removeSource(sourceId)

    this.map.addSource(sourceId, {
      type: "geojson",
      data: this.#circleGeoJson(lat, lng, radiusKm)
    })
    this.map.addLayer({
      id: fillLayerId,
      type: "fill",
      source: sourceId,
      paint: {
        "fill-color": "#16a34a",
        "fill-opacity": 0.08
      }
    })
    this.map.addLayer({
      id: outlineLayerId,
      type: "line",
      source: sourceId,
      paint: {
        "line-color": "#16a34a",
        "line-width": 2,
        "line-opacity": 0.8
      }
    })
  }

  hideAnswerHintCircle() {
    if (!this.map) return

    const sourceId = "answer-hint-circle"
    const fillLayerId = "answer-hint-circle-fill"
    const outlineLayerId = "answer-hint-circle-outline"
    if (this.map.getLayer(fillLayerId)) this.map.removeLayer(fillLayerId)
    if (this.map.getLayer(outlineLayerId)) this.map.removeLayer(outlineLayerId)
    if (this.map.getSource(sourceId)) this.map.removeSource(sourceId)
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
            coordinates: shorterLineCoords([guessLngLat.lng, guessLngLat.lat], [lng, lat])
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
          geometry: { type: "LineString", coordinates: shorterLineCoords([lng, lat], [answerLng, answerLat]) }
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
    this.hideAnswerHintCircle()
    this.map.getCanvasContainer().querySelectorAll(".maplibregl-marker").forEach((el) => {
      if (el !== this.marker?._element) el.remove()
    })
  }

  disconnect() {
    this.map?.remove()
  }

  #hideLoader() {
    if (this.hasLoaderTarget) this.loaderTarget.classList.add("hidden")
  }

  #circleGeoJson(centerLat, centerLng, radiusKm) {
    const earthRadiusKm = 6371
    const angularDistance = radiusKm / earthRadiusKm
    const lat1 = this.#degToRad(centerLat)
    const lng1 = this.#degToRad(centerLng)
    const steps = 128
    const coords = []

    for (let i = 0; i <= steps; i += 1) {
      const bearing = (i / steps) * 2 * Math.PI
      const lat2 = Math.asin(
        Math.sin(lat1) * Math.cos(angularDistance) +
        Math.cos(lat1) * Math.sin(angularDistance) * Math.cos(bearing)
      )
      const lng2 = lng1 + Math.atan2(
        Math.sin(bearing) * Math.sin(angularDistance) * Math.cos(lat1),
        Math.cos(angularDistance) - Math.sin(lat1) * Math.sin(lat2)
      )

      coords.push([
        this.#normalizeLng(this.#radToDeg(lng2)),
        this.#radToDeg(lat2)
      ])
    }

    return {
      type: "Feature",
      geometry: {
        type: "Polygon",
        coordinates: [coords]
      }
    }
  }

  #degToRad(v) {
    return (v * Math.PI) / 180
  }

  #radToDeg(v) {
    return (v * 180) / Math.PI
  }

  #normalizeLng(lng) {
    let normalized = lng
    while (normalized > 180) normalized -= 360
    while (normalized < -180) normalized += 360
    return normalized
  }
}
