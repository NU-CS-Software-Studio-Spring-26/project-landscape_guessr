import { Controller } from "@hotwired/stimulus"

// Warn the user if they navigate away from a form with unsaved edits.
// Used on the image_sets/locations bulk-edit page, where pagination
// (prev/next/per-page) and other links would otherwise silently discard
// title/lat/lng changes.
//
// Tracks dirtiness on input/change so genuinely-untouched pages don't
// nag. Both turbo:before-visit (Turbo Drive navigations) and
// beforeunload (full reloads, tab close) are handled.
export default class extends Controller {
  static values = { message: { type: String, default: "You have unsaved changes. Leave anyway?" } }

  connect() {
    this.dirty = false
    this.onInput        = this.onInput.bind(this)
    this.onSubmit       = this.onSubmit.bind(this)
    this.onBeforeVisit  = this.onBeforeVisit.bind(this)
    this.onBeforeUnload = this.onBeforeUnload.bind(this)

    this.element.addEventListener("input",  this.onInput)
    this.element.addEventListener("change", this.onInput)
    this.element.addEventListener("submit", this.onSubmit)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    window.addEventListener("beforeunload",         this.onBeforeUnload)
  }

  disconnect() {
    this.element.removeEventListener("input",  this.onInput)
    this.element.removeEventListener("change", this.onInput)
    this.element.removeEventListener("submit", this.onSubmit)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    window.removeEventListener("beforeunload",         this.onBeforeUnload)
  }

  onInput()  { this.dirty = true }
  onSubmit() { this.dirty = false }

  onBeforeVisit(event) {
    if (this.dirty && !window.confirm(this.messageValue)) {
      event.preventDefault()
    }
  }

  onBeforeUnload(event) {
    if (this.dirty) {
      event.preventDefault()
      // Most browsers ignore custom strings now and show their own prompt,
      // but assigning returnValue is still required to trigger it.
      event.returnValue = ""
    }
  }
}
