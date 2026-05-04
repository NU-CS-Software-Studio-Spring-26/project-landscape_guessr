import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["guessBtn", "nextBtn", "result", "imageLink"]
  static values = { imageId: Number, checkUrl: String }
  #boundKeydown

  connect() {
    this.guessLat = null
    this.guessLng = null
    this.#boundKeydown = this.#handleKeydown.bind(this)
    document.addEventListener("keydown", this.#boundKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.#boundKeydown)
  }

  pinChanged(event) {
    this.guessLat = event.detail.lat
    this.guessLng = event.detail.lng
    this.guessBtnTarget.disabled = false
  }

  async submitGuess() {
    if (this.guessLat === null) return
    this.guessBtnTarget.disabled = true

    const url = `${this.checkUrlValue}?image_id=${this.imageIdValue}&lat=${this.guessLat}&lng=${this.guessLng}`
    const res = await fetch(url, { headers: { "Accept": "application/json" } })
    if (!res.ok) {
      this.resultTarget.textContent = "Couldn't check guess. Try again."
      this.resultTarget.className = "text-lg font-medium text-red-600"
      this.guessBtnTarget.disabled = false
      return
    }
    const { answer_lat, answer_lng, distance_km: km } = await res.json()

    const mapCtrl = this.application.getControllerForElementAndIdentifier(
      this.element.querySelector("[data-controller='guess-map']"),
      "guess-map"
    )
    mapCtrl.showAnswer(answer_lat, answer_lng)

    this.guessBtnTarget.classList.add("hidden")
    this.nextBtnTarget.classList.remove("hidden")
    this.imageLinkTarget.classList.remove("hidden")

    let text, color
    if (km < 50) {
      text = `${Math.round(km)} km away — Excellent!`
      color = "text-green-600"
    } else if (km < 300) {
      text = `${Math.round(km)} km away — Great!`
      color = "text-green-600"
    } else if (km < 1000) {
      text = `${Math.round(km)} km away — Not bad!`
      color = "text-yellow-600"
    } else {
      text = `${Math.round(km).toLocaleString()} km away`
      color = "text-red-600"
    }

    this.resultTarget.textContent = text
    this.resultTarget.className = `text-lg font-medium ${color}`
  }

  next() {
    window.location.reload()
  }

  #handleKeydown(event) {
    if (event.code !== "Space") return
    event.preventDefault()

    if (!this.guessBtnTarget.classList.contains("hidden") && !this.guessBtnTarget.disabled) {
      this.submitGuess()
    } else if (!this.nextBtnTarget.classList.contains("hidden")) {
      this.next()
    }
  }
}
