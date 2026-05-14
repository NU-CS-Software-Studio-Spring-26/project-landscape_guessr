import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails } from "lib/maptiler"

export default class extends Controller {
  static targets = ["searchInput", "results", "pills", "hiddenFields", "map", "matchCount", "submitBtn"]
  static values = {
    parentSetId: Number,
    mapStyle: { type: String, default: "outdoor-v2" },
    imagesUrl: String,
    initialRegionIds: { type: Array, default: [] }
  }

  connect() {
    this.selectedRegions = new Map()
    this.searchTimeout = null
    this.initMap()
  }

  disconnect() {
    this.map?.remove()
  }

  async initMap() {
    await ensureMaptilerSdk()

    this.map = new maptilersdk.Map({
      container: this.mapTarget,
      style: `https://api.maptiler.com/maps/${this.mapStyleValue}/style.json?key=${MAPTILER_KEY}`,
      center: [0, 20],
      zoom: 1
    })

    this.map.on("load", () => {
      hideOutdoorTrails(this.map)
      this.addRegionLayers()
      this.loadImageDots()
      this.loadInitialRegions()
    })

    this.map.on("click", (e) => this.onMapClick(e))
  }

  addRegionLayers() {
    this.map.addSource("regions", {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] }
    })

    this.map.addLayer({
      id: "regions-fill",
      type: "fill",
      source: "regions",
      paint: {
        "fill-color": "#166534",
        "fill-opacity": 0.15
      }
    })

    this.map.addLayer({
      id: "regions-line",
      type: "line",
      source: "regions",
      paint: {
        "line-color": "#166534",
        "line-width": 2,
        "line-opacity": 0.8
      }
    })
  }

  async loadImageDots() {
    if (!this.imagesUrlValue) return
    try {
      const resp = await fetch(this.imagesUrlValue)
      const images = await resp.json()
      this.allImagePoints = images

      this.map.addSource("image-dots", {
        type: "geojson",
        data: this.imageDotsGeoJSON(images)
      })

      this.map.addLayer({
        id: "image-dots-layer",
        type: "circle",
        source: "image-dots",
        paint: {
          "circle-radius": 3,
          "circle-color": ["get", "color"],
          "circle-opacity": 0.7
        }
      })
    } catch (e) {
      console.warn("Failed to load image dots:", e)
    }
  }

  imageDotsGeoJSON(images) {
    return {
      type: "FeatureCollection",
      features: images.map(p => ({
        type: "Feature",
        geometry: { type: "Point", coordinates: [p.lng, p.lat] },
        properties: { color: "#9ca3af" }
      }))
    }
  }

  async loadInitialRegions() {
    const ids = this.initialRegionIdsValue
    if (!ids.length) return

    try {
      const params = ids.map(id => `ids[]=${id}`).join("&")
      const resp = await fetch(`/regions/boundaries.json?${params}`)
      const geojson = await resp.json()

      for (const feature of geojson.features) {
        this.selectedRegions.set(feature.id, {
          id: feature.id,
          name: feature.properties.name,
          admin_level: feature.properties.admin_level
        })
      }

      this.renderPills()
      this.renderHiddenFields()
      this.updateMapRegions()
      this.updateMatchCount()
    } catch (e) {
      console.warn("Failed to load initial regions:", e)
    }
  }

  onSearchInput() {
    clearTimeout(this.searchTimeout)
    const query = this.searchInputTarget.value.trim()
    if (query.length < 2) {
      this.resultsTarget.innerHTML = '<div class="p-3 text-sm text-gray-500">Type at least 2 characters to search</div>'
      return
    }
    this.searchTimeout = setTimeout(() => this.performSearch(query), 250)
  }

  async performSearch(query) {
    try {
      const url = `/regions/search.json?q=${encodeURIComponent(query)}&image_set_id=${this.parentSetIdValue}`
      const resp = await fetch(url)
      const regions = await resp.json()
      this.renderResults(regions)
    } catch (e) {
      this.resultsTarget.innerHTML = '<div class="p-3 text-sm text-red-500">Search failed</div>'
    }
  }

  renderResults(regions) {
    if (!regions.length) {
      this.resultsTarget.innerHTML = '<div class="p-3 text-sm text-gray-500">No regions found</div>'
      return
    }

    const levelLabels = { continent: "Continent", country: "Country", admin1: "State/Province", admin2: "County/District", city: "City" }

    this.resultsTarget.innerHTML = regions.map(r => {
      const isSelected = this.selectedRegions.has(r.id)
      const countStr = r.image_count != null ? `<span class="text-xs text-gray-400 ml-1">${r.image_count} img</span>` : ""
      return `
        <button type="button"
                class="w-full text-left px-3 py-2 hover:bg-gray-50 flex items-center justify-between border-b border-gray-100 last:border-0 ${isSelected ? 'bg-forest-50' : ''}"
                data-action="click->region-filter#addFromResult"
                data-region-id="${r.id}"
                data-region-name="${r.name}"
                data-region-level="${r.admin_level}"
                ${isSelected ? "disabled" : ""}>
          <div class="min-w-0">
            <span class="text-sm font-medium text-gray-800">${r.name}</span>
            <span class="text-xs text-gray-500 ml-1">${levelLabels[r.admin_level] || r.admin_level}</span>
            ${countStr}
          </div>
          <span class="text-xs ${isSelected ? 'text-forest-600' : 'text-forest-600 font-medium'}">${isSelected ? '✓ Added' : '+ Add'}</span>
        </button>`
    }).join("")
  }

  addFromResult(event) {
    const btn = event.currentTarget
    const id = parseInt(btn.dataset.regionId)
    const name = btn.dataset.regionName
    const level = btn.dataset.regionLevel

    if (this.selectedRegions.has(id)) return

    this.selectedRegions.set(id, { id, name, admin_level: level })
    this.renderPills()
    this.renderHiddenFields()
    this.updateMapRegions()
    this.updateMatchCount()

    btn.classList.add("bg-forest-50")
    btn.querySelector("span:last-child").textContent = "✓ Added"
    btn.disabled = true
  }

  removeRegion(event) {
    const id = parseInt(event.currentTarget.dataset.regionId)
    this.selectedRegions.delete(id)
    this.renderPills()
    this.renderHiddenFields()
    this.updateMapRegions()
    this.updateMatchCount()
  }

  renderPills() {
    if (this.selectedRegions.size === 0) {
      this.pillsTarget.innerHTML = '<span class="text-sm text-gray-400 italic">None selected — add regions above</span>'
      return
    }

    const levelColors = {
      continent: "bg-purple-100 text-purple-700",
      country: "bg-blue-100 text-blue-700",
      admin1: "bg-green-100 text-green-700",
      admin2: "bg-amber-100 text-amber-700",
      city: "bg-rose-100 text-rose-700"
    }

    this.pillsTarget.innerHTML = Array.from(this.selectedRegions.values()).map(r => {
      const colors = levelColors[r.admin_level] || "bg-gray-100 text-gray-700"
      return `
        <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${colors}">
          ${r.name}
          <button type="button" data-action="click->region-filter#removeRegion" data-region-id="${r.id}"
                  class="hover:text-red-600 ml-0.5">&times;</button>
        </span>`
    }).join("")
  }

  renderHiddenFields() {
    const fieldName = this.hiddenFieldsTarget.closest("form").querySelector("[name='image_set[parent_image_set_id]']")
      ? "image_set[region_ids][]"
      : "region_ids[]"

    this.hiddenFieldsTarget.innerHTML = Array.from(this.selectedRegions.keys())
      .map(id => `<input type="hidden" name="${fieldName}" value="${id}">`)
      .join("")
  }

  async updateMapRegions() {
    const ids = Array.from(this.selectedRegions.keys())
    if (!ids.length) {
      this.map.getSource("regions")?.setData({ type: "FeatureCollection", features: [] })
      return
    }

    try {
      const params = ids.map(id => `ids[]=${id}`).join("&")
      const resp = await fetch(`/regions/boundaries.json?${params}`)
      const geojson = await resp.json()
      this.map.getSource("regions")?.setData(geojson)

      // Fit map to the selected regions
      const bounds = new maptilersdk.LngLatBounds()
      for (const feature of geojson.features) {
        this.extendBoundsWithGeometry(bounds, feature.geometry)
      }
      if (!bounds.isEmpty()) {
        this.map.fitBounds(bounds, { padding: 40, maxZoom: 8, duration: 500 })
      }
    } catch (e) {
      console.warn("Failed to load region boundaries:", e)
    }
  }

  extendBoundsWithGeometry(bounds, geometry) {
    if (!geometry) return
    const coords = geometry.type === "Polygon"
      ? geometry.coordinates[0]
      : geometry.type === "MultiPolygon"
        ? geometry.coordinates.flat(2)
        : []
    for (const coord of coords) {
      bounds.extend(coord)
    }
  }

  async updateMatchCount() {
    const ids = Array.from(this.selectedRegions.keys())
    if (!ids.length) {
      this.matchCountTarget.textContent = ""
      return
    }

    this.matchCountTarget.textContent = "counting..."

    try {
      const params = ids.map(id => `ids[]=${id}`).join("&")
      const resp = await fetch(`/regions/search.json?q=&image_set_id=${this.parentSetIdValue}&count_for_ids=${params}`)
      // For now, just show region count
      this.matchCountTarget.textContent = `${this.selectedRegions.size} region(s) selected`
    } catch (e) {
      this.matchCountTarget.textContent = `${this.selectedRegions.size} region(s) selected`
    }
  }

  async onMapClick(e) {
    const { lng, lat } = e.lngLat
    this.resultsTarget.innerHTML = '<div class="p-3 text-sm text-gray-500">Finding regions at this point...</div>'

    try {
      const resp = await fetch(`/regions/at_point.json?lat=${lat}&lng=${lng}`)
      const regions = await resp.json()

      if (!regions.length) {
        this.resultsTarget.innerHTML = '<div class="p-3 text-sm text-gray-500">No regions found at this location</div>'
        return
      }

      this.renderResults(regions.map(r => ({ ...r, image_count: null })))
    } catch (e) {
      this.resultsTarget.innerHTML = '<div class="p-3 text-sm text-red-500">Failed to find regions</div>'
    }
  }
}
