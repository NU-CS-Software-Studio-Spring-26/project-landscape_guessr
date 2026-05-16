import { Controller } from "@hotwired/stimulus"
import { MAPTILER_KEY } from "lib/maptiler"

const HINT_RADIUS_OPTIONS_KM = [0, 500, 750, 1000, 1500, 2000, 3000, 4000]

export default class extends Controller {
  static targets = ["guessBtn", "nextBtn", "result", "imageLink", "timer", "timerBar", "timerPanel", "timerOption", "attemptsOption", "hintTypeOption", "hintRadiusPanel", "hintRadiusOption", "hintLocationPanel", "hintLocationOption", "hintReadout", "saveForm", "removeForm", "saveStatus"]
  static values = {
    imageId: Number,
    checkUrl: String,
    timeLimit: { type: Number, default: 0 },
    attempts: { type: Number, default: 1 },
    hintCircle: { type: Boolean, default: false },
    signedIn: { type: Boolean, default: false },
    initiallySaved: { type: Boolean, default: false }
  }

  #boundKeydown
  #timerRaf
  #endsAtMs
  #totalSeconds
  #nextPrefetchController
  #prefetchedNextUrl
  #prefetchedImage
  #hintLocationRequestId

  connect() {
    this.guessLat = null
    this.guessLng = null
    this.completed = false
    this.resolving = false
    this.attemptIndex = 0
    this.savedForPractice = this.initiallySavedValue
    this.#prefetchedNextUrl = null
    this.#prefetchedImage = null
    this.#nextPrefetchController = null
    this.#hintLocationRequestId = 0
    this.hintLocationMessage = ""
    this.hintLocationDetails = null
    this.#initializeHintStateFromUrl()
    this.#boundKeydown = this.#handleKeydown.bind(this)
    document.addEventListener("keydown", this.#boundKeydown)

    this.#syncTimerUi()
    if (this.timeLimitValue > 0) this.#startTimer()
    this.#syncAttemptsUi()
    this.#syncHintUi()
    this.#applyHintSelection()
    this.#syncSavedControls()
  }

  disconnect() {
    document.removeEventListener("keydown", this.#boundKeydown)
    this.#clearTimer()
    this.#clearNextPrefetch()
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
    this.#clearNextPrefetch()
    if (!this.completed && this.timeLimitValue > 0) this.#startTimer()
  }

  setAttempts(event) {
    const attempts = parseInt(event.params.attempts, 10) || 1
    this.attemptsValue = attempts === 2 ? 2 : 1
    this.attemptIndex = 0
    this.#syncAttemptsUi()
    this.#syncPracticeInUrl()
    this.#clearNextPrefetch()
  }

  setHintType(event) {
    const type = String(event.params.type || "off")
    if (!["off", "radius", "location"].includes(type)) return
    this.hintType = type
    if (type === "radius") this.hintRadiusKm = 0
    if (type === "location") this.hintLocationLevel = "none"
    this.#applyHintSelection()
  }

  setHintRadius(event) {
    const radius = parseInt(event.params.radius, 10)
    if (!HINT_RADIUS_OPTIONS_KM.includes(radius)) return
    this.hintType = "radius"
    this.hintRadiusKm = radius
    this.#applyHintSelection()
  }

  setHintLocationLevel(event) {
    const level = String(event.params.level || "none")
    if (!["none", "continent", "country"].includes(level)) return
    this.hintType = "location"
    this.hintLocationLevel = level
    this.#applyHintSelection()
  }

  async saveForPractice(event) {
    event.preventDefault()
    if (!this.hasSaveFormTarget) return

    const form = event.currentTarget
    const submit = form.querySelector("input[type='submit'], button[type='submit']")
    if (!submit || submit.disabled) return

    submit.disabled = true
    const isInputSubmit = submit.tagName === "INPUT"
    const originalLabel = isInputSubmit ? submit.value : submit.textContent

    try {
      const csrf = document.querySelector("meta[name='csrf-token']")?.content
      const res = await fetch(form.action, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          ...(csrf ? { "X-CSRF-Token": csrf } : {})
        },
        body: new FormData(form),
        credentials: "same-origin"
      })

      if (!res.ok) throw new Error("save_failed")

      this.savedForPractice = true
      this.#syncSavedControls()
      this.#setSaveStatus("Saved", "text-green-700")
    } catch {
      if (isInputSubmit) submit.value = originalLabel
      else submit.textContent = originalLabel
      submit.disabled = false
      this.#setSaveStatus("Couldn't save. Try again.", "text-red-600")
    }
  }

