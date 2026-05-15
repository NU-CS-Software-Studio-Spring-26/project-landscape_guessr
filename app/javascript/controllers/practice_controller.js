import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["guessBtn", "nextBtn", "result", "imageLink", "timer", "timerBar", "timerPanel", "timerOption", "attemptsOption"]
  static values = {
    imageId: Number,
    checkUrl: String,
    timeLimit: { type: Number, default: 0 },
    attempts: { type: Number, default: 1 }
  }

  #boundKeydown
  #timerRaf
  #endsAtMs
  #totalSeconds

  connect() {
    this.guessLat = null
    this.guessLng = null
    this.completed = false
    this.resolving = false
    this.attemptIndex = 0
    this.#boundKeydown = this.#handleKeydown.bind(this)
    document.addEventListener("keydown", this.#boundKeydown)

    this.#syncTimerUi()
    if (this.timeLimitValue > 0) this.#startTimer()
    this.#syncAttemptsUi()
  }

  disconnect() {
    document.removeEventListener("keydown", this.#boundKeydown)
    this.#clearTimer()
  }

  pinChanged(event) {
    this.guessLat = event.detail.lat
    this.guessLng = event.detail.lng
    if (this.completed || this.resolving) return
    this.guessBtnTarget.disabled = false
  }

  async submitGuess(event) {
    if (event?.preventDefault) event.preventDefault()
    if (this.completed || this.resolving || this.guessLat === null) return

    await this.#resolveGuess({ timedOutWithoutPin: false })
  }

  setTimer(event) {
    const seconds = parseInt(event.params.seconds, 10) || 0
    this.timeLimitValue = seconds
    this.#clearTimer()
    this.#syncTimerUi()
    this.#syncPracticeInUrl()
    if (!this.completed && this.timeLimitValue > 0) this.#startTimer()
  }

  setAttempts(event) {
    const attempts = parseInt(event.params.attempts, 10) || 1
    this.attemptsValue = attempts === 2 ? 2 : 1
    this.attemptIndex = 0
    this.#syncAttemptsUi()
    this.#syncPracticeInUrl()
  }

  async #resolveGuess({ timedOutWithoutPin }) {
    this.resolving = true
    this.guessBtnTarget.disabled = true

    const url = `${this.checkUrlValue}?image_id=${this.imageIdValue}&lat=${this.guessLat}&lng=${this.guessLng}`
    const res = await fetch(url, { headers: { "Accept": "application/json" } })
    if (!res.ok) {
      this.resultTarget.textContent = "Couldn't check guess. Try again."
      this.resultTarget.className = "text-lg font-medium text-red-600"
      this.resolving = false
      this.guessBtnTarget.disabled = false
      if (this.timeLimitValue > 0) this.#startTimer()
      return
    }
    const { answer_lat, answer_lng, distance_km: km } = await res.json()

    // In 2-attempt mode, first submit gives distance feedback only.
    if (this.attemptsValue === 2 && this.attemptIndex === 0) {
      let firstText = `Attempt 1: ${Math.round(km).toLocaleString()} km away. Adjust your pin and submit attempt 2.`
      if (timedOutWithoutPin) firstText = `Attempt 1 timed out with no pin. ${firstText}`
      this.resultTarget.textContent = firstText
      this.resultTarget.className = "text-lg font-medium text-amber-700"
      this.attemptIndex = 1
      this.resolving = false
      this.guessBtnTarget.disabled = false
      this.#syncAttemptsUi()
      if (this.timeLimitValue > 0) this.#startTimer()
      return
    }

    this.completed = true
    this.resolving = false
    this.#clearTimer()

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
    if (this.completed || this.resolving) return

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
      if (this.completed || this.resolving) {
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
    const urgent = safeSeconds <= 10
    this.timerTarget.textContent = `${Math.ceil(safeSeconds)}s`
    this.timerTarget.classList.toggle("text-red-700", urgent)
    this.timerTarget.classList.toggle("border-red-300", urgent)
    this.timerTarget.classList.toggle("bg-red-50", urgent)

    if (this.hasTimerBarTarget) {
      const pct = this.#totalSeconds > 0 ? (safeSeconds / this.#totalSeconds) * 100 : 0
      this.timerBarTarget.style.width = `${Math.max(0, Math.min(100, pct))}%`
      // Hue 120 -> 0 yields green -> orange -> red continuously.
      const clampedRatio = Math.max(0, Math.min(1, pct / 100))
      const hue = clampedRatio * 120
      const liveColor = `hsl(${hue} 85% 45%)`
      if (urgent) {
        // Hard blink (no smooth interpolation): alternate between
        // the live timer color and the default track color.
        const blinkOn = Math.floor(performance.now() / 320) % 2 === 0
        this.timerBarTarget.style.backgroundColor = blinkOn ? liveColor : "#fef3c7"
      } else {
        this.timerBarTarget.style.backgroundColor = liveColor
      }
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

  #syncAttemptsUi() {
    if (this.hasAttemptsOptionTarget) {
      this.attemptsOptionTargets.forEach((option) => {
        const optionAttempts = parseInt(option.dataset.practiceAttemptsParam || "1", 10)
        const active = optionAttempts === this.attemptsValue
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

    if (!this.hasGuessBtnTarget || this.completed) return
    this.guessBtnTarget.textContent = this.attemptsValue === 2 && this.attemptIndex === 1 ? "Submit final attempt" :
      (this.attemptsValue === 2 ? "Submit first attempt" : "Submit guess")
  }

  #syncPracticeInUrl() {
    const url = new URL(window.location.href)
    if (this.timeLimitValue > 0) url.searchParams.set("seconds", String(this.timeLimitValue))
    else url.searchParams.delete("seconds")
    if (this.attemptsValue > 1) url.searchParams.set("attempts", String(this.attemptsValue))
    else url.searchParams.delete("attempts")
    url.searchParams.set("image_id", String(this.imageIdValue))
    window.history.replaceState({}, "", url.toString())
  }

  #clearTimer() {
    if (this.#timerRaf) {
      window.cancelAnimationFrame(this.#timerRaf)
      this.#timerRaf = null
    }
    if (this.hasTimerBarTarget) {
      this.timerBarTarget.style.backgroundColor = "hsl(120 85% 45%)"
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
