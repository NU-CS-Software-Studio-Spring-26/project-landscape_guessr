import { Controller } from "@hotwired/stimulus"

// Wraps an upload form: intercepts submit, shows an overlay with an
// upload-progress bar while the file uploads, then a spinner during
// server-side processing, then follows the redirect.
//
// Usage:
//   <%= form_with ..., data: { controller: "upload-progress" } do %>
//     ...
//   <% end %>
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

    this.#showOverlay()
    this.#setStage("uploading", 0)

    const xhr = new XMLHttpRequest()
    xhr.open(form.method.toUpperCase() || "POST", form.action)
    xhr.responseType = "text"

    xhr.upload.addEventListener("progress", (e) => {
      if (e.lengthComputable) {
        const pct = Math.round((e.loaded / e.total) * 100)
        this.#setStage("uploading", pct)
      }
    })

    xhr.upload.addEventListener("load", () => {
      // Upload bytes done; server is now processing (resize/convert).
      this.#setStage("processing", 100)
    })

    xhr.addEventListener("load", () => {
      // Rails redirects to the destination URL on success — XHR follows
      // automatically and exposes the final URL via responseURL.
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
      <div class="bg-white rounded-lg shadow-lg p-6 w-full max-w-sm space-y-4">
        <p data-target="status" class="text-sm font-medium text-gray-800">Uploading…</p>
        <div class="w-full h-2 rounded-full bg-gray-200 overflow-hidden">
          <div data-target="bar" class="h-full bg-blue-600 transition-all duration-150" style="width: 0%"></div>
        </div>
        <p data-target="hint" class="muted">This may take a moment for large images.</p>
      </div>
    `
    document.body.appendChild(overlay)
    this.overlay = overlay
    this.statusEl = overlay.querySelector('[data-target="status"]')
    this.barEl    = overlay.querySelector('[data-target="bar"]')
    this.hintEl   = overlay.querySelector('[data-target="hint"]')
  }

  #setStage(stage, pct) {
    if (!this.overlay) return
    if (stage === "uploading") {
      this.statusEl.textContent = `Uploading… ${pct}%`
      this.barEl.style.width = `${pct}%`
      this.hintEl.textContent = "Sending file to server."
    } else if (stage === "processing") {
      this.statusEl.textContent = "Processing image…"
      this.barEl.style.width = "100%"
      this.barEl.classList.add("animate-pulse")
      this.hintEl.textContent = "Resizing and re-encoding. This can take a few seconds for HEIC or large files."
    } else if (stage === "error") {
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
  }
}
