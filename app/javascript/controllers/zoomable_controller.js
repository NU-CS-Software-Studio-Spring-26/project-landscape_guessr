import { Controller } from "@hotwired/stimulus"

// Map-style zoom on a single <img>. Scroll wheel zooms centered on the
// cursor (the point under the cursor stays put — same UX as Google
// Maps / MapLibre). When zoomed in, click-and-drag pans. Double-click
// resets. Used on /games/:id and /practice/:id so players can read
// station signage / route numbers without a new-tab roundtrip.
//
// HTML wiring:
//   <div data-controller="zoomable" data-zoomable-cap-width-value="3840">
//     <div data-zoomable-target="viewport" class="... overflow-hidden">
//       <img src="..." class="...">  <!-- only direct child that matters -->
//     </div>
//     <button data-zoomable-target="originalButton"
//             data-action="zoomable#loadOriginal" class="hidden">
//       load full quality
//     </button>
//   </div>
//
// The controller's element is the outer wrapper so target lookups (button)
// resolve, but wheel/mouse listeners and geometry stay scoped to the
// `viewport` target — otherwise scrolling over a sibling row (hint text,
// the button) would trigger a no-op zoom. If `viewport` isn't declared
// (zoom-only callers), this falls back to `this.element`.
//
// Notes:
// - Wheel events are intercepted only when zooming would actually do
//   something. At scale=1 + scroll-down (zoom-out attempted), the
//   event passes through so the page can still scroll past the photo.
// - Touch is left to the browser's native pinch-to-zoom — building a
//   second pinch handler ourselves would clash with that and isn't
//   worth the code on small screens.
// - clamp() keeps the image edges flush with the container — you
//   can't drag the photo off into empty space.
const MIN_SCALE  = 1
const MAX_SCALE  = 8
const ZOOM_SPEED = 0.0015  // wheel-delta multiplier feeding Math.exp()

export default class extends Controller {
  static targets = ["originalButton", "viewport"]
  static values  = { capWidth: { type: Number, default: 0 } }

  connect() {
    this.scale = 1
    this.tx    = 0
    this.ty    = 0
    this.dragging = false
    this.viewport = this.hasViewportTarget ? this.viewportTarget : this.element
    this.img = this.viewport.querySelector("img")
    if (!this.img) return

    this.viewport.style.overflow = "hidden"
    this.img.style.transformOrigin = "0 0"
    this.img.style.willChange      = "transform"
    this.img.style.cursor          = "zoom-in"
    this.img.draggable             = false  // suppress browser ghost-drag

    this.viewport.addEventListener("wheel",     this.onWheel,      { passive: false })
    this.viewport.addEventListener("mousedown", this.onMouseDown)
    this.viewport.addEventListener("dblclick",  this.onDoubleClick)
    window.addEventListener("mousemove",        this.onMouseMove)
    window.addEventListener("mouseup",          this.onMouseUp)

    this.#maybeRevealOriginalButton()
  }

  disconnect() {
    if (!this.viewport) return
    this.viewport.removeEventListener("wheel",     this.onWheel)
    this.viewport.removeEventListener("mousedown", this.onMouseDown)
    this.viewport.removeEventListener("dblclick",  this.onDoubleClick)
    window.removeEventListener("mousemove",        this.onMouseMove)
    window.removeEventListener("mouseup",          this.onMouseUp)
  }

  onWheel = (e) => {
    // Already at min scale and scrolling down → let the page scroll
    // past instead of capturing the wheel for a no-op zoom-out.
    if (this.scale <= MIN_SCALE && e.deltaY > 0) return
    e.preventDefault()

    const rect = this.viewport.getBoundingClientRect()
    const cx   = e.clientX - rect.left
    const cy   = e.clientY - rect.top

    const factor   = Math.exp(-e.deltaY * ZOOM_SPEED)
    const newScale = clamp(this.scale * factor, MIN_SCALE, MAX_SCALE)
    const ratio    = newScale / this.scale

    // Anchor the point under the cursor: solve for tx/ty so that
    //   (cx - tx_new) / newScale === (cx - tx_old) / scale_old
    this.tx    = cx - ratio * (cx - this.tx)
    this.ty    = cy - ratio * (cy - this.ty)
    this.scale = newScale

    this.clampPan()
    this.apply()
  }

