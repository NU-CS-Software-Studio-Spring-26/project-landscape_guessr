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
      document.addEventListener("click",   this.#closeOutside)
      document.addEventListener("keydown", this.#handleEsc)
    } else {
      document.removeEventListener("click",   this.#closeOutside)
      document.removeEventListener("keydown", this.#handleEsc)
    }
  }

  disconnect() {
    document.removeEventListener("click",   this.#closeOutside)
    document.removeEventListener("keydown", this.#handleEsc)
  }

  #closeOutside
  #handleEsc
}
