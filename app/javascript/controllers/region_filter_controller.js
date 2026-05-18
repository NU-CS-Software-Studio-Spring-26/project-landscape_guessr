import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY, ensureMaptilerSdk, hideOutdoorTrails } from "lib/maptiler"

export default class extends Controller {
  static targets = ["searchInput", "results", "pills", "hiddenFields", "customAreasField", "map", "matchCount", "submitBtn", "nameInput", "hint", "circleModeBtn", "circleStatus", "mapHint"]
  static values = {
    parentSetId: Number,
    mapStyle: { type: String, default: "outdoor-v2" },
    imagesUrl: String,
    initialRegionIds: { type: Array, default: [] },
    initialCustomAreas: { type: Array, default: [] }
  }

  // Circle radii presented as round numbers in km.
  CIRCLE_DEFAULT_KM = 25
  CIRCLE_MIN_KM = 1
  CIRCLE_MAX_KM = 1000

  connect() {
    this.selectedRegions = new Map()
    // Custom areas (currently just circles; polygon path on the backend is
    // ready when a drawing UI ships). Keyed by uuid.
    this.customAreas = new Map()
    this.searchTimeout = null
    this.nameUserEdited = this.hasNameInputTarget && this.nameInputTarget.value.trim().length > 0
    // Drives auto-fit on add. Map-clicks: don't zoom (user's already there).
    // Search adds: zoom so user can see what they picked.
    this.resultsSource = null
    // "Draw a circle" mode — armed via the toolbar button. While armed,
    // mousedown+drag on the map draws a circle instead of panning.
    this.circleDropMode = false
    this.initMap()
  }

  onNameEdit() {
    this.nameUserEdited = true
  }

