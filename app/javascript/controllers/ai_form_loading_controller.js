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
  // streamed back to us — but for a 5-15s wait, rotating text signals
  // real progress. Order ~tracks the backend's typical work pattern
  // (the model thinks first, then searches for Q-IDs, then composes).
  static stages = [
    "Thinking…",
    "Looking up Wikidata IDs…",
    "Verifying the data shape…",
    "Composing the SPARQL query…",
    "Still thinking…",
  ]
  static stageInterval = 5000 // ms — slow enough to actually read

  submit(event) {
    this.#lock(event?.submitter)
    if (this.hasThinkingTarget) this.thinkingTarget.classList.remove("hidden")
    this.#startStageRotation()
  }

  // Also bind to the submit-button's click as a backup. If the submit
  // event somehow misfires (Stimulus reconnect, double-click race), the
  // click handler still locks the form before the page navigates.
  click(event) {
    this.#lock(event.currentTarget)
  }

  disconnect() { if (this.stageTimer) clearInterval(this.stageTimer) }

  #lock(submitter) {
    // Disable the submit target. Don't relabel — the standalone spinner
    // span is the visible loading indicator. Earlier version replaced
    // the button text with "Thinking…", which duplicated the span.
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = true
      this.submitTarget.setAttribute("aria-busy", "true")
    }
    // Belt-and-suspenders: if the click came from a different button
    // than our declared target (e.g. Stimulus targets out of sync after
    // a turbo refresh), disable the actual submitter too.
    if (submitter && submitter !== this.submitTarget) submitter.disabled = true
  }

  #startStageRotation() {
    const label = this.element.querySelector("[data-thinking-label]")
    if (!label) return
    const stages = this.constructor.stages
    let i = 0
    label.textContent = stages[i]
    this.stageTimer = setInterval(() => {
      i = Math.min(i + 1, stages.length - 1) // stick on the last label after we run out
      label.textContent = stages[i]
    }, this.constructor.stageInterval)
  }
}
