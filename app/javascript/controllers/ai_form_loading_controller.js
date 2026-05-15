import { Controller } from "@hotwired/stimulus"

// Disables the submit button on form submit so a slow double-click or
// stuck network can't fire a second /ai_generate POST (which would
// burn a second AI quota slot). Once the form posts, the controller
// at /ai_new redirects to ?generation_id=N and the poll banner takes
// over all in-flight UI — so this controller only has to cover the
// brief redirect window. No rotating "thinking" stages here; that
// belongs to ai_generation_poll_controller.
export default class extends Controller {
  static targets = ["submit"]

  submit(_event) {
    if (!this.hasSubmitTarget) return
    this.submitTarget.disabled = true
    this.submitTarget.setAttribute("aria-busy", "true")
  }
}
