import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tooltip"]

  show() { this.tooltipTarget.classList.remove("hidden") }
  hide() { this.tooltipTarget.classList.add("hidden") }
}