  onMouseDown = (e) => {
    if (this.scale <= 1) return
    e.preventDefault()
    this.dragging   = true
    this.dragStartX = e.clientX - this.tx
    this.dragStartY = e.clientY - this.ty
    this.img.style.cursor = "grabbing"
  }

  onMouseMove = (e) => {
    if (!this.dragging) return
    e.preventDefault()
    this.tx = e.clientX - this.dragStartX
    this.ty = e.clientY - this.dragStartY
    this.clampPan()
    this.apply()
  }

  onMouseUp = () => {
    if (!this.dragging) return
    this.dragging = false
    this.img.style.cursor = this.scale > 1 ? "grab" : "zoom-in"
  }

  onDoubleClick = (e) => {
    e.preventDefault()
    this.scale = 1
    this.tx    = 0
    this.ty    = 0
    this.apply()
  }

  // Keep the image edges flush with the container — at scale s,
  // tx is in [w*(1-s), 0] and ty in [h*(1-s), 0].
  clampPan() {
    const w = this.viewport.clientWidth
    const h = this.viewport.clientHeight
    this.tx = Math.min(0, Math.max(w * (1 - this.scale), this.tx))
    this.ty = Math.min(0, Math.max(h * (1 - this.scale), this.ty))
  }

  apply() {
    this.img.style.transform = `translate(${this.tx}px, ${this.ty}px) scale(${this.scale})`
    this.img.style.cursor    = this.scale > 1 ? "grab" : "zoom-in"
  }

  // The displayed <img> requests a width-capped thumbnail (e.g. ?width=3840
  // on Wikimedia). If the loaded image's naturalWidth is less than that
  // cap, Wikimedia served the original — there's no higher-res version
  // to fetch, so hide the "load full quality" button. If it equals or
  // exceeds the cap, the image was downsized and the button is meaningful.
  #maybeRevealOriginalButton() {
    if (!this.hasOriginalButtonTarget) return
    if (!this.capWidthValue) return

    const reveal = () => {
      if (this.img.naturalWidth >= this.capWidthValue) {
        this.originalButtonTarget.classList.remove("hidden")
      }
    }
    if (this.img.complete && this.img.naturalWidth) {
      reveal()
    } else {
      this.img.addEventListener("load", reveal, { once: true })
    }
  }

  // Swap the <img>'s src to the full-resolution original URL passed in
  // via data-zoomable-url-param. Same DOM element, just a higher-res
  // bitmap — the current zoom state (scale + translation) persists
  // through the swap, so a player who has already zoomed in stays put.
  // Visual feedback: the trigger gets a "loading…" label and disables
  // until the image finishes loading.
  loadOriginal(event) {
    if (!this.img) return
    const url = event.params?.url
    if (!url || this.img.src === url) return

    const trigger = event.currentTarget
    const original_label = trigger.textContent
    trigger.textContent = "loading full quality…"
    trigger.disabled = true
    trigger.classList.add("opacity-60", "pointer-events-none")
    this.img.style.opacity = "0.55"

    const finish = (ok) => {
      this.img.style.opacity = ""
      this.img.removeEventListener("load",  onLoad)
      this.img.removeEventListener("error", onError)
      if (ok) {
        trigger.textContent = "full quality loaded ✓"
      } else {
        trigger.textContent = original_label
        trigger.disabled = false
        trigger.classList.remove("opacity-60", "pointer-events-none")
      }
    }
    const onLoad  = () => finish(true)
    const onError = () => finish(false)
    this.img.addEventListener("load",  onLoad)
    this.img.addEventListener("error", onError)
    this.img.src = url
  }
}

function clamp(v, min, max) {
  return Math.min(max, Math.max(min, v))
}
