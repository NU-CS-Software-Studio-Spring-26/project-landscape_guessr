import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["latitude", "longitude", "readout", "submit"]

  connect() {
    this.#boundKeydown = this.#handleKeydown.bind(this)
    document.addEventListener("keydown", this.#boundKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.#boundKeydown)
  }

  pinChanged(event) {
    const { lat, lng } = event.detail
    this.latitudeTarget.value = lat
    this.longitudeTarget.value = lng
    this.readoutTarget.textContent = `Pin: ${lat.toFixed(3)}, ${lng.toFixed(3)}`
    this.submitTarget.disabled = false
  }

  #boundKeydown

  #handleKeydown(event) {
    if (event.code !== "Space") return
    if (this.submitTarget.disabled) return
    event.preventDefault()
    this.submitTarget.click()
  }
}
