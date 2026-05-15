import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "menu", "hamburger", "close", "toggleButton" ]

  connect() {
    this.#setOpen(false)
  }

  toggle() {
    this.#setOpen(this.menuTarget.hidden)
  }

  // Close when a nav link is clicked (Turbo visit keeps the menu open otherwise)
  close() {
    this.#setOpen(false)
  }

  closeOnEscape(event) {
    if (this.menuTarget.hidden) return
    event.preventDefault()
    this.#setOpen(false, { focusToggle: true })
  }

  closeOnOutside(event) {
    if (this.menuTarget.hidden) return
    if (!(event.target instanceof Element)) return
    if (this.element.contains(event.target)) return
    this.#setOpen(false, { focusToggle: true })
  }

  #setOpen(open, { focusToggle = false } = {}) {
    this.menuTarget.hidden = !open
    this.menuTarget.classList.toggle("hidden", !open)

    if (this.hasHamburgerTarget) this.hamburgerTarget.classList.toggle("hidden", open)
    if (this.hasCloseTarget) this.closeTarget.classList.toggle("hidden", !open)
    if (this.hasToggleButtonTarget) {
      this.toggleButtonTarget.setAttribute("aria-expanded", open ? "true" : "false")
    }

    if (open) this.#focusFirstMenuItem()
    if (!open && focusToggle && this.hasToggleButtonTarget) this.toggleButtonTarget.focus()
  }

  #focusFirstMenuItem() {
    const focusable = this.menuTarget.querySelector(
      "a[href], button:not([disabled]), [tabindex]:not([tabindex='-1'])"
    )
    focusable?.focus()
  }
}
