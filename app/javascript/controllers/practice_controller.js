import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["guessBtn", "nextBtn", "result", "imageLink", "timer", "timerBar", "timerPanel", "timerOption"]
  static values = {
    imageId: Number,
    checkUrl: String,
    timeLimit: { type: Number, default: 0 }
  }

  #boundKeydown
  #timerRaf
  #endsAtMs
  #totalSeconds

  connect() {
    this.guessLat = null
    this.guessLng = null
    this.submitted = false
    this.#boundKeydown = this.#handleKeydown.bind(this)
    document.addEventListener("keydown", this.#boundKeydown)

    this.#syncTimerUi()
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

  setTimer(event) {
    const seconds = parseInt(event.params.seconds, 10) || 0
    this.timeLimitValue = seconds
    this.#clearTimer()
    this.#syncTimerUi()
    this.#syncTimerInUrl()
    if (!this.submitted && this.timeLimitValue > 0) this.#startTimer()
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
    this.#totalSeconds = this.remainingSeconds
    this.#endsAtMs = performance.now() + (this.#totalSeconds * 1000)
    this.#renderTimer()

    const tick = () => {
      if (this.submitted) {
        this.#clearTimer()
        return
      }

      const remainingMs = Math.max(0, this.#endsAtMs - performance.now())
      this.remainingSeconds = remainingMs / 1000
      this.#renderTimer()
      if (remainingMs <= 0) {
        this.#handleTimeout()
        return
      }
      this.#timerRaf = window.requestAnimationFrame(tick)
    }

    this.#timerRaf = window.requestAnimationFrame(tick)
  }

  #renderTimer() {
    if (!this.hasTimerTarget) return

    const safeSeconds = Math.max(0, this.remainingSeconds)
    this.timerTarget.textContent = `${Math.ceil(safeSeconds)}s`
    this.timerTarget.classList.toggle("text-red-700", safeSeconds <= 10)
    this.timerTarget.classList.toggle("border-red-300", safeSeconds <= 10)
    this.timerTarget.classList.toggle("bg-red-50", safeSeconds <= 10)

    if (this.hasTimerBarTarget) {
      const pct = this.#totalSeconds > 0 ? (safeSeconds / this.#totalSeconds) * 100 : 0
      this.timerBarTarget.style.width = `${Math.max(0, Math.min(100, pct))}%`
      // Hue 120 -> 0 yields green -> orange -> red continuously.
      const clampedRatio = Math.max(0, Math.min(1, pct / 100))
      const hue = clampedRatio * 120
      this.timerBarTarget.style.backgroundColor = `hsl(${hue} 85% 45%)`
    }
  }

  #syncTimerUi() {
    const timedOn = this.timeLimitValue > 0
    if (this.hasTimerPanelTarget) {
      this.timerPanelTarget.classList.toggle("hidden", !timedOn)
    }

    if (this.hasTimerTarget) {
      this.timerTarget.textContent = `${timedOn ? this.timeLimitValue : 0}s`
    }

    if (this.hasTimerBarTarget) {
      this.timerBarTarget.style.width = timedOn ? "100%" : "0%"
      this.timerBarTarget.style.backgroundColor = "hsl(120 85% 45%)"
    }

    if (this.hasTimerOptionTarget) {
      this.timerOptionTargets.forEach((option) => {
        const optionSeconds = parseInt(option.dataset.practiceSecondsParam || "0", 10)
        const active = optionSeconds === this.timeLimitValue
        option.setAttribute("aria-pressed", active ? "true" : "false")
        option.classList.toggle("bg-blue-100", active)
        option.classList.toggle("text-blue-800", active)
        option.classList.toggle("border-blue-300", active)
        option.classList.toggle("shadow-sm", active)
        option.classList.toggle("bg-white", !active)
        option.classList.toggle("text-gray-700", !active)
        option.classList.toggle("border-gray-300", !active)
        option.classList.toggle("hover:bg-gray-50", !active)
      })
    }
  }

  #syncTimerInUrl() {
    const url = new URL(window.location.href)
    if (this.timeLimitValue > 0) url.searchParams.set("seconds", String(this.timeLimitValue))
    else url.searchParams.delete("seconds")
    url.searchParams.set("image_id", String(this.imageIdValue))
    window.history.replaceState({}, "", url.toString())
  }

  #clearTimer() {
    if (this.#timerRaf) {
      window.cancelAnimationFrame(this.#timerRaf)
      this.#timerRaf = null
    }
  }

  next() {
    // Turbo.visit (not window.location.reload) so the JS context survives
    // and the MapTiler session stays the same across practice rounds.
    // `replace` keeps the back button sane — successive random images
    // shouldn't pile into history.
    const url = new URL(window.location.href)
    // Keep timer settings but drop image pinning so "Next image" actually
    // advances to a new random image.
    url.searchParams.delete("image_id")
    Turbo.visit(url.toString(), { action: "replace" })
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
