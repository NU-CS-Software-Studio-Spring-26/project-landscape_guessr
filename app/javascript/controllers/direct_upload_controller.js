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

  disconnect() {
    this.#removeBeforeUnloadGuard()
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
    // upload.id -> bytes loaded. Entries are added when an upload
    // starts, grow on progress, and are PINNED at file.size when the
    // upload completes. We never decrement or delete entries — that's
    // what makes the rendered total strictly non-decreasing.
    this.inflight       = new Map()

    // Guard against accidental reload/navigation while uploads are in
    // flight. Without this, every reload spawns a fresh batch of
    // attach_blob calls (the in-flight ones may still complete server-
    // side), creating duplicate Image rows in the set.
    this.#installBeforeUnloadGuard()

    this.#showOverlay()

    // Run a small worker pool over the file list. Concurrency=2 strikes
    // a balance: uploads benefit from a second connection (saves ~250ms
    // per-file attach_blob round-trip overlap), but we don't pile up so
    // many ProcessImageJobs that the dyno's :async pool OOMs decoding
    // multiple HEICs at once.
    const concurrency = 2
    let nextIndex = 0
    const worker = async () => {
      while (true) {
        const i = nextIndex++
        if (i >= files.length) return
        const file = files[i]
        const ok = await this.#uploadOneWithRetry(file)
        if (ok) this.completedCount += 1
        else {
          this.failedCount += 1
          this.failedNames.push(file.name)
        }
        this.#renderProgress()
      }
    }
    await Promise.all(Array.from({ length: concurrency }, worker))

    // Remove the guard *before* triggering our own navigation, otherwise
    // the redirect would itself fire the "are you sure?" dialog.
    this.#removeBeforeUnloadGuard()

    this.#renderDone()
    setTimeout(() => { window.location.href = this.redirectUrlValue },
      this.failedCount > 0 ? 4000 : 800)
  }

  #installBeforeUnloadGuard() {
    this.beforeUnloadHandler = (e) => {
      // Modern browsers ignore custom strings here and show a generic
      // "Leave site?" dialog, but we still need to set returnValue (or
      // call preventDefault) for the dialog to appear at all.
      e.preventDefault()
      e.returnValue = ""
    }
    window.addEventListener("beforeunload", this.beforeUnloadHandler)
  }

  #removeBeforeUnloadGuard() {
    if (this.beforeUnloadHandler) {
      window.removeEventListener("beforeunload", this.beforeUnloadHandler)
      this.beforeUnloadHandler = null
    }
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

  // Returns true on success, throws on failure. Uses a per-upload
  // delegate so we can track each in-flight file's loaded bytes
  // independently — needed for an accurate progress bar when
  // concurrency > 1.
  //
  // Inflight bookkeeping: we set the entry to 0 on start, grow it on
  // progress events, and pin it to file.size on completion. We never
  // delete or decrement — so even while we await attach_blob, the bar
  // doesn't dip from another worker's render seeing a "missing"
  // upload.
  #uploadOne(file) {
    return new Promise((resolve, reject) => {
      const delegate = {
        directUploadWillStoreFileWithXHR: (xhr) => {
          const id = upload.id
          this.inflight.set(id, 0)
          xhr.upload.addEventListener("progress", (e) => {
            if (e.lengthComputable) {
              this.inflight.set(id, e.loaded)
              this.#renderProgress()
            }
          })
        },
      }
      const upload = new DirectUpload(file, this.directUploadUrlValue, delegate)
      upload.create(async (error, blob) => {
        if (error) return reject(new Error(error))
        // Pin at full size for monotonic progress, then await the
        // (much smaller) attach_blob round-trip without holding up
        // the bar from advancing.
        this.inflight.set(upload.id, file.size)
        this.#renderProgress()
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

  #renderProgress() {
    if (!this.overlay) return
    // Bar = sum of loaded bytes across every upload we've ever started.
    // Each entry only grows or stays the same (pinned at file.size on
    // completion, never deleted), so the total is monotonically
    // non-decreasing across the whole batch.
    let loaded = 0
    for (const v of this.inflight.values()) loaded += v
    const pct = this.totalBytes > 0 ? Math.min(100, Math.round((loaded / this.totalBytes) * 100)) : 0
    this.barEl.style.width = `${pct}%`
    const done = this.completedCount + this.failedCount
    const failNote = this.failedCount > 0 ? `, ${this.failedCount} failed` : ""
    this.statusEl.textContent = `Uploading ${Math.min(done + 1, this.totalCount)} / ${this.totalCount}${failNote} — ${pct}%`
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
