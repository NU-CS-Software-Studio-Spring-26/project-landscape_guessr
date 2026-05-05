import { Controller } from "@hotwired/stimulus"

// Wraps a form whose file inputs use ActiveStorage `direct_upload: true`.
// Shows an overlay with a per-batch progress bar while files upload
// directly to S3, then a "submitting…" spinner while the form posts the
// blob signed-ids to Rails. After redirect, the locations page handles
// the "still processing on the server" state itself.
//
// We listen to the `direct-upload:*` events that ActiveStorage's JS
// dispatches per file, so we can show one combined progress bar across
// the whole batch (e.g. "uploading 23 / 91, 14%").
export default class extends Controller {
  connect() {
    this.totalCount = 0
    this.completedCount = 0
    this.totalBytes = 0
    this.loadedBytes = {}

    this.element.addEventListener("direct-upload:initialize", this.#onInit.bind(this))
    this.element.addEventListener("direct-upload:start", this.#onStart.bind(this))
    this.element.addEventListener("direct-upload:progress", this.#onProgress.bind(this))
    this.element.addEventListener("direct-upload:end", this.#onEnd.bind(this))
    this.element.addEventListener("submit", this.#onSubmit.bind(this))
  }

  disconnect() {
    this.#removeOverlay()
  }

  #onSubmit() {
    // Submit fires once at the start; AS then runs uploads and resubmits.
    // Show overlay early so the user sees something immediately.
    if (!this.overlay) this.#showOverlay()
  }

  #onInit(event) {
    // initialize fires upfront for *every* file (AS creates a
    // DirectUploadController for each before the sequential start
    // loop), so this is the right place to sum totalBytes — not
    // onStart, which fires one-by-one and would make the bar jump.
    this.totalCount += 1
    this.loadedBytes[event.detail.id] = 0
    if (event.detail.file && event.detail.file.size) {
      this.totalBytes += event.detail.file.size
    }
    this.#render()
  }

  #onStart() {
    this.#render()
  }

  #onProgress(event) {
    const { id, progress } = event.detail
    const file = event.detail.file
    if (file && file.size) {
      this.loadedBytes[id] = file.size * (progress / 100)
    }
    this.#render()
  }

  #onEnd(event) {
    this.completedCount += 1
    const file = event.detail.file
    if (file && file.size) this.loadedBytes[event.detail.id] = file.size
    this.#render()

    if (this.completedCount >= this.totalCount) {
      // All uploads done; AS will now resubmit the form. Switch the
      // overlay copy from "uploading" to "submitting".
      this.#setSubmitting()
    }
  }

  #showOverlay() {
    const overlay = document.createElement("div")
    overlay.className =
      "fixed inset-0 z-50 flex items-center justify-center bg-black/40"
    overlay.innerHTML = `
      <div class="bg-white rounded-lg shadow-lg p-6 w-full max-w-md space-y-4">
        <p data-target="status" class="text-sm font-medium text-gray-800">Preparing upload…</p>
        <div class="w-full h-2 rounded-full bg-gray-200 overflow-hidden">
          <div data-target="bar" class="h-full bg-blue-600 transition-all duration-150" style="width: 0%"></div>
        </div>
        <p data-target="hint" class="muted">Files upload straight to storage — large batches are fine.</p>
      </div>
    `
    document.body.appendChild(overlay)
    this.overlay  = overlay
    this.statusEl = overlay.querySelector('[data-target="status"]')
    this.barEl    = overlay.querySelector('[data-target="bar"]')
    this.hintEl   = overlay.querySelector('[data-target="hint"]')
  }

  #render() {
    if (!this.overlay) return
    const totalLoaded = Object.values(this.loadedBytes).reduce((a, b) => a + b, 0)
    const pct = this.totalBytes > 0 ? Math.min(100, Math.round((totalLoaded / this.totalBytes) * 100)) : 0
    this.barEl.style.width = `${pct}%`
    this.statusEl.textContent = `Uploading ${this.completedCount + 1} / ${this.totalCount}… ${pct}%`
  }

  #setSubmitting() {
    if (!this.overlay) return
    this.barEl.style.width = "100%"
    this.barEl.classList.add("animate-pulse")
    this.statusEl.textContent = "Saving…"
    this.hintEl.textContent = "Server is recording uploads — almost done."
  }

  #removeOverlay() {
    if (this.overlay) {
      this.overlay.remove()
      this.overlay = null
    }
  }
}
