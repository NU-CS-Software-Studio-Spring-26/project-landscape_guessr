import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails, escapeText } from "lib/maptiler"

// Renders a world map with one circle per point. Used by /images/map and
// /image_sets/:id/map. Wired up via shared/_image_map.html.erb.
//
// Values:
//   points — Array<{ id, lat, lng, title, url? }>
//
// Circles are rendered as a GeoJSON source + circle layer (native WebGL),
// not maptilersdk.Marker DOM elements — that scales fine to a thousand+
// points where a Marker per point would tank the page.
export default class extends Controller {
  static values = {
    points: { type: Array,  default: [] },
    style:  { type: String, default: "outdoor-v2" }
  }

  async connect() {
    await ensureMaptilerSdk()

    this.map = new maptilersdk.Map({
      container: this.element,
      style: `https://api.maptiler.com/maps/${this.styleValue}/style.json?key=${MAPTILER_KEY}`,
      center: [0, 20],
      zoom: 1
    })

    this.map.on("load", () => {
      hideOutdoorTrails(this.map)
      this.#render()
    })
  }

  disconnect() {
    this.map?.remove()
  }

  #render() {
    const points = this.pointsValue
    if (!points.length) return

    this.map.addSource("points", {
      type: "geojson",
      data: {
        type: "FeatureCollection",
        features: points.map((p) => ({
          type: "Feature",
          geometry: { type: "Point", coordinates: [p.lng, p.lat] },
          properties: { id: p.id, title: p.title || "", url: p.url || "", lat: p.lat, lng: p.lng }
        }))
      }
    })

    this.map.addLayer({
      id: "points-circles",
      type: "circle",
      source: "points",
      paint: {
        "circle-radius": 5,
        "circle-color": "#3b82f6",
        "circle-stroke-color": "#1d4ed8",
        "circle-stroke-width": 1.5,
        "circle-opacity": 0.85
      }
    })

    // Hover affordance.
    this.map.on("mouseenter", "points-circles", () => {
      this.map.getCanvas().style.cursor = "pointer"
    })
    this.map.on("mouseleave", "points-circles", () => {
      this.map.getCanvas().style.cursor = ""
    })

    // Click → popup.
    this.map.on("click", "points-circles", (e) => {
      const f = e.features?.[0]
      if (!f) return
      const { id, title, url, lat, lng } = f.properties
      const safeTitle = escapeText(title)
      // 600 source for the 240×120 popup so retina displays render
      // crisp; 300 looked soft on >1x DPR.
      const imgHtml = url
        ? `<img src="${url}${url.includes("?") ? "&" : "?"}width=600" loading="lazy" style="width:100%;height:120px;object-fit:cover;border-radius:4px" alt="">`
        : ""
      const html = `
        <div style="min-width:200px">
          ${imgHtml}
          <div style="margin-top:6px;font-weight:600">${safeTitle}</div>
          <div style="font-size:12px;color:#666">${Number(lat).toFixed(4)}, ${Number(lng).toFixed(4)}</div>
          <a href="/images/${id}" style="color:#2563eb;font-size:12px">Details →</a>
        </div>`
      new maptilersdk.Popup({ offset: 10, maxWidth: "240px" })
        .setLngLat(f.geometry.coordinates)
        .setHTML(html)
        .addTo(this.map)
    })

    // Auto-fit to all points (with sane max zoom so a single point doesn't
    // slam to street level).
    const bounds = new maptilersdk.LngLatBounds()
    points.forEach((p) => bounds.extend([p.lng, p.lat]))
    this.map.fitBounds(bounds, { padding: 60, maxZoom: 9, duration: 0 })
  }
}
