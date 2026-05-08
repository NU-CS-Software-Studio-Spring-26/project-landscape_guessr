// Shared MapTiler SDK loader + helpers used by every map controller
// (guess_map, image_map, results_map). The SDK wraps MapLibre GL and
// adds an `mtsid` to each tile request so traffic is billed per *session*
// rather than per tile — one session covers ~6h or 10k tiles per browser
// context, and Turbo Drive keeps the JS bundle warm across navs so a
// single visitor playing multiple rounds + viewing results = one session.

const MAPTILER_SDK_CSS = "https://cdn.maptiler.com/maptiler-sdk-js/v4.0.2/maptiler-sdk.css"
const MAPTILER_SDK_JS  = "https://cdn.maptiler.com/maptiler-sdk-js/v4.0.2/maptiler-sdk.umd.min.js"
export const MAPTILER_KEY = "biJMFiy9HEvnGGS540u4"

// Idempotent: if the SDK is already on window.maptilersdk, resolves
// immediately. Otherwise injects the CSS + UMD script tags into <head>
// and resolves once the script has executed (which is when the global
// is defined and config.apiKey can be set).
export function ensureMaptilerSdk() {
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

// Hide hiking trails on the outdoor-v2 style. They paint colored lines
// on top of everything — useful for hikers, distracting for a guesser
// game where the player is identifying a station / landmark / region.
// Scoped to source="outdoor" + source-layer="trail" so other styles
// (streets-v2's footpaths, etc.) keep their pedestrian detail.
export function hideOutdoorTrails(map) {
  for (const layer of map.getStyle()?.layers || []) {
    if (layer.source === "outdoor" && layer["source-layer"] === "trail") {
      map.setLayoutProperty(layer.id, "visibility", "none")
    }
  }
}

// Minimal HTML escape for text injected into popup setHTML(). Only `<`
// matters for breaking out of text content into a tag — `>` and `&` in
// text are tolerated by all browsers, and `"` only matters in attribute
// context (which our popup templates don't put user data into). Used
// for Image#title, which is user-editable.
export function escapeText(s) {
  return String(s).replace(/</g, "&lt;")
}
