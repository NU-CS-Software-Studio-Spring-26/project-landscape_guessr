import { Controller } from "@hotwired/stimulus"

// Live "n / max" counter for a text field with maxlength.
export default class extends Controller {
  static targets = ["input", "counter"]
  static values = { max: Number }

  connect() {
    this.boundClearForCache = this.update.bind(this)
    document.addEventListener("turbo:before-cache", this.boundClearForCache)
    this.update()
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.boundClearForCache)
  }

  update() {
    if (!this.hasInputTarget || !this.hasCounterTarget) return
    const len = this.inputTarget.value.length
    const max = this.maxValue
    this.counterTarget.textContent = `${len} / ${max}`
    this.counterTarget.classList.toggle("text-amber-700", len >= max - 20 && len < max)
    this.counterTarget.classList.toggle("text-red-600", len >= max)
    this.counterTarget.classList.toggle("text-forest-700", len < max - 20)
  }
}
