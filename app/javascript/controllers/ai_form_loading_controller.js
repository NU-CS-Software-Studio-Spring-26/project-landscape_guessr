import { Controller } from "@hotwired/stimulus"

// Shows a "Thinking..." indicator on form submit and disables the
// submit button. Lives on the AI-generate / AI-refine form on
// /image_sets/ai_new. Gemini calls take ~3-6s and Wikidata
// count+sample adds another ~1-2s, so without this the user just
// stares at a hung page.
//
// We disable on the JS-level `submit` event (which fires before the
// browser navigates), not on click — so re-clicking the submit button
// during the window between click and navigation doesn't fire a
// duplicate request.
export default class extends Controller {
  static targets = ["submit", "thinking"]

  // Plausible-sounding stages we cycle through while the AI works.
  // We DON'T actually know which stage Gemini is in — the API isn't
  // streamed — but for a 5-15s wait, rotating text gives the user
  // something to watch and signals real progress. Order ~tracks the
  // backend's typical work pattern (search → inspect → compose).
  static stages = [
    "Looking up Wikidata IDs…",
    "Verifying the data shape…",
    "Composing the SPARQL query…",
    "Almost there…",
  ]
  static stageInterval = 3500 // ms — slow enough to read, fast enough not to stall

  submit() {
    // Disable but don't relabel — the standalone spinner span is the
    // visible loading indicator. Earlier version did both, which left
    // "Thinking…" duplicated next to a "Thinking…" button.
    if (this.hasSubmitTarget) this.submitTarget.disabled = true
    if (this.hasThinkingTarget) this.thinkingTarget.classList.remove("hidden")
    this.#startStageRotation()
  }

  disconnect() { if (this.stageTimer) clearInterval(this.stageTimer) }

  #startStageRotation() {
    const label = this.element.querySelector("[data-thinking-label]")
    if (!label) return
    const stages = this.constructor.stages
    let i = 0
    label.textContent = stages[i]
    this.stageTimer = setInterval(() => {
      i = Math.min(i + 1, stages.length - 1) // stick on "Almost there…" once we hit the last
      label.textContent = stages[i]
    }, this.constructor.stageInterval)
  }
}
