import { Controller } from "@hotwired/stimulus"

// Polls the AI-import status endpoint while the AiImportImagesJob is
// running. Updates a progress bar + count, and reloads the page once
// the job reports state="completed" (or "failed") so the user sees the
// imported images + the standard image-set show layout.
//
// HTML wiring:
//   <div data-controller="ai-import-poll"
//        data-ai-import-poll-url-value="<%= import_status_image_set_path(set) %>">
//     <progress data-ai-import-poll-target="bar" value="0" max="100"></progress>
//     <span    data-ai-import-poll-target="status">starting...</span>
//   </div>
export default class extends Controller {
  static values = {
    url:      String,
    interval: { type: Number, default: 2500 },
  }
  static targets = ["bar", "status", "progress", "total"]

  connect() { this.#schedule(0) }

  disconnect() { if (this.timer) clearTimeout(this.timer) }

  #schedule(delay) {
    this.timer = setTimeout(() => this.#poll(), delay)
  }

  async #poll() {
    try {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (!res.ok) throw new Error("HTTP " + res.status)
      const data = await res.json()
      this.#render(data)

      // Reload once when the job leaves the importing state so the rest
      // of the page (image gallery, action buttons) re-renders from
      // post-import server state. Both completed and failed reload so
      // the user sees the failure banner.
      if (data.state === "completed" || data.state === "failed") {
        window.location.reload()
        return
      }
    } catch (e) {
      console.warn("[ai-import-poll]", e)
    }
    this.#schedule(this.intervalValue)
  }

  // Friendly labels for each sub-state of the import pipeline. The
  // importer sets these in WikidataImporter#import!; see comment there
  // for what each phase actually does. Until we have a numeric total
  // (i.e. until we hit the "inserting" phase), we hide the X/Y counter
  // since it'd just sit on "0 / ?" and look stuck.
  static stageLabels = {
    pending:           "Starting…",
    importing:         "Starting import…",
    fetching:          "Fetching matching items from Wikidata (this can take 30-60 seconds for broad sets)…",
    looking_up_images: "Fetching photos from Wikipedia articles…",
    inserting:         "Importing images…",
  }

  #render(data) {
    const labels = this.constructor.stageLabels
    const hasNumbers = data.total > 0 || data.state === "inserting"

    if (this.hasProgressTarget) this.progressTarget.textContent = data.progress
    if (this.hasTotalTarget)    this.totalTarget.textContent    = data.total || "?"
    if (this.hasBarTarget && data.total > 0) {
      this.barTarget.value = data.progress
      this.barTarget.max   = data.total
    }
    // Toggle the "(0 / ?)" counter visibility — hide it during the
    // pre-insert phases when we don't have meaningful numbers yet.
    const counter = this.element.querySelector("[data-counter]")
    if (counter) counter.classList.toggle("hidden", !hasNumbers)

    if (this.hasStatusTarget) {
      this.statusTarget.textContent = labels[data.state] || data.state || ""
    }
  }
}
