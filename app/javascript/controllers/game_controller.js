import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["latitude", "longitude", "readout", "submit", "next", "result", "otherGuesses", "leaveModal"]
  static values = { gamePath: String }

  connect() {
    this.guessLat = null
    this.guessLng = null
    this.#pendingNavigation = null
    this.#isBypassingGuard = false
    this.#boundKeydown = this.#handleKeydown.bind(this)
    this.#boundClick = this.#handleClick.bind(this)
    this.#boundSubmit = this.#handleSubmit.bind(this)
    this.#boundBeforeVisit = this.#handleBeforeVisit.bind(this)
    document.addEventListener("keydown", this.#boundKeydown)
    document.addEventListener("click", this.#boundClick, true)
    document.addEventListener("submit", this.#boundSubmit, true)
    document.addEventListener("turbo:before-visit", this.#boundBeforeVisit)
  }

  disconnect() {
    document.removeEventListener("keydown", this.#boundKeydown)
    document.removeEventListener("click", this.#boundClick, true)
    document.removeEventListener("submit", this.#boundSubmit, true)
    document.removeEventListener("turbo:before-visit", this.#boundBeforeVisit)
    document.body.classList.remove("overflow-hidden")
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

    const dist = this.#formatDistance(km)
    let text, color
    if (km < 50) {
      text = `${dist} away — Excellent!`
      color = "text-green-600"
    } else if (km < 300) {
      text = `${dist} away — Great!`
      color = "text-green-600"
    } else if (km < 1000) {
      text = `${dist} away — Not bad!`
      color = "text-yellow-600"
    } else {
      text = `${dist} away`
      color = "text-red-600"
    }

    this.resultTarget.textContent = text
    this.resultTarget.className = `text-lg font-medium ${color}`
    this.readoutTarget.classList.add("hidden")

    if (data.other_guesses?.length) {
      mapCtrl.showOtherGuesses(data.other_guesses, answerLat, answerLng)
      this.#renderOtherGuesses(data.other_guesses, answerLat, answerLng)
    }
  }

  nextRound() {
    // Turbo.visit (not window.location.href) so the JS context survives
    // and the MapTiler session stays the same across rounds — a hard nav
    // would mint a new mtsid per round and burn 5× the session quota.
    Turbo.visit(this.gamePathValue)
  }

  #boundKeydown
  #boundClick
  #boundSubmit
  #boundBeforeVisit
  #pendingNavigation
  #isBypassingGuard

  #handleKeydown(event) {
    if (this.#modalOpen()) {
      if (event.code === "Escape") {
        event.preventDefault()
        this.cancelLeave()
      }
      return
    }

    if (event.code !== "Space") return
    event.preventDefault()

    if (!this.submitTarget.classList.contains("hidden") && !this.submitTarget.disabled) {
      this.submitTarget.click()
    } else if (!this.nextTarget.classList.contains("hidden")) {
      this.nextRound()
    }
  }

  #renderOtherGuesses(guesses, answerLat, answerLng) {
    if (!this.hasOtherGuessesTarget) return
    const items = guesses.map(g => {
      const km = this.#haversine(parseFloat(g.latitude), parseFloat(g.longitude), answerLat, answerLng)
      return `<span><strong>${g.username}</strong> ${this.#formatDistance(km)}</span>`
    })
    this.otherGuessesTarget.innerHTML = items.join(" &middot; ")
    this.otherGuessesTarget.classList.remove("hidden")
  }

  // Mirrors GamesHelper#format_distance_compact so sub-km guesses
  // don't render as "0 km" and 1.x km don't get rounded up to "2 km".
  #formatDistance(km) {
    if (km < 1) return `${Math.round(km * 1000)} m`
    if (km < 10) {
      const r = Math.round(km * 10) / 10
      return `${Number.isInteger(r) ? r.toFixed(0) : r.toFixed(1)} km`
    }
    return `${Math.round(km).toLocaleString()} km`
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

  #handleBeforeVisit(event) {
    if (this.#isBypassingGuard) return

    const destinationUrl = event.detail?.url
    if (this.#isInGameFlow(destinationUrl)) return

    event.preventDefault()
    this.#openLeaveModal(() => {
      this.#isBypassingGuard = true
      Turbo.visit(destinationUrl)
    })
  }

  #handleClick(event) {
    if (this.#isBypassingGuard) return
    if (event.defaultPrevented || event.button !== 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    if (!(event.target instanceof Element)) return

    const link = event.target.closest("a[href]")
    if (!link) return
    if (link.target === "_blank" || link.hasAttribute("download")) return

    const destinationUrl = link.href
    if (this.#isInGameFlow(destinationUrl)) return

    event.preventDefault()
    this.#openLeaveModal(() => {
      this.#isBypassingGuard = true
      window.location.href = destinationUrl
    })
  }

  #handleSubmit(event) {
    if (this.#isBypassingGuard) return

    const form = event.target
    if (!(form instanceof HTMLFormElement)) return

    // The in-round guess form stays in-game and is handled via fetch.
    if (form.closest("[data-controller~='game']") === this.element) return

    const destinationUrl = form.action
    if (this.#isInGameFlow(destinationUrl)) return

    event.preventDefault()
    this.#openLeaveModal(() => {
      this.#isBypassingGuard = true
      if (event.submitter) {
        form.requestSubmit(event.submitter)
      } else {
        form.requestSubmit()
      }
    })
  }

  #isInGameFlow(url) {
    if (!url) return false

    const destination = new URL(url, window.location.origin)
    if (destination.origin !== window.location.origin) return false

    const allowedPaths = [this.gamePathValue, `${this.gamePathValue}/results`]
    return allowedPaths.includes(destination.pathname)
  }

  #openLeaveModal(navigateCallback) {
    this.#pendingNavigation = navigateCallback
    this.leaveModalTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }

  #closeLeaveModal() {
    this.leaveModalTarget.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
  }

  #modalOpen() {
    return this.hasLeaveModalTarget && !this.leaveModalTarget.classList.contains("hidden")
  }

  confirmLeave() {
    const navigate = this.#pendingNavigation
    this.#pendingNavigation = null
    this.#closeLeaveModal()
    if (navigate) navigate()
  }

  cancelLeave() {
    this.#pendingNavigation = null
    this.#closeLeaveModal()
  }
}
