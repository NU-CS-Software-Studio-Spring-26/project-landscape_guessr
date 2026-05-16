import { Controller } from "@hotwired/stimulus"

// Polls the AI-generation status endpoint while AiGenerationJob runs.
// Reloads the page once the job reports completed/failed so the
// server can render the full result card (preview, import form, etc.)
// instead of trying to assemble it from JSON on the client.
//
// Mirrors ai_import_poll_controller. Shared shape so both ai-import
// and ai-generation polling stay easy to reason about side by side.
export default class extends Controller {
  static values = {
    url:        String,
    interval:   { type: Number, default: 1500 },
    maxErrors:  { type: Number, default: 5 },
  }
  static targets = ["status"]

  // Per-phase labels are the FALLBACK shown when the server hasn't yet
  // set progress_message. progress_message ("Searching Wikidata for
  // 'volcano'…") is the AI's live tool call — preferred when available.
  // status is the lifecycle (pending/running/completed/failed); phase
  // is finer-grained. For the sampling phase we also tack the count
  // onto the label so the user sees "Found N matches" as soon as the
  // counting phase finishes — much more informative than spinning
  // anonymously through the 30-60s sample.
  static stageLabels = {
    pending:   "Starting…",
    thinking:  "Thinking…",
    counting:  "Counting matches in Wikidata…",
    sampling:  "Loading preview images…",
  }

  connect() {
    this.errorCount = 0
    this.#schedule(0)
  }
  disconnect() { if (this.timer) clearTimeout(this.timer) }

  #schedule(delay) { this.timer = setTimeout(() => this.#poll(), delay) }

  async #poll() {
    try {
      // no-store keeps the browser cache out of the polling loop —
      // some browsers will return cached JSON for a repeat GET to the
      // same URL otherwise, which would make the UI appear frozen.
      const res = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        cache:   "no-store",
      })
      if (!res.ok) throw new Error("HTTP " + res.status)
      const data = await res.json()
      this.errorCount = 0
      this.#render(data)

      // Terminal states: hand off to a full server-side render so the
      // user sees the right card (result / failure / canceled) for
      // whatever happened.
      if (data.status === "completed" || data.status === "failed" || data.status === "canceled") {
        window.location.reload()
        return
      }
    } catch (e) {
      this.errorCount++
      console.warn("[ai-generation-poll]", e, `(error ${this.errorCount}/${this.maxErrorsValue})`)
      // Bail after too many consecutive errors so we don't hammer a
      // 404'd endpoint forever. Reloading shows whatever the server
      // renders for the page now (e.g. the fresh form if the record
      // got deleted, or a failure card from the stale? check).
      if (this.errorCount >= this.maxErrorsValue) {
        window.location.reload()
        return
      }
    }
    this.#schedule(this.intervalValue)
  }

  #render(data) {
    if (!this.hasStatusTarget) return
    let label =
      data.progress_message ||
      this.constructor.stageLabels[data.phase] ||
      this.constructor.stageLabels[data.status] ||
      "Working…"
    // Once we know the count, append it to the sampling-phase label
    // so the user has a real number to react to.
    if (data.phase === "sampling" && typeof data.result_count === "number") {
      label = `Found ${data.result_count.toLocaleString()} match${data.result_count === 1 ? "" : "es"} — loading preview images…`
    }
    this.statusTarget.textContent = label
  }
}
