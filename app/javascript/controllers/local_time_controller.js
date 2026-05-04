import { Controller } from "@hotwired/stimulus"

// Reformats a server-rendered <time datetime="..."> element into the
// user's local date. Falls back to the server-rendered text if the
// datetime attr is missing or unparseable.
export default class extends Controller {
  connect() {
    const dt = this.element.getAttribute("datetime")
    if (!dt) return
    const date = new Date(dt)
    if (isNaN(date)) return
    this.element.textContent = date.toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric"
    })
  }
}