  async removeFromSaved(event) {
    event.preventDefault()
    if (!this.hasRemoveFormTarget) return

    const form = event.currentTarget
    const submit = form.querySelector("input[type='submit'], button[type='submit']")
    if (!submit || submit.disabled) return

    submit.disabled = true
    const isInputSubmit = submit.tagName === "INPUT"
    const originalLabel = isInputSubmit ? submit.value : submit.textContent

    try {
      const csrf = document.querySelector("meta[name='csrf-token']")?.content
      const res = await fetch(form.action, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          ...(csrf ? { "X-CSRF-Token": csrf } : {})
        },
        body: new FormData(form),
        credentials: "same-origin"
      })

      if (!res.ok) throw new Error("unsave_failed")

      this.savedForPractice = false
      this.#syncSavedControls()
      this.#setSaveStatus("Removed", "text-green-700")
    } catch {
      if (isInputSubmit) submit.value = originalLabel
      else submit.textContent = originalLabel
      submit.disabled = false
      this.#setSaveStatus("Couldn't remove. Try again.", "text-red-600")
    }
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
    this.#resetHintForNextAttempt()

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
    this.#syncSavedControls()

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
    this.#prefetchNextRound()
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
        this.#syncOptionButtonStyle(option, active)
      })
    }
  }

  #syncAttemptsUi() {
    if (this.hasAttemptsOptionTarget) {
      this.attemptsOptionTargets.forEach((option) => {
        const optionAttempts = parseInt(option.dataset.practiceAttemptsParam || "1", 10)
        const active = optionAttempts === this.attemptsValue
        option.setAttribute("aria-pressed", active ? "true" : "false")
        this.#syncOptionButtonStyle(option, active)
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
    if (this.hintType === "radius") {
      url.searchParams.set("hint_type", "radius")
      url.searchParams.set("hint_radius", String(this.hintRadiusKm))
    } else if (this.hintType === "location") {
      url.searchParams.set("hint_type", "location")
      url.searchParams.set("hint_location", this.hintLocationLevel)
    } else {
      url.searchParams.delete("hint_type")
      url.searchParams.delete("hint_radius")
      url.searchParams.delete("hint_location")
    }
    url.searchParams.delete("hint_circle")
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

  #syncSavedControls() {
    const showControls = this.signedInValue && this.completed

    if (this.hasSaveFormTarget) {
      this.#setSubmitLabel(this.saveFormTarget, this.savedForPractice ? "Saved" : "Add to practice image set")
      this.#setSubmitDisabled(this.saveFormTarget, false)
      const showSave = showControls && !this.savedForPractice
      this.saveFormTarget.classList.toggle("hidden", !showSave)
    }

    if (this.hasRemoveFormTarget) {
      this.#setSubmitLabel(this.removeFormTarget, "Remove from saved")
      this.#setSubmitDisabled(this.removeFormTarget, false)
      const showRemove = showControls && this.savedForPractice
      this.removeFormTarget.classList.toggle("hidden", !showRemove)
    }
  }

  #setSubmitLabel(form, label) {
    const submit = form.querySelector("input[type='submit'], button[type='submit']")
    if (!submit) return
    if (submit.tagName === "INPUT") submit.value = label
    else submit.textContent = label
  }

  #setSubmitDisabled(form, disabled) {
    const submit = form.querySelector("input[type='submit'], button[type='submit']")
    if (!submit) return
    submit.disabled = disabled
  }

  #setSaveStatus(message, colorClass) {
    if (!this.hasSaveStatusTarget) return
    this.saveStatusTarget.textContent = message
    this.saveStatusTarget.className = `text-sm font-medium ${colorClass}`
  }

  #syncHintUi() {
    if (this.hasHintTypeOptionTarget) {
      this.hintTypeOptionTargets.forEach((option) => {
        const type = String(option.dataset.practiceTypeParam || "off")
        const active = type === this.hintType
        option.setAttribute("aria-pressed", active ? "true" : "false")
        this.#syncOptionButtonStyle(option, active)
      })
    }

    if (this.hasHintRadiusPanelTarget) {
      this.hintRadiusPanelTarget.classList.toggle("hidden", this.hintType !== "radius")
    }
    if (this.hasHintRadiusOptionTarget) {
      this.hintRadiusOptionTargets.forEach((option) => {
        const radius = parseInt(option.dataset.practiceRadiusParam || "0", 10)
        const active = this.hintType === "radius" && radius === this.hintRadiusKm
        option.setAttribute("aria-pressed", active ? "true" : "false")
        this.#syncOptionButtonStyle(option, active)
      })
    }

    if (this.hasHintLocationPanelTarget) {
      this.hintLocationPanelTarget.classList.toggle("hidden", this.hintType !== "location")
    }
    if (this.hasHintLocationOptionTarget) {
      this.hintLocationOptionTargets.forEach((option) => {
        const level = String(option.dataset.practiceLevelParam || "continent")
        const active = this.hintType === "location" && level === this.hintLocationLevel
        option.setAttribute("aria-pressed", active ? "true" : "false")
        this.#syncOptionButtonStyle(option, active)
      })
    }

    if (this.hasHintReadoutTarget) {
      const showReadout = this.hintType === "location" && this.hintLocationMessage.length > 0
      this.hintReadoutTarget.textContent = this.hintLocationMessage
      this.hintReadoutTarget.classList.toggle("hidden", !showReadout)
    }
  }

  #syncOptionButtonStyle(option, active) {
    option.classList.toggle("btn-primary", active)
    option.classList.toggle("btn-secondary", !active)
  }

  async #applyHintSelection() {
    this.#syncHintUi()
    this.#syncPracticeInUrl()
    this.#clearNextPrefetch()

    if (this.hintType === "radius") {
      this.hintLocationMessage = ""
      this.#syncHintUi()
      await this.#showHintCircle()
      return
    }

    this.#hideHintCircle()
    if (this.hintType === "location") {
      await this.#showLocationHint()
      return
    }

    this.hintLocationMessage = ""
    this.#syncHintUi()
  }

  #initializeHintStateFromUrl() {
    const params = new URLSearchParams(window.location.search)
    const type = params.get("hint_type")
    const radius = parseInt(params.get("hint_radius") || "", 10)
    const level = params.get("hint_location")

    if (type === "radius") this.hintType = "radius"
    else if (type === "location") this.hintType = "location"
    else this.hintType = this.hintCircleValue ? "radius" : "off"

    this.hintRadiusKm = HINT_RADIUS_OPTIONS_KM.includes(radius) ? radius : 0
    this.hintLocationLevel = ["none", "continent", "country"].includes(level) ? level : "none"
  }

  async #showLocationHint() {
    if (this.hintLocationLevel === "none") {
      this.hintLocationMessage = ""
      this.#syncHintUi()
      return
    }

    this.hintLocationMessage = "Loading location hint…"
    this.#syncHintUi()

    const requestId = this.#hintLocationRequestId + 1
    this.#hintLocationRequestId = requestId
    const currentLevel = this.hintLocationLevel
    const answer = await this.#loadAnswerForHint()
    if (!answer || requestId !== this.#hintLocationRequestId) return

    const details = await this.#loadLocationHintDetails(answer.lat, answer.lng)
    if (requestId !== this.#hintLocationRequestId || this.hintType !== "location") return

    if (!details) {
      this.hintLocationMessage = "Couldn't load location hint."
      this.#syncHintUi()
      return
    }

    if (currentLevel === "country") {
      this.hintLocationMessage = `Hint: Country — ${details.country || "Unknown"}`
    } else {
      this.hintLocationMessage = `Hint: Continent — ${details.continent || "Unknown"}`
    }
    this.#syncHintUi()
  }

  async #loadLocationHintDetails(lat, lng) {
    if (this.hintLocationDetails) return this.hintLocationDetails

    const endpoint = `https://api.maptiler.com/geocoding/${lng},${lat}.json?key=${encodeURIComponent(MAPTILER_KEY)}&language=en&limit=8`
    const res = await fetch(endpoint, { headers: { "Accept": "application/json" } })
    if (!res.ok) return null

    const payload = await res.json()
    const details = { continent: "", country: "" }
    const features = Array.isArray(payload?.features) ? payload.features : []

    features.forEach((feature) => {
      const placeTypes = Array.isArray(feature?.place_type) ? feature.place_type : []
      if (!details.country && placeTypes.includes("country")) {
        details.country = feature?.text || feature?.place_name || ""
      }
      if (!details.continent && placeTypes.includes("continent")) {
        details.continent = feature?.text || feature?.place_name || ""
      }

      const context = Array.isArray(feature?.context) ? feature.context : []
      context.forEach((entry) => {
        const id = String(entry?.id || "")
        if (!details.country && id.startsWith("country")) details.country = entry?.text || ""
        if (!details.continent && id.startsWith("continent")) details.continent = entry?.text || ""
      })
    })

    this.hintLocationDetails = details
    return details
  }

  #resetHintForNextAttempt() {
    if (this.hintType === "off") return
    this.hintType = "off"
    this.hintLocationMessage = ""
    this.#hideHintCircle()
    this.#syncHintUi()
    this.#syncPracticeInUrl()
  }

  async #showHintCircle() {
    if (this.hintRadiusKm <= 0) {
      this.#hideHintCircle()
      return
    }

    const mapCtrl = this.#guessMapController()
    if (!mapCtrl) return

    const answer = await this.#loadAnswerForHint()
    if (!answer) {
      this.resultTarget.className = "text-lg font-medium text-red-600"
      this.resultTarget.textContent = `Couldn't load ${this.hintRadiusKm} km hint.`
      this.hintType = "off"
      this.hintLocationMessage = ""
      this.#syncHintUi()
      this.#syncPracticeInUrl()
      return
    }

    mapCtrl.showAnswerHintCircle(answer.lat, answer.lng, this.hintRadiusKm)
  }

  #hideHintCircle() {
    const mapCtrl = this.#guessMapController()
    if (!mapCtrl) return
    mapCtrl.hideAnswerHintCircle()
  }

  async #loadAnswerForHint() {
    if (this.hintAnswerLat !== undefined && this.hintAnswerLng !== undefined) {
      return { lat: this.hintAnswerLat, lng: this.hintAnswerLng }
    }

    const url = `${this.checkUrlValue}?image_id=${this.imageIdValue}&lat=0&lng=0`
    const res = await fetch(url, { headers: { "Accept": "application/json" } })
    if (!res.ok) return null
    const { answer_lat, answer_lng } = await res.json()
    this.hintAnswerLat = parseFloat(answer_lat)
    this.hintAnswerLng = parseFloat(answer_lng)
    return { lat: this.hintAnswerLat, lng: this.hintAnswerLng }
  }

  #guessMapController() {
    return this.application.getControllerForElementAndIdentifier(
      this.element.querySelector("[data-controller='guess-map']"),
      "guess-map"
    )
  }

  next() {
    // Turbo.visit (not window.location.reload) so the JS context survives
    // and the MapTiler session stays the same across practice rounds.
    // `replace` keeps the back button sane — successive random images
    // shouldn't pile into history.
    const url = this.#prefetchedNextUrl || this.#nextRoundUrl().toString()
    this.#clearNextPrefetch()
    Turbo.visit(url, { action: "replace" })
  }

  #handleKeydown(event) {
    if (event.defaultPrevented) return
    if (event.altKey || event.ctrlKey || event.metaKey) return
    if (this.#isEditableTarget(event.target)) return

    const key = String(event.key || "").toLowerCase()
    const canSubmit = !this.guessBtnTarget.classList.contains("hidden") && !this.guessBtnTarget.disabled
    const canNext = !this.nextBtnTarget.classList.contains("hidden")

    if (event.code === "Space" || event.key === "Enter") {
      event.preventDefault()
      if (canSubmit) this.submitGuess()
      else if (canNext) this.next()
      return
    }

    if (key === "n" && canNext) {
      event.preventDefault()
      this.next()
      return
    }

  }

  #isEditableTarget(target) {
    if (!(target instanceof Element)) return false
    if (target.closest("input, textarea, select")) return true
    return target.closest("[contenteditable=''], [contenteditable='true']") !== null
  }

  #nextRoundUrl() {
    const url = new URL(window.location.href)
    if (this.timeLimitValue > 0) url.searchParams.set("seconds", String(this.timeLimitValue))
    else url.searchParams.delete("seconds")
    if (this.attemptsValue > 1) url.searchParams.set("attempts", String(this.attemptsValue))
    else url.searchParams.delete("attempts")
    if (this.hintType === "radius") {
      url.searchParams.set("hint_type", "radius")
      url.searchParams.set("hint_radius", String(this.hintRadiusKm))
    } else if (this.hintType === "location") {
      url.searchParams.set("hint_type", "location")
      url.searchParams.set("hint_location", this.hintLocationLevel)
    } else {
      url.searchParams.delete("hint_type")
      url.searchParams.delete("hint_radius")
      url.searchParams.delete("hint_location")
    }
    url.searchParams.delete("hint_circle")
    url.searchParams.delete("image_id")
    return url
  }

  async #prefetchNextRound() {
    this.#clearNextPrefetch()

    const prefetchUrl = this.#nextRoundUrl().toString()
    const controller = new AbortController()
    this.#nextPrefetchController = controller

    try {
      const res = await fetch(prefetchUrl, {
        headers: { "Accept": "text/html" },
        credentials: "same-origin",
        signal: controller.signal
      })
      if (!res.ok) return

      const html = await res.text()
      if (controller.signal.aborted) return

      const doc = new DOMParser().parseFromString(html, "text/html")
      const root = doc.querySelector("[data-controller~='practice']")
      const nextImageId = parseInt(root?.dataset.practiceImageIdValue || "", 10)
      if (!Number.isFinite(nextImageId)) return

      const image = doc.querySelector("img[data-zoomable-target='image']")
      const imageSrc = image?.getAttribute("src")
      if (!imageSrc) return

      const url = this.#nextRoundUrl()
      url.searchParams.set("image_id", String(nextImageId))
      this.#prefetchedNextUrl = url.toString()

      // Warm the browser image cache so the next round appears faster.
      this.#prefetchedImage = new Image()
      this.#prefetchedImage.decoding = "async"
      this.#prefetchedImage.src = imageSrc
    } catch (error) {
      if (error?.name !== "AbortError") this.#clearNextPrefetch()
      return
    } finally {
      if (this.#nextPrefetchController === controller) {
        this.#nextPrefetchController = null
      }
    }
  }

  #clearNextPrefetch() {
    if (this.#nextPrefetchController) {
      this.#nextPrefetchController.abort()
      this.#nextPrefetchController = null
    }
    this.#prefetchedNextUrl = null
    this.#prefetchedImage = null
  }
}
