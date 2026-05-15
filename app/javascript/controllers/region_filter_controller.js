import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails } from "lib/maptiler"

export default class extends Controller {
  static targets = ["searchInput", "results", "pills", "hiddenFields", "map", "matchCount", "submitBtn", "nameInput", "hint"]
  static values = {
    parentSetId: Number,
    mapStyle: { type: String, default: "outdoor-v2" },
    imagesUrl: String,
    initialRegionIds: { type: Array, default: [] }
  }

  connect() {
    this.selectedRegions = new Map()
    this.searchTimeout = null
    // Track whether the user has manually edited the name. We auto-fill from
    // selected regions until they touch it, then we leave it alone.
    this.nameUserEdited = this.hasNameInputTarget && this.nameInputTarget.value.trim().length > 0
    // Source of the currently-displayed results — drives whether we auto-fit
    // the map after an add. Click-add: user is already looking at the spot
    // so don't zoom. Search-add: zoom to show what they picked.
    this.resultsSource = null
    this.initMap()
  }

  onNameEdit() {
    this.nameUserEdited = true
  }

  updateAutoName() {
    if (!this.hasNameInputTarget || this.nameUserEdited) return
    const prefix = this.nameInputTarget.dataset.namePrefix
    const regions = Array.from(this.selectedRegions.values())
    if (regions.length === 0) {
      this.nameInputTarget.value = ""
      return
    }
    const names = regions.slice(0, 3).map(r => r.name)
    const suffix = regions.length > 3 ? `${names.join(", ")} +${regions.length - 3} more` : names.join(", ")
    this.nameInputTarget.value = `${prefix} — ${suffix}`
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

      if (this.map.getLayer("regions-fill")) {
        this.map.moveLayer("regions-fill")
        this.map.moveLayer("regions-line")
      }
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

  // Show a message in the results container, making sure it's visible
  // and the empty-state hint is hidden.
  showResultsMessage(html) {
    this.resultsTarget.classList.remove("hidden")
    this.resultsTarget.innerHTML = html
    if (this.hasHintTarget) this.hintTarget.classList.add("hidden")
  }

  hideResults() {
    this.resultsTarget.classList.add("hidden")
    this.resultsTarget.innerHTML = ""
    if (this.hasHintTarget) this.hintTarget.classList.remove("hidden")
  }

  onSearchInput() {
    clearTimeout(this.searchTimeout)
    const query = this.searchInputTarget.value.trim()
    if (query.length < 2) {
      this.hideResults()
      return
    }
    this.searchTimeout = setTimeout(() => this.performSearch(query), 250)
  }

  async performSearch(query) {
    try {
      let url = `/regions/search.json?q=${encodeURIComponent(query)}&image_set_id=${this.parentSetIdValue}`
      // Only bias by location when the user has zoomed past world view —
      // at zoom 1-3 the map is at the default world center and distance is meaningless.
      const zoom = this.map?.getZoom()
      if (this.map && zoom && zoom >= 4) {
        const center = this.map.getCenter()
        url += `&lat=${center.lat.toFixed(4)}&lng=${center.lng.toFixed(4)}`
      }
      const resp = await fetch(url)
      const regions = await resp.json()
      this.resultsSource = "search"
      this.renderResults(regions)
    } catch (e) {
      this.showResultsMessage('<div class="p-3 text-sm text-red-500">Search failed</div>')
    }
  }

  renderResults(items) {
    if (!items.length) {
      this.showResultsMessage('<div class="p-3 text-sm text-gray-500">No regions found</div>')
      return
    }
    this.resultsTarget.classList.remove("hidden")
    if (this.hasHintTarget) this.hintTarget.classList.add("hidden")

    const levelLabels = { continent: "Continent", country: "Country", admin1: "State/Province", admin2: "County/District", city: "City" }

    // Items are one of two shapes:
    //   - search-bar results: { id, name, admin_level, parent_name, ... }
    //     → button carries data-region-id and can be added immediately.
    //   - at_point candidates: { name, admin_level, country_code, ancestor_chain }
    //     → no DB row yet; button carries the candidate as a data-candidate
    //       JSON blob, and addFromResult must POST /regions/resolve first.
    // Build via DOM nodes so region names from the API can't inject HTML.
    this.resultsTarget.replaceChildren(...items.map(r => {
      const isCandidate = r.id == null
      const knownId = isCandidate ? null : r.id
      const isSelected = !isCandidate && this.selectedRegions.has(knownId)

      const btn = document.createElement("button")
      btn.type = "button"
      btn.className = `w-full text-left px-3 py-2 hover:bg-gray-50 flex items-center justify-between border-b border-gray-100 last:border-0 ${isSelected ? 'bg-forest-50' : ''}`
      btn.dataset.action = "click->region-filter#addFromResult"
      btn.dataset.regionName = r.name
      btn.dataset.regionLevel = r.admin_level
      if (isCandidate) {
        btn.dataset.candidate = JSON.stringify({
          name: r.name,
          admin_level: r.admin_level,
          country_code: r.country_code,
          ancestor_chain: r.ancestor_chain || []
        })
      } else {
        btn.dataset.regionId = knownId
      }
      if (isSelected) btn.disabled = true

      const info = document.createElement("div")
      info.className = "min-w-0"

      const nameSpan = document.createElement("span")
      nameSpan.className = "text-sm font-medium text-gray-800"
      nameSpan.textContent = r.name
      info.appendChild(nameSpan)

      const levelSpan = document.createElement("span")
      levelSpan.className = "text-xs text-gray-500 ml-1"
      levelSpan.textContent = levelLabels[r.admin_level] || r.admin_level
      info.appendChild(levelSpan)

      // For candidates, build the parent chain string from the ancestor chain
      // (which is country → admin1 → admin2). For DB regions, use parent_name
      // populated by the search endpoint.
      const parentText = isCandidate
        ? (r.ancestor_chain || []).map(a => a.name).reverse().join(", ")
        : r.parent_name
      if (parentText) {
        const parentSpan = document.createElement("span")
        parentSpan.className = "text-xs text-gray-400 ml-1"
        parentSpan.textContent = `· ${parentText}`
        info.appendChild(parentSpan)
      }

      const action = document.createElement("span")
      action.dataset.actionLabel = ""
      action.className = "text-xs text-forest-600 font-medium shrink-0 ml-2"
      action.textContent = isSelected ? "✓ Added" : "+ Add"

      btn.appendChild(info)
      btn.appendChild(action)
      return btn
    }))
  }

  // Two entry shapes:
  //   - data-region-id on the button → already a DB row (search result). Skip
  //     resolve, go straight to selection + boundary fetch.
  //   - data-candidate on the button → geocoder candidate from a map click.
  //     POST /regions/resolve first to find-or-create the Region row, then
  //     proceed identically once we have an id.
  async addFromResult(event) {
    const btn = event.currentTarget
    const label = btn.querySelector("[data-action-label]")
    const name = btn.dataset.regionName
    const level = btn.dataset.regionLevel

    if (label) label.textContent = "⏳ Loading..."
    btn.disabled = true

    let id
    if (btn.dataset.regionId) {
      id = parseInt(btn.dataset.regionId)
    } else if (btn.dataset.candidate) {
      const candidate = JSON.parse(btn.dataset.candidate)
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      try {
        const resp = await fetch("/regions/resolve.json", {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": token || "" },
          credentials: "same-origin",
          body: JSON.stringify({ candidate })
        })
        if (!resp.ok) throw new Error(`resolve ${resp.status}`)
        const data = await resp.json()
        if (!data.region_id) throw new Error("no region_id")
        id = data.region_id
      } catch (e) {
        if (label) label.textContent = "⚠ Failed"
        setTimeout(() => {
          if (label) label.textContent = "+ Add"
          btn.disabled = false
        }, 2000)
        return
      }
    } else {
      return
    }

    if (this.selectedRegions.has(id)) {
      if (label) label.textContent = "✓ Added"
      return
    }

    this.selectedRegions.set(id, { id, name, admin_level: level })
    this.renderPills()
    this.renderHiddenFields()
    this.updateAutoName()
    btn.classList.add("bg-forest-50")

    // No auto-fit on click-source adds — user is already looking at the spot.
    // Search adds still fit so the user can see what they just picked.
    const fitBounds = this.resultsSource !== "click"

    const loadedIds = await this.updateMapRegions({ fitBounds })
    if (loadedIds.has(id)) {
      if (label) label.textContent = "✓ Added"
      this.updateMatchCount()
    } else {
      // Boundary fetch failed — roll back the selection.
      this.selectedRegions.delete(id)
      this.renderPills()
      this.renderHiddenFields()
      this.updateAutoName()
      if (label) label.textContent = "⚠ Failed"
      btn.classList.remove("bg-forest-50")
      setTimeout(() => {
        if (label) label.textContent = "+ Add"
        btn.disabled = false
      }, 2000)
    }
  }

  removeRegion(event) {
    const id = parseInt(event.currentTarget.dataset.regionId)
    this.selectedRegions.delete(id)
    this.renderPills()
    this.renderHiddenFields()
    this.updateAutoName()
    // Don't fit-bounds on remove — losing one region shouldn't jerk the camera
    // around. User's mental model: removal is a small delta, not a "look here"
    // event.
    this.updateMapRegions({ fitBounds: false }).then(() => this.updateMatchCount())
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

    this.pillsTarget.replaceChildren(...Array.from(this.selectedRegions.values()).map(r => {
      const colors = levelColors[r.admin_level] || "bg-gray-100 text-gray-700"
      const pill = document.createElement("span")
      pill.className = `inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${colors}`
      pill.appendChild(document.createTextNode(r.name + " "))

      const removeBtn = document.createElement("button")
      removeBtn.type = "button"
      removeBtn.dataset.action = "click->region-filter#removeRegion"
      removeBtn.dataset.regionId = r.id
      removeBtn.setAttribute("aria-label", `Remove ${r.name}`)
      removeBtn.className = "hover:text-red-600 ml-0.5"
      removeBtn.textContent = "×"
      pill.appendChild(removeBtn)
      return pill
    }))
  }

  renderHiddenFields() {
    const fieldName = this.hiddenFieldsTarget.closest("form").querySelector("[name='image_set[parent_image_set_id]']")
      ? "image_set[region_ids][]"
      : "region_ids[]"

    this.hiddenFieldsTarget.innerHTML = Array.from(this.selectedRegions.keys())
      .map(id => `<input type="hidden" name="${fieldName}" value="${id}">`)
      .join("")
  }

  // Returns a Set of region IDs that successfully got a boundary loaded.
  // The caller can check membership to decide whether an Add succeeded.
  // Pass { fitBounds: false } to skip the auto-zoom (e.g. after map-click adds).
  async updateMapRegions({ fitBounds = true } = {}) {
    const ids = Array.from(this.selectedRegions.keys())
    if (!ids.length) {
      this.map.getSource("regions")?.setData({ type: "FeatureCollection", features: [] })
      return new Set()
    }

    try {
      const params = ids.map(id => `ids[]=${id}`).join("&")
      const resp = await fetch(`/regions/boundaries.json?${params}`)
      const geojson = await resp.json()
      this.map.getSource("regions")?.setData(geojson)

      if (fitBounds) {
        const bounds = new maptilersdk.LngLatBounds()
        for (const feature of geojson.features) {
          this.extendBoundsWithGeometry(bounds, feature.geometry)
        }
        if (!bounds.isEmpty()) {
          this.map.fitBounds(bounds, { padding: 40, maxZoom: 8, duration: 500 })
        }
      }

      return new Set(geojson.features.map(f => f.id).filter(Boolean))
    } catch (e) {
      console.warn("Failed to load region boundaries:", e)
      return new Set()
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
      this.recolorImageDots(new Set())
      // Cancel any in-flight count fetch so it can't paint stale data.
      this.matchCountAbort?.abort()
      return
    }

    this.matchCountTarget.textContent = `${ids.length} region(s) — counting matching images...`

    // Cancel previous in-flight request so quick add/remove sequences don't
    // race — only the latest selection's count should ever paint.
    this.matchCountAbort?.abort()
    const controller = new AbortController()
    this.matchCountAbort = controller

    try {
      const params = ids.map(id => `region_ids[]=${id}`).join("&")
      const url = `/image_sets/${this.parentSetIdValue}/preview_filter_count.json?${params}`
      const resp = await fetch(url, { signal: controller.signal })
      const data = await resp.json().catch(() => ({}))
      if (controller.signal.aborted) return
      if (data.count != null) {
        this.matchCountTarget.textContent = `${ids.length} region(s) — ${data.count.toLocaleString()} matching image(s)`
      } else {
        this.matchCountTarget.textContent = `${ids.length} region(s) selected`
      }
      // Recolor dots if the server returned the matched image IDs (we'll add
      // them to the response below).
      if (Array.isArray(data.matched_ids)) {
        this.recolorImageDots(new Set(data.matched_ids))
      }
    } catch (e) {
      if (e.name === "AbortError") return
      this.matchCountTarget.textContent = `${ids.length} region(s) selected`
    }
  }

  // Repaint the image-dots layer based on which IDs are matched by the current
  // filter. Matched = forest-green (#166534), unmatched = gray (#9ca3af).
  // Without this the user gets no visual signal of what their filter catches.
  recolorImageDots(matchedIds) {
    const source = this.map?.getSource("image-dots")
    if (!source || !this.allImagePoints) return
    const features = this.allImagePoints.map(p => ({
      type: "Feature",
      geometry: { type: "Point", coordinates: [ p.lng, p.lat ] },
      properties: { color: matchedIds.has(p.id) ? "#166534" : "#9ca3af" }
    }))
    source.setData({ type: "FeatureCollection", features })
  }

  async onMapClick(e) {
    const { lng, lat } = e.lngLat
    this.resultsSource = "click"
    this.showResultsMessage('<div class="p-3 text-sm text-gray-500">Finding regions at this point...</div>')

    try {
      const resp = await fetch(`/regions/at_point.json?lat=${lat}&lng=${lng}`)
      const regions = await resp.json()
      if (!Array.isArray(regions) || !regions.length) {
        this.showResultsMessage('<div class="p-3 text-sm text-gray-500">No regions found at this location</div>')
        return
      }

      this.renderResults(regions)
    } catch (e) {
      this.showResultsMessage('<div class="p-3 text-sm text-red-500">Failed to find regions</div>')
    }
  }
}
