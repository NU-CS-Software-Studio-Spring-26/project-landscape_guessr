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

  // Friendly labels per sub-state. The fetching phase now uses
  // per-type fan-out (categories done / total) so we customize the
  // label when those numbers are present. Inserting phase still uses
  // (rows done / total).
  static stageLabels = {
    pending:           "Starting…",
    importing:         "Starting import…",
    looking_up_images: "Fetching photos from Wikipedia articles…",
    inserting:         "Importing images…",
  }

  #render(data) {
    const labels = this.constructor.stageLabels
    // fetching, looking_up_images, and inserting all advance per batch.
    const hasNumbers = (data.state === "fetching" && data.total > 0) ||
                       data.state === "looking_up_images" ||
                       data.state === "inserting"

    if (this.hasProgressTarget) this.progressTarget.textContent = data.progress
    if (this.hasTotalTarget)    this.totalTarget.textContent    = data.total || "?"
    // Drive the bar from whichever phase has real numerator/denominator
    // data: fetching (categories done), looking_up_images (titles done),
    // inserting (rows done).
    if (this.hasBarTarget && data.total > 0 &&
        ["fetching", "looking_up_images", "inserting"].includes(data.state)) {
      this.barTarget.value = data.progress
      this.barTarget.max   = data.total
    }
    const counter = this.element.querySelector("[data-counter]")
    if (counter) counter.classList.toggle("hidden", !hasNumbers)

    if (this.hasStatusTarget) {
      this.statusTarget.textContent = this.#labelFor(data, labels)
    }
  }

  // fetching gets a special label because the X/Y meaning is "8 of 14
  // categories done", not "8 of 14 images". Wording matters: "categories"
  // makes clear that we're fanning out across the AI's per-type queries.
  #labelFor(data, labels) {
    if (data.state === "fetching") {
      if (data.total > 0) {
        return `Fetching matching items from Wikidata (${data.progress} of ${data.total} categories done)…`
      }
      return "Fetching matching items from Wikidata…"
    }
    return labels[data.state] || data.state || ""
  }
}
