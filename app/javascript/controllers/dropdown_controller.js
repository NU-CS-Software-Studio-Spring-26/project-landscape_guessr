import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "trigger"]

  connect() {
    this.triggerTarget.setAttribute("aria-haspopup", "true")
    this.triggerTarget.setAttribute("aria-expanded", "false")
    this.menuTarget.setAttribute("role", "menu")
    this._outsideClick = this.#handleOutsideClick.bind(this)
    document.addEventListener("click", this._outsideClick)
  }

  disconnect() {
    document.removeEventListener("click", this._outsideClick)
  }

  toggle() {
    this.#isOpen() ? this.#close() : this.#open()
  }

  keydown(event) {
    if (event.key === "Escape" && this.#isOpen()) {
      event.preventDefault()
      this.#close()
      this.triggerTarget.focus()
    }
  }

  #open() {
    this.menuTarget.classList.remove("hidden")
    this.triggerTarget.setAttribute("aria-expanded", "true")
    // Move focus to the first focusable item in the panel
    const first = this.menuTarget.querySelector("a, button")
    first?.focus()
  }

  #close() {
    this.menuTarget.classList.add("hidden")
    this.triggerTarget.setAttribute("aria-expanded", "false")
  }

  #isOpen() {
    return !this.menuTarget.classList.contains("hidden")
  }

  #handleOutsideClick(event) {
    if (!this.element.contains(event.target)) {
      this.#close()
    }
  }
}
