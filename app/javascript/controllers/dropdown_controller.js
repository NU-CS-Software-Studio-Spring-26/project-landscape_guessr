import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "menu", "label", "input" ]
  static values  = { open: { type: Boolean, default: false } }

  connect() {
    this.#closeOutside = (e) => { if (!this.element.contains(e.target)) this.close() }
    this.#handleEsc    = (e) => { if (e.key === "Escape") this.close() }
  }

  toggle() { this.openValue = !this.openValue }
  close()  { this.openValue = false }

  pick(event) {
    const { url, value, label } = event.currentTarget.dataset
    if (this.hasLabelTarget && label) this.labelTarget.textContent = label
    this.close()
    if (url)   Turbo.visit(url)
    else if (value && this.hasInputTarget) this.inputTarget.value = value
  }

  openValueChanged() {
    if (!this.hasMenuTarget) return
    this.menuTarget.classList.toggle("hidden", !this.openValue)
    if (this.openValue) {
      if (this.menuTarget.classList.contains("fixed")) this.#anchorMenuToTrigger()
      document.addEventListener("click",   this.#closeOutside)
      document.addEventListener("keydown", this.#handleEsc)
    } else {
      document.removeEventListener("click",   this.#closeOutside)
      document.removeEventListener("keydown", this.#handleEsc)
    }
  }

  // For menus marked `fixed` in their classes (used where the menu would
  // otherwise be clipped by a scrollable ancestor): anchor the menu's
  // bottom-left corner directly to the trigger button's bottom-right corner,
  // using `bottom`/`left` so the box grows up-and-right from that corner.
  // This only reads the trigger's rect — the trigger itself never moves, and
  // there's no need to measure or center the menu.
  #anchorMenuToTrigger() {
    const trigger = this.element.querySelector("button")
    if (!trigger) return

    const rect = trigger.getBoundingClientRect()
    const gap = 8

    Object.assign(this.menuTarget.style, {
      top: "auto",
      right: "auto",
      bottom: `${window.innerHeight - rect.bottom}px`,
      left: `${rect.right + gap}px`
    })
  }

  disconnect() {
    document.removeEventListener("click",   this.#closeOutside)
    document.removeEventListener("keydown", this.#handleEsc)
  }

  #closeOutside
  #handleEsc
}
