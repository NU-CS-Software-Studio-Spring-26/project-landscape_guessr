import { Controller } from "@hotwired/stimulus"
import { DirectUpload } from "@rails/activestorage"

// Resilient bulk-upload flow:
//   1. Browser uploads each file directly to S3 via AS DirectUpload.
//   2. As soon as a single upload finishes, we POST its blob signed-id
//      to the per-set attach_blob endpoint, which creates the Image,
//      attaches the blob, and enqueues ProcessImageJob.
//   3. Failed uploads retry once; if still failing they're flagged in
//      the overlay's failure count and the batch continues with the
//      next file rather than halting (which is what AS's auto-bind
//      DirectUploadsController does — it stops on the first error).
//
// Tab-close safety: because step 2 happens per file rather than after
// the whole batch, anything already uploaded is persisted server-side
// regardless of what happens to the rest of the batch.
//
// Required values on the wrapping <form>:
//   data-direct-upload-attach-url-value="<%= attach_blob_image_set_path(set) %>"
//   data-direct-upload-direct-upload-url-value="<%= rails_direct_uploads_url %>"
//   data-direct-upload-redirect-url-value="<%= locations_image_set_path(set) %>"
export default class extends Controller {
  static values = {
    attachUrl: String,
    directUploadUrl: String,
    redirectUrl: String,
  }

  connect() {
    this.element.addEventListener("submit", this.#onSubmit.bind(this))
  }

  async #onSubmit(event) {
    event.preventDefault()

    const fileInput = this.element.querySelector('input[type="file"]')
    const files = Array.from(fileInput?.files || [])
    if (files.length === 0) return

    this.totalCount     = files.length
    this.totalBytes     = files.reduce((s, f) => s + f.size, 0)
    this.completedCount = 0
    this.failedCount    = 0
    this.failedNames    = []
    this.currentLoaded  = 0
    this.currentSize    = 0

    this.#showOverlay()

    for (let i = 0; i < files.length; i++) {
      const file = files[i]
      this.currentSize   = file.size
      this.currentLoaded = 0
      this.#renderProgress(file.name, i + 1)

      const ok = await this.#uploadOneWithRetry(file)
      if (ok) this.completedCount += 1
      else {
        this.failedCount += 1
        this.failedNames.push(file.name)
      }
    }

    this.#renderDone()
    // Give the user a moment to see the result, then reload the
    // locations page so newly-attached items + processing placeholders
    // appear.
    setTimeout(() => { window.location.href = this.redirectUrlValue },
      this.failedCount > 0 ? 4000 : 800)
  }

  async #uploadOneWithRetry(file) {
    try {
      return await this.#uploadOne(file)
    } catch (e1) {
      console.warn(`[direct-upload] retrying ${file.name} after error:`, e1)
      try {
        return await this.#uploadOne(file)
      } catch (e2) {
        console.error(`[direct-upload] giving up on ${file.name}:`, e2)
        return false
      }
    }
  }

  // Returns true on success, throws on failure.
  #uploadOne(file) {
    return new Promise((resolve, reject) => {
      const upload = new DirectUpload(file, this.directUploadUrlValue, this)
      upload.create(async (error, blob) => {
        if (error) return reject(new Error(error))
        try {
          await this.#attachBlob(blob.signed_id)
          resolve(true)
        } catch (attachErr) {
          reject(attachErr)
        }
      })
    })
  }

  async #attachBlob(signedId) {
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content
    const res = await fetch(this.attachUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token":  csrf,
        "Accept":        "application/json",
      },
      body: JSON.stringify({ signed_id: signedId }),
    })
    if (!res.ok) throw new Error(`attach_blob HTTP ${res.status}`)
    return res.json()
  }

  // DirectUpload delegate: gets called with the XHR mid-upload so we
  // can hook into per-file byte progress and feed it into the overall
  // progress bar.
  directUploadWillStoreFileWithXHR(request) {
    request.upload.addEventListener("progress", (e) => {
      if (e.lengthComputable) {
        this.currentLoaded = e.loaded
        this.#renderProgress(this.currentFilename, this.completedCount + this.failedCount + 1)
      }
    })
  }

  #showOverlay() {
    const overlay = document.createElement("div")
    overlay.className = "fixed inset-0 z-50 flex items-center justify-center bg-black/40"
    overlay.innerHTML = `
      <div class="bg-white rounded-lg shadow-lg p-6 w-full max-w-md space-y-4">
        <p data-target="status" class="text-sm font-medium text-gray-800">Preparing upload…</p>
        <div class="w-full h-2 rounded-full bg-gray-200 overflow-hidden">
          <div data-target="bar" class="h-full bg-blue-600 transition-all duration-150" style="width: 0%"></div>
        </div>
        <p data-target="hint" class="muted">Files upload straight to storage and are attached one-by-one — anything that finishes is safe even if the tab closes.</p>
      </div>
    `
    document.body.appendChild(overlay)
    this.overlay  = overlay
    this.statusEl = overlay.querySelector('[data-target="status"]')
    this.barEl    = overlay.querySelector('[data-target="bar"]')
    this.hintEl   = overlay.querySelector('[data-target="hint"]')
  }

  #renderProgress(filename, currentIndex) {
    if (!this.overlay) return
    this.currentFilename = filename
    const finishedBytes = this.#finishedBytes()
    const loadedBytes   = finishedBytes + this.currentLoaded
    const pct = this.totalBytes > 0 ? Math.min(100, Math.round((loadedBytes / this.totalBytes) * 100)) : 0
    this.barEl.style.width = `${pct}%`
    const failNote = this.failedCount > 0 ? `, ${this.failedCount} failed` : ""
    this.statusEl.textContent = `Uploading ${currentIndex} / ${this.totalCount}${failNote} — ${pct}%`
  }

  #finishedBytes() {
    // Approximate: each finished file contributes its full size; we
    // don't track per-file size after completion, but for a uniform
    // batch this is close enough.
    if (this.totalCount === 0) return 0
    const avgSize = this.totalBytes / this.totalCount
    return (this.completedCount + this.failedCount) * avgSize
  }

  #renderDone() {
    if (!this.overlay) return
    this.barEl.style.width = "100%"
    if (this.failedCount === 0) {
      this.statusEl.textContent = `Done — ${this.completedCount} / ${this.totalCount} uploaded.`
      this.hintEl.textContent = "Reloading…"
    } else {
      this.barEl.classList.add("bg-amber-500")
      this.statusEl.textContent = `${this.completedCount} succeeded, ${this.failedCount} failed.`
      const sample = this.failedNames.slice(0, 3).join(", ") + (this.failedNames.length > 3 ? "…" : "")
      this.hintEl.textContent = `Failed: ${sample}. Successful uploads have been added to the set; you can re-pick the failed files and try again.`
    }
  }
}