  updateAutoName() {
    if (!this.hasNameInputTarget || this.nameUserEdited) return
    const prefix = this.nameInputTarget.dataset.namePrefix
    const labels = [
      ...Array.from(this.selectedRegions.values()).map(r => r.name),
      ...Array.from(this.customAreas.values()).map(a => a.name || "custom area")
    ]
    if (labels.length === 0) {
      this.nameInputTarget.value = ""
      return
    }
    const head = labels.slice(0, 3)
    const suffix = labels.length > 3 ? `${head.join(", ")} +${labels.length - 3} more` : head.join(", ")
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
      this.addCustomAreaLayers()
      this.addCirclePreviewLayer()
      this.loadImageDots()
      this.loadInitialRegions()
      this.loadInitialCustomAreas()
    })

    // Plain map clicks reverse-geocode to find regions at the click point.
    // Circle drawing uses mousedown/move/up via attachCircleDragHandlers
    // when "Draw a circle" mode is armed.
    this.map.on("click", (e) => this.onMapClick(e))
  }

  // Live preview circle while the user drags. Same colors as the saved
  // custom-areas layer so the preview looks like the eventual result.
  addCirclePreviewLayer() {
    this.map.addSource("circle-preview", {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] }
    })
    this.map.addLayer({
      id: "circle-preview-fill",
      type: "fill",
      source: "circle-preview",
      paint: { "fill-color": "#f97316", "fill-opacity": 0.20 }
    })
    this.map.addLayer({
      id: "circle-preview-line",
      type: "line",
      source: "circle-preview",
      paint: { "line-color": "#f97316", "line-width": 2, "line-dasharray": [ 3, 3 ] }
    })
  }

  addCustomAreaLayers() {
    this.map.addSource("custom-areas", {
      type: "geojson",
      data: { type: "FeatureCollection", features: [] }
    })
    this.map.addLayer({
      id: "custom-areas-fill",
      type: "fill",
      source: "custom-areas",
      paint: { "fill-color": "#f97316", "fill-opacity": 0.15 }
    })
    this.map.addLayer({
      id: "custom-areas-line",
      type: "line",
      source: "custom-areas",
      paint: { "line-color": "#f97316", "line-width": 2, "line-opacity": 0.9 }
    })
  }

  loadInitialCustomAreas() {
    for (const area of this.initialCustomAreasValue || []) {
      if (!area?.id) continue
      this.customAreas.set(area.id, area)
    }
    if (this.customAreas.size) {
      this.renderPills()
      this.renderHiddenFields()
      this.redrawCustomAreas()
      this.updateMatchCount()
    }
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

    // Seed selectedRegions with placeholder names BEFORE the boundaries fetch
    // so the saved selection is preserved even if the network fetch fails. If
    // we waited until after the fetch, a transient 500 on /regions/boundaries
    // would leave selectedRegions empty — and the next renderHiddenFields()
    // (triggered by any add or remove) would silently overwrite the
    // server-rendered hidden inputs, dropping every previously-saved region.
    for (const id of ids) {
      this.selectedRegions.set(id, { id, name: `Region ${id}`, admin_level: "" })
    }
    this.renderPills()
    this.renderHiddenFields()

    try {
      const params = ids.map(id => `ids[]=${id}`).join("&")
      const resp = await fetch(`/regions/boundaries.json?${params}`)
      const geojson = await resp.json()

      // Enrich placeholders with real names/admin_level from the response.
      for (const feature of geojson.features) {
        this.selectedRegions.set(feature.id, {
          id: feature.id,
          name: feature.properties.name,
          admin_level: feature.properties.admin_level
        })
      }

      this.renderPills()
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
      let url = `/regions/search.json?q=${encodeURIComponent(query)}`
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
    //   - Nominatim candidates: { name, admin_level, country_code, ancestor_chain }
    //     → no DB row yet; button carries the candidate as a data-candidate
    //       JSON blob, and addFromResult must POST /regions/resolve first.
    // Build via DOM nodes so region names from the API can't inject HTML.
    const buttons = items.map(r => {
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
    })

    this.resultsTarget.replaceChildren(...buttons)
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
    const totalSelected = this.selectedRegions.size + this.customAreas.size
    if (totalSelected === 0) {
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

    const regionPills = Array.from(this.selectedRegions.values()).map(r => {
      const colors = levelColors[r.admin_level] || "bg-gray-100 text-gray-700"
      return this.buildPill(r.name, colors, {
        action: "click->region-filter#removeRegion",
        regionId: String(r.id)
      })
    })

    const customPills = Array.from(this.customAreas.values()).map(a => {
      return this.buildPill(a.name || "Custom area", "bg-orange-100 text-orange-700", {
        action: "click->region-filter#removeCustomArea",
        customAreaId: a.id
      })
    })

    this.pillsTarget.replaceChildren(...regionPills, ...customPills)
  }

  buildPill(name, colorClasses, dataset) {
    const pill = document.createElement("span")
    pill.className = `inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium ${colorClasses}`
    pill.appendChild(document.createTextNode(name + " "))

    const removeBtn = document.createElement("button")
    removeBtn.type = "button"
    Object.entries(dataset).forEach(([k, v]) => { removeBtn.dataset[k] = v })
    removeBtn.setAttribute("aria-label", `Remove ${name}`)
    removeBtn.className = "hover:text-red-600 ml-0.5"
    removeBtn.textContent = "×"
    pill.appendChild(removeBtn)
    return pill
  }

  renderHiddenFields() {
    const isNewFilteredForm = !!this.hiddenFieldsTarget.closest("form").querySelector("[name='image_set[parent_image_set_id]']")
    const idFieldName = isNewFilteredForm ? "image_set[region_ids][]" : "region_ids[]"
    const areasFieldName = isNewFilteredForm ? "image_set[custom_areas_json]" : "custom_areas"

    // Region IDs go as repeated inputs (standard Rails array form). Custom
    // areas serialize to one JSON-blob input — the server parses + validates
    // it via ImageSetsController#sanitize_custom_areas.
    const regionInputs = Array.from(this.selectedRegions.keys())
      .map(id => `<input type="hidden" name="${idFieldName}" value="${id}">`)
      .join("")

    const areasJson = JSON.stringify(Array.from(this.customAreas.values()))
      .replace(/"/g, "&quot;")
    const areasInput = `<input type="hidden" name="${areasFieldName}" value="${areasJson}">`

    this.hiddenFieldsTarget.innerHTML = regionInputs + areasInput
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
    const areas = Array.from(this.customAreas.values())
    const totalParts = ids.length + areas.length
    if (totalParts === 0) {
      this.matchCountTarget.textContent = ""
      this.recolorImageDots(new Set())
      this.matchCountAbort?.abort()
      return
    }

    this.matchCountTarget.textContent = `${totalParts} area(s) — counting matching images...`

    // Cancel previous in-flight request so quick add/remove sequences don't
    // race — only the latest selection's count should ever paint.
    this.matchCountAbort?.abort()
    const controller = new AbortController()
    this.matchCountAbort = controller

    try {
      // POST so we can carry the custom_areas JSON cleanly (a long blob would
      // bloat the query string). preview_filter_count accepts both via Rails
      // params resolution, but POST is cleaner for the typical add/remove
      // burst.
      const token = document.querySelector('meta[name="csrf-token"]')?.content
      const url = `/image_sets/${this.parentSetIdValue}/preview_filter_count.json`
      const body = new FormData()
      ids.forEach(id => body.append("region_ids[]", String(id)))
      body.append("custom_areas", JSON.stringify(areas))
      const resp = await fetch(url, {
        method: "POST",
        headers: { "X-CSRF-Token": token || "", "Accept": "application/json" },
        credentials: "same-origin",
        body,
        signal: controller.signal
      })
      const data = await resp.json().catch(() => ({}))
      if (controller.signal.aborted) return
      if (data.count != null) {
        this.matchCountTarget.textContent = `${totalParts} area(s) — ${data.count.toLocaleString()} matching image(s)`
      } else {
        this.matchCountTarget.textContent = `${totalParts} area(s) selected`
      }
      if (Array.isArray(data.matched_ids)) {
        this.recolorImageDots(new Set(data.matched_ids))
      }
    } catch (e) {
      if (e.name === "AbortError") return
      this.matchCountTarget.textContent = `${totalParts} area(s) selected`
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
    // A circle just finished drawing: the browser fires a synthetic `click`
    // off the same gesture, which would otherwise reverse-geocode the release
    // point. Consume the flag and bail.
    if (this._suppressNextClick) {
      this._suppressNextClick = false
      return
    }

    const { lng, lat } = e.lngLat
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      this.showResultsMessage('<div class="p-3 text-sm text-gray-500">No regions found at this location</div>')
      return
    }

    // While circle-drag mode is armed, mousedown/move/up handle drawing —
    // skip the reverse-geocode flow on plain clicks (which fire on mouseup
    // even after small drags in some browsers).
    if (this.circleDropMode) return

    this.resultsSource = "click"
    this.showResultsMessage('<div class="p-3 text-sm text-gray-500">Finding regions at this point...</div>')

    try {
      const candidates = await this.nominatimReverse(lat, lng)
      if (!candidates.length) {
        this.showResultsMessage('<div class="p-3 text-sm text-gray-500">No regions found at this location</div>')
        return
      }
      // Just the geocoder candidates — circles are drawn via the toolbar
      // button (one obvious entry point, drag-to-size). Two affordances
      // for the same thing was confusing.
      this.renderResults(candidates)
    } catch (err) {
      if (err?.message === "rate_limited") {
        this.showResultsMessage('<div class="p-3 text-sm text-amber-700">Geocoder is rate-limited (1 lookup/sec). Wait a few seconds and try again.</div>')
      } else {
        this.showResultsMessage('<div class="p-3 text-sm text-red-500">Failed to find regions</div>')
      }
    }
  }

  toggleCircleMode() {
    this.armCircleMode(!this.circleDropMode)
  }

  armCircleMode(armed) {
    this.circleDropMode = armed
    if (this.hasCircleModeBtnTarget) {
      this.circleModeBtnTarget.classList.toggle("bg-forest-100", armed)
      this.circleModeBtnTarget.setAttribute("aria-pressed", armed ? "true" : "false")
    }
    this.setCircleStatus(armed ? "Drag on the map to draw a circle. Click ✎ again to stop." : null)
    this.mapTarget.style.cursor = armed ? "crosshair" : ""

    // Hot-swap the map's interaction model. Disable dragPan while armed so
    // mouse/touch drag is captured for circle-drawing instead of panning.
    // Pinch-zoom (touchZoomRotate) stays enabled so users can still zoom in
    // to pick a precise center.
    if (armed) {
      this.map?.dragPan.disable()
      this.attachCircleDragHandlers()
    } else {
      this.map?.dragPan.enable()
      this.detachCircleDragHandlers()
      this.clearCirclePreview()
      this._circleDrag = null
    }
  }

  attachCircleDragHandlers() {
    if (this._circleHandlers) return
    const down = (e) => this.onCircleDragStart(e)
    const move = (e) => this.onCircleDragMove(e)
    const up   = (e) => this.onCircleDragEnd(e)
    // Register both mouse and touch events. MapLibre normalizes `lngLat` for
    // both, so the same handler bodies work either way. Without the touch
    // wiring, the entire feature was inert on phones and tablets.
    this._circleHandlers = { down, move, up }
    this.map.on("mousedown",  down)
    this.map.on("mousemove",  move)
    this.map.on("mouseup",    up)
    this.map.on("touchstart", down)
    this.map.on("touchmove",  move)
    this.map.on("touchend",   up)
  }

  detachCircleDragHandlers() {
    if (!this._circleHandlers) return
    const { down, move, up } = this._circleHandlers
    this.map.off("mousedown",  down)
    this.map.off("mousemove",  move)
    this.map.off("mouseup",    up)
    this.map.off("touchstart", down)
    this.map.off("touchmove",  move)
    this.map.off("touchend",   up)
    this._circleHandlers = null
  }

  onCircleDragStart(e) {
    // Ignore multi-touch — that's a pinch-zoom gesture, not a circle draw.
    if (e.points && e.points.length > 1) return
    e.preventDefault?.()
    const { lng, lat } = e.lngLat
    this._circleDrag = { center: { lat, lng }, radiusM: 0 }
    this.updateCirclePreview(lat, lng, 0)
  }

  onCircleDragMove(e) {
    if (!this._circleDrag) return
    if (e.points && e.points.length > 1) return
    const { lng, lat } = e.lngLat
    const r = this.haversineMeters(this._circleDrag.center.lat, this._circleDrag.center.lng, lat, lng)
    this._circleDrag.radiusM = r
    this.updateCirclePreview(this._circleDrag.center.lat, this._circleDrag.center.lng, r)
    this.setCircleStatus(`Radius: ${this.formatKm(r)} — release to finish (click ✎ to stop drawing)`)
  }

  // Show the amber status line and hide the default map hint while circle mode
  // is active. Pass null/undefined to revert to the default hint.
  setCircleStatus(text) {
    if (this.hasCircleStatusTarget) {
      this.circleStatusTarget.textContent = text || ""
      this.circleStatusTarget.classList.toggle("hidden", !text)
    }
    if (this.hasMapHintTarget) {
      this.mapHintTarget.classList.toggle("hidden", !!text)
    }
  }

  onCircleDragEnd(_e) {
    const drag = this._circleDrag
    this._circleDrag = null
    if (!drag) return

    // Suppress the synthetic click that follows mouseup/touchend — without
    // this, onMapClick would reverse-geocode the release point as if the
    // user had tapped to look up regions there.
    this._suppressNextClick = true

    // Treat tiny accidental drags as a no-op rather than dropping a
    // minimum-size circle the user didn't intend.
    if (drag.radiusM < 100) {
      this.clearCirclePreview()
      // Reset the prompt back to the armed-mode hint.
      this.setCircleStatus("Drag on the map to draw a circle. Click ✎ again to stop.")
      return
    }

    const r = Math.max(drag.radiusM, this.CIRCLE_MIN_KM * 1000)
    const capped = Math.min(r, this.CIRCLE_MAX_KM * 1000)
    this.addCircle(drag.center.lat, drag.center.lng, capped)

    // Stay armed — drawing multiple circles in succession was forcing users
    // to re-arm via the toolbar after every release.
    this.clearCirclePreview()
    this.setCircleStatus("Drag on the map to draw another circle. Click ✎ to stop.")
  }

  updateCirclePreview(lat, lng, radiusM) {
    const source = this.map?.getSource("circle-preview")
    if (!source) return
    if (radiusM <= 0) {
      source.setData({ type: "FeatureCollection", features: [] })
      return
    }
    source.setData({
      type: "FeatureCollection",
      features: [ { type: "Feature", geometry: this.circleAsPolygon(lat, lng, radiusM) } ]
    })
  }

  clearCirclePreview() {
    this.map?.getSource("circle-preview")?.setData({ type: "FeatureCollection", features: [] })
  }

  formatKm(meters) {
    const km = meters / 1000
    if (km < 1) return `${Math.round(meters)} m`
    if (km < 10) return `${km.toFixed(1)} km`
    return `${Math.round(km)} km`
  }

  haversineMeters(lat1, lng1, lat2, lng2) {
    const R = 6_371_000
    const toRad = d => d * Math.PI / 180
    const dLat = toRad(lat2 - lat1)
    const dLng = toRad(lng2 - lng1)
    const a = Math.sin(dLat / 2) ** 2 +
              Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  }

  addCircle(lat, lng, radiusM) {
    const id = (crypto?.randomUUID?.() ?? `c_${Date.now()}_${Math.random().toString(36).slice(2, 9)}`)
    const area = {
      id,
      type: "circle",
      name: `${this.formatKm(radiusM)} circle`,
      center: { lat, lng },
      radius_m: radiusM
    }
    this.customAreas.set(id, area)
    this.renderPills()
    this.renderHiddenFields()
    this.redrawCustomAreas()
    this.updateAutoName()
    this.updateMatchCount()
  }

  removeCustomArea(event) {
    const id = event.currentTarget.dataset.customAreaId
    if (!id || !this.customAreas.has(id)) return
    this.customAreas.delete(id)
    this.renderPills()
    this.renderHiddenFields()
    this.redrawCustomAreas()
    this.updateAutoName()
    this.updateMatchCount()
  }

  // Repaint the custom-areas source from the current selection. Circles render
  // as 64-vertex polygons computed in true-distance metres so they stay round
  // at the rendered zoom; small distortion near the poles is acceptable for
  // our use case.
  redrawCustomAreas() {
    const source = this.map?.getSource("custom-areas")
    if (!source) return
    const features = []
    for (const a of this.customAreas.values()) {
      if (a.type === "circle") {
        features.push({
          type: "Feature",
          id: a.id,
          geometry: this.circleAsPolygon(a.center.lat, a.center.lng, a.radius_m),
          properties: { name: a.name }
        })
      } else if (a.type === "polygon" && a.geojson) {
        features.push({
          type: "Feature",
          id: a.id,
          geometry: a.geojson,
          properties: { name: a.name }
        })
      }
    }
    source.setData({ type: "FeatureCollection", features })
  }

  // Generate a GeoJSON Polygon approximating a geodesic circle. 64 vertices
  // is enough that a 5km circle in mid-latitudes looks round at street zoom.
  // Inverse Haversine: walk `radiusM` along bearings 0..360°.
  circleAsPolygon(lat, lng, radiusM, steps = 64) {
    const R = 6371000.0
    const latRad = lat * Math.PI / 180
    const lngRad = lng * Math.PI / 180
    const angDist = radiusM / R
    const coords = []
    for (let i = 0; i <= steps; i++) {
      const bearing = (i / steps) * 2 * Math.PI
      const lat2 = Math.asin(
        Math.sin(latRad) * Math.cos(angDist) +
        Math.cos(latRad) * Math.sin(angDist) * Math.cos(bearing)
      )
      const lng2 = lngRad + Math.atan2(
        Math.sin(bearing) * Math.sin(angDist) * Math.cos(latRad),
        Math.cos(angDist) - Math.sin(latRad) * Math.sin(lat2)
      )
      coords.push([ lng2 * 180 / Math.PI, lat2 * 180 / Math.PI ])
    }
    return { type: "Polygon", coordinates: [ coords ] }
  }

  // Client-side Nominatim reverse-geocode. Same provider as the server-side
  // boundary fetch (Region.fetch_real_boundary!), which means the names we
  // receive here will match what Nominatim's search endpoint returns later
  // when the server fetches the boundary — no name-drift between providers.
  // Distributing the call across user IPs also sidesteps the 1 req/sec/IP
  // rate limit that would otherwise be a chokepoint server-side.
  //
  // Throws Error("rate_limited") on HTTP 429 so the caller can show a
  // dedicated "wait a few seconds" message instead of generic failure.
  async nominatimReverse(lat, lng) {
    const url = `https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lng}` +
                `&format=jsonv2&addressdetails=1&accept-language=en&zoom=12`
    const resp = await fetch(url, { headers: { "Accept": "application/json" } })
    if (resp.status === 429) throw new Error("rate_limited")
    if (!resp.ok) return []
    const data = await resp.json()
    return this.buildCandidatesFromNominatim(data)
  }

  // Map Nominatim's `address` block onto our 4-level admin hierarchy. The
  // returned list goes most-specific (city) → broadest (country) so the UI
  // shows the user's "best guess" at the top of the picker. Each candidate
  // carries the full ancestor chain so the server can resolve it standalone.
  //
  // Field priority per level mirrors how OSM tags admin entities:
  //   admin1: state > region > province
  //   admin2: county > municipality (some EU countries put admin2 there)
  //   city:   city > town > village > hamlet
  // Borough/suburb/neighbourhood are intentionally not city candidates —
  // they're sub-city and would create noise admin levels in our DB.
  buildCandidatesFromNominatim(data) {
    const a = data?.address || {}
    const cc = (a.country_code || "").toUpperCase()
    if (!cc || !a.country) return []

    // Build the ancestor chain top-down so each level can snapshot the right
    // prefix when emitting its candidate.
    const entries = [{ name: a.country, admin_level: "country", country_code: cc }]

    const admin1Name = a.state || a.region || a.province
    if (admin1Name && admin1Name !== a.country) {
      entries.push({ name: admin1Name, admin_level: "admin1", country_code: cc })
    }

    const admin2Name = a.county || a.municipality
    if (admin2Name && admin2Name !== admin1Name) {
      entries.push({ name: admin2Name, admin_level: "admin2", country_code: cc })
    }

    const cityName = a.city || a.town || a.village || a.hamlet
    if (cityName && cityName !== admin1Name && cityName !== admin2Name) {
      entries.push({ name: cityName, admin_level: "city", country_code: cc })
    }

    const candidates = entries.map((e, i) => ({
      ...e,
      ancestor_chain: entries.slice(0, i)
    }))
    return candidates.reverse()
  }
}
