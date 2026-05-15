import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "menu", "hamburger", "close" ]

  toggle() {
    const open = this.menuTarget.classList.toggle("hidden") === false
    if (this.hasHamburgerTarget) this.hamburgerTarget.classList.toggle("hidden", open)
    if (this.hasCloseTarget)     this.closeTarget.classList.toggle("hidden", !open)
  }

  // Close when a nav link is clicked (Turbo visit keeps the menu open otherwise)
  close() {
    this.menuTarget.classList.add("hidden")
    if (this.hasHamburgerTarget) this.hamburgerTarget.classList.remove("hidden")
    if (this.hasCloseTarget)     this.closeTarget.classList.add("hidden")
  }
}
