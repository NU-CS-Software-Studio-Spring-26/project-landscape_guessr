import { Controller } from "@hotwired/stimulus"

// Disables the submit button on form submit so a slow double-click or
// stuck network can't fire a second /ai_generate POST (which would
// burn a second AI quota slot). Once the form posts, the controller
// at /ai_new redirects to ?generation_id=N and the poll banner takes
// over all in-flight UI — so this controller only has to cover the
// brief redirect window. No rotating "thinking" stages here; that
// belongs to ai_generation_poll_controller.
//
// Also resets the prompt textarea before Turbo caches the page on
// navigation. Without this, typed-but-unsubmitted text persists in
// the snapshot and reappears when the user navigates back to /ai_new.
// The server always renders value="" so resetting to defaultValue
// matches the fresh-render state.
export default class extends Controller {
  static targets = ["submit"]

  connect() {
    this.boundClearForCache = this.#clearForCache.bind(this)
    document.addEventListener("turbo:before-cache", this.boundClearForCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.boundClearForCache)
  }

  submit(_event) {
    if (!this.hasSubmitTarget) return
    this.submitTarget.disabled = true
    this.submitTarget.setAttribute("aria-busy", "true")
    // DON'T reset textareas here. The browser collects form data AFTER
    // the submit-event handler chain, so a synchronous reset blanks
    // the values the browser then sends — server gets user_message=""
    // and rejects with "type a prompt first." Cache cleanup happens
    // later via turbo:before-cache.
  }

  #clearForCache() {
    this.element.querySelectorAll("textarea, input[type='text']").forEach((el) => {
      el.value = el.defaultValue
    })
  }
}
