import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["latitude", "longitude", "readout", "submit", "next", "result"]
  static values = { gamePath: String }

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
    const { lat, lng } = event.detail
    this.guessLat = lat
    this.guessLng = lng
    this.latitudeTarget.value = lat
    this.longitudeTarget.value = lng
    this.readoutTarget.textContent = `Pin: ${lat.toFixed(3)}, ${lng.toFixed(3)}`
    this.submitTarget.disabled = false
  }

  async submitGuess(event) {
    event.preventDefault()
    if (this.guessLat === null) return

    this.submitTarget.disabled = true

    const form = this.submitTarget.closest("form")
    const formData = new FormData(form)
    const body = {}
    formData.forEach((v, k) => {
      const match = k.match(/^guess\[(.+)\]$/)
      if (match) body[match[1]] = v
    })

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const response = await fetch(form.action + ".json", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token
      },
      body: JSON.stringify({ guess: body })
    })

    if (!response.ok) {
      this.readoutTarget.textContent = "Something went wrong. Please try again."
      this.readoutTarget.classList.add("text-red-600")
      this.submitTarget.disabled = false
      return
    }

    const data = await response.json()
    const answerLat = data.answer.latitude
    const answerLng = data.answer.longitude
    const km = this.#haversine(this.guessLat, this.guessLng, answerLat, answerLng)

    const mapCtrl = this.application.getControllerForElementAndIdentifier(
      this.element.querySelector("[data-controller='guess-map']"),
      "guess-map"
    )
    mapCtrl.showAnswer(answerLat, answerLng)

    this.submitTarget.classList.add("hidden")
    this.nextTarget.classList.remove("hidden")

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
    this.readoutTarget.classList.add("hidden")
  }

  nextRound() {
    window.location.href = this.gamePathValue
  }

  #boundKeydown

  #handleKeydown(event) {
    if (event.code !== "Space") return
    event.preventDefault()

    if (!this.submitTarget.classList.contains("hidden") && !this.submitTarget.disabled) {
      this.submitTarget.click()
    } else if (!this.nextTarget.classList.contains("hidden")) {
      this.nextRound()
    }
  }

  #haversine(lat1, lng1, lat2, lng2) {
    const R = 6371
    const toRad = (deg) => (deg * Math.PI) / 180
    const dLat = toRad(lat2 - lat1)
    const dLng = toRad(lng2 - lng1)
    const a =
      Math.sin(dLat / 2) ** 2 +
      Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  }
}
