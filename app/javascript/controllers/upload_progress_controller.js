import { Controller } from "@hotwired/stimulus"

// Wraps an upload form: intercepts submit, shows an overlay with an
// upload-progress bar while the file uploads, then a spinner during
// server-side processing, then follows the redirect.
//
// Usage:
//   <%= form_with ..., data: { controller: "upload-progress" } do %>
//     ...
//   <% end %>
//
// Note on bulk uploads (multiple files): the browser-to-server upload
// progress (phase 1) covers ALL files combined; the server then
// processes them sequentially (libvips convert + S3 PUT each), so
// the "processing" phase can take minutes for large batches with no
// per-file progress signal. The rotating copy below is purely cosmetic.
export default class extends Controller {
  connect() {
    this.element.addEventListener("submit", this.#onSubmit.bind(this))
  }

  disconnect() {
    this.#removeOverlay()
  }

  #onSubmit(event) {
    event.preventDefault()
    const form = this.element
    const fileInputs = form.querySelectorAll('input[type="file"]')
    let fileCount = 0
    fileInputs.forEach((inp) => { fileCount += (inp.files ? inp.files.length : 0) })

    this.#showOverlay()
    this.#setStage("uploading", 0)
    this.fileCount = fileCount

    const xhr = new XMLHttpRequest()
    xhr.open(form.method.toUpperCase() || "POST", form.action)
    xhr.responseType = "text"

    xhr.upload.addEventListener("progress", (e) => {
      if (!e.lengthComputable) return
      const pct = Math.round((e.loaded / e.total) * 100)
      // Transition to processing as soon as bytes are done. We can't rely
      // on xhr.upload.load alone — for large bodies it can fire much later
      // than the last progress event, leaving the UI stuck at "100%".
      if (pct >= 100) {
        this.#setStage("processing", 100)
      } else {
        this.#setStage("uploading", pct)
      }
    })

    xhr.upload.addEventListener("load", () => {
      this.#setStage("processing", 100)
    })

    xhr.addEventListener("load", () => {
      window.location.href = xhr.responseURL || form.action
    })

    xhr.addEventListener("error", () => {
      this.#setStage("error")
    })

    xhr.send(new FormData(form))
  }

  #showOverlay() {
    if (this.overlay) return
    const overlay = document.createElement("div")
    overlay.className =
      "fixed inset-0 z-50 flex items-center justify-center bg-black/40"
    overlay.innerHTML = `
      <div class="bg-white rounded-lg shadow-lg p-6 w-full max-w-md space-y-4">
        <div class="flex items-center gap-3">
          <div data-target="spinner" class="w-5 h-5 rounded-full border-2 border-blue-600 border-t-transparent animate-spin hidden"></div>
          <p data-target="status" class="text-sm font-medium text-gray-800">Uploading…</p>
        </div>
        <div class="w-full h-2 rounded-full bg-gray-200 overflow-hidden">
          <div data-target="bar" class="h-full bg-blue-600 transition-all duration-150" style="width: 0%"></div>
        </div>
        <p data-target="hint" class="muted">This may take a moment for large images.</p>
      </div>
    `
    document.body.appendChild(overlay)
    this.overlay   = overlay
    this.statusEl  = overlay.querySelector('[data-target="status"]')
    this.barEl     = overlay.querySelector('[data-target="bar"]')
    this.hintEl    = overlay.querySelector('[data-target="hint"]')
    this.spinnerEl = overlay.querySelector('[data-target="spinner"]')
  }

  #setStage(stage, pct) {
    if (!this.overlay) return
    if (this.stage === stage && stage === "processing") return  // idempotent
    this.stage = stage
    if (stage === "uploading") {
      this.spinnerEl.classList.add("hidden")
      this.barEl.classList.remove("animate-pulse")
      this.statusEl.textContent = `Uploading… ${pct}%`
      this.barEl.style.width = `${pct}%`
      this.hintEl.textContent = "Sending file to server."
    } else if (stage === "processing") {
      this.spinnerEl.classList.remove("hidden")
      this.barEl.style.width = "100%"
      this.barEl.classList.add("animate-pulse")

      // No real progress signal during server-side processing + S3 upload,
      // so rotate optimistic copy. For bulk uploads include the count so
      // the user understands why it can take minutes.
      const n = this.fileCount || 1
      const eta = n > 5 ? ` (${n} images — this can take a few minutes)` : ""
      const stages = [
        { ms: 0,    status: "Processing image…",       hint: "Resizing and re-encoding to JPEG." + eta },
        { ms: 3000, status: "Uploading to storage…",   hint: "Sending the processed images to AWS S3." + eta },
        { ms: 12000, status: "Still working…",         hint: "Large bulk uploads can take a few minutes — please don't close this tab." }
      ]
      let i = 0
      const start = Date.now()
      const tick = () => {
        const elapsed = Date.now() - start
        while (i + 1 < stages.length && elapsed >= stages[i + 1].ms) i++
        this.statusEl.textContent = stages[i].status
        this.hintEl.textContent  = stages[i].hint
      }
      tick()
      this.processingTimer = setInterval(tick, 500)
    } else if (stage === "error") {
      this.spinnerEl.classList.add("hidden")
      this.statusEl.textContent = "Upload failed."
      this.barEl.classList.add("bg-red-500")
      this.hintEl.textContent = "Something went wrong. Try again or use a smaller file."
    }
  }

  #removeOverlay() {
    if (this.overlay) {
      this.overlay.remove()
      this.overlay = null
    }
    if (this.processingTimer) {
      clearInterval(this.processingTimer)
      this.processingTimer = null
    }
  }
}
