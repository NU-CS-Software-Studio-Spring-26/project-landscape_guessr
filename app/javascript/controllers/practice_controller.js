import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["guessBtn", "nextBtn", "result", "imageLink", "timer"]
  static values = {
    imageId: Number,
    checkUrl: String,
    timeLimit: { type: Number, default: 0 }
  }

  #boundKeydown
  #timerInterval

  connect() {
    this.guessLat = null
    this.guessLng = null
    this.submitted = false
    this.#boundKeydown = this.#handleKeydown.bind(this)
    document.addEventListener("keydown", this.#boundKeydown)

    if (this.timeLimitValue > 0) this.#startTimer()
  }

  disconnect() {
    document.removeEventListener("keydown", this.#boundKeydown)
    this.#clearTimer()
  }

  pinChanged(event) {
    this.guessLat = event.detail.lat
    this.guessLng = event.detail.lng
    if (this.submitted) return
    this.guessBtnTarget.disabled = false
  }

  async submitGuess(event) {
    if (event?.preventDefault) event.preventDefault()
    if (this.submitted || this.guessLat === null) return

    await this.#resolveGuess({ timedOutWithoutPin: false })
  }

  async #resolveGuess({ timedOutWithoutPin }) {
    this.submitted = true
    this.#clearTimer()
    this.guessBtnTarget.disabled = true

    const url = `${this.checkUrlValue}?image_id=${this.imageIdValue}&lat=${this.guessLat}&lng=${this.guessLng}`
    const res = await fetch(url, { headers: { "Accept": "application/json" } })
    if (!res.ok) {
      this.resultTarget.textContent = "Couldn't check guess. Try again."
      this.resultTarget.className = "text-lg font-medium text-red-600"
      this.submitted = false
      this.guessBtnTarget.disabled = false
      if (this.timeLimitValue > 0) this.#startTimer()
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

    if (timedOutWithoutPin) {
      text = `Time's up — no pin selected. ${text}`
    }

    this.resultTarget.textContent = text
    this.resultTarget.className = `text-lg font-medium ${color}`
  }

  async #handleTimeout() {
    if (this.submitted) return

    if (this.guessLat === null || this.guessLng === null) {
      // Timer fallback when no pin was placed.
      this.guessLat = 0
      this.guessLng = 0
      await this.#resolveGuess({ timedOutWithoutPin: true })
      return
    }

    await this.#resolveGuess({ timedOutWithoutPin: false })
  }

  #startTimer() {
    this.#clearTimer()
    if (!this.hasTimerTarget) return

    this.remainingSeconds = this.timeLimitValue > 0 ? this.timeLimitValue : 60
    this.#renderTimer()

    this.#timerInterval = window.setInterval(() => {
      if (this.submitted) {
        this.#clearTimer()
        return
      }

      this.remainingSeconds -= 1
      this.#renderTimer()
      if (this.remainingSeconds <= 0) this.#handleTimeout()
    }, 1000)
  }

  #renderTimer() {
    if (!this.hasTimerTarget) return

    const safeSeconds = Math.max(0, this.remainingSeconds)
    this.timerTarget.textContent = `${safeSeconds}s`
    this.timerTarget.classList.toggle("text-red-700", safeSeconds <= 10)
    this.timerTarget.classList.toggle("border-red-300", safeSeconds <= 10)
    this.timerTarget.classList.toggle("bg-red-50", safeSeconds <= 10)
  }

  #clearTimer() {
    if (this.#timerInterval) {
      window.clearInterval(this.#timerInterval)
      this.#timerInterval = null
    }
  }

  next() {
    // Turbo.visit (not window.location.reload) so the JS context survives
    // and the MapTiler session stays the same across practice rounds.
    // `replace` keeps the back button sane — successive random images
    // shouldn't pile into history.
    Turbo.visit(window.location.href, { action: "replace" })
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
