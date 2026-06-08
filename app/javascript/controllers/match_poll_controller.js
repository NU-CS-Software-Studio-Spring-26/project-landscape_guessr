import { Controller } from "@hotwired/stimulus"

// Drives a multiplayer match page over plain HTTP polling. Asks the server
// for /matches/:code/state.json every `intervalMs`, diffs against what's
// already on screen, and pokes the embedded guess-map controller for
// per-round pin / answer / reveal updates.
//
// The map is the existing single-player Stimulus controller — multiplayer
// only adds this sibling controller on top, no fork of map code.
export default class extends Controller {
  static values = {
    stateUrl:   String,
    guessUrl:   String,
    resultsUrl: String,
    intervalMs: { type: Number, default: 2000 }
  }
  static targets = [
    "image", "roundLabel", "timer", "status",
    "scoreboard", "reveal", "guessHint", "lockedBadge", "finished"
  ]

  connect() {
    this.currentRoundIndex   = null
    this.revealedRoundIndex  = null
    this.guessInFlight       = false
    this.serverOffsetMs      = 0
    this.deadlineMs          = null

    this.boundPinned = (e) => this.onPinned(e)
    this.element.addEventListener("guess-map:pinned", this.boundPinned)

    this.tick()
    this.pollTimer = setInterval(() => this.tick(), this.intervalMsValue)
    this.countdownTimer = setInterval(() => this.updateCountdown(), 250)
  }

  disconnect() {
    clearInterval(this.pollTimer)
    clearInterval(this.countdownTimer)
    this.element.removeEventListener("guess-map:pinned", this.boundPinned)
  }

  async tick() {
    try {
      const res = await fetch(this.stateUrlValue, {
        headers: { "Accept": "application/json" },
        credentials: "same-origin"
      })
      if (!res.ok) return
      const state = await res.json()
      this.applyState(state)
    } catch (_) {
      // network blip — next tick will try again
    }
  }

  applyState(state) {
    this.state = state
    this.serverOffsetMs = Date.now() - Date.parse(state.server_now)

    if (this.hasStatusTarget) {
      this.statusTarget.textContent = state.match.status
    }

    this.applyRound(state)
    this.applyReveal(state)
    this.applyScoreboard(state)
    this.applyFinished(state)
  }

  applyRound(state) {
    const cr = state.current_round
    if (!cr) return

    if (cr.index !== this.currentRoundIndex) {
      // New round — flip the visible artifacts and reset the map so the
      // previous reveal markers / answer line are gone before the player
      // can drop a new pin.
      this.currentRoundIndex = cr.index
      this.guessInFlight = false

      const map = this.mapController
      if (map) {
        map.reset()
      }

      if (this.hasImageTarget)      this.imageTarget.src = cr.image_url
      if (this.hasRoundLabelTarget) {
        this.roundLabelTarget.textContent = `Round ${cr.index} / ${state.match.rounds_total}`
      }
      if (this.hasGuessHintTarget) {
        this.guessHintTarget.textContent = "Click the map to drop your pin."
        this.guessHintTarget.classList.remove("hidden")
      }
      if (this.hasLockedBadgeTarget) this.lockedBadgeTarget.classList.add("hidden")

      this.deadlineMs = Date.parse(cr.deadline_at)
    }

    if (cr.my_guess_submitted) {
      this.markGuessAccepted()
    }
  }

  applyReveal(state) {
    const r = state.last_round_result
    if (!r) return
    if (r.round_index === this.revealedRoundIndex) return
    this.revealedRoundIndex = r.round_index

    const map = this.mapController
    if (map) {
      map.lock()
      map.showAnswer(r.answer.lat, r.answer.lng)
      const others = r.guesses
        .filter(g => g.user_id !== state.you.user_id)
        .map(g => ({ username: g.username, latitude: g.lat, longitude: g.lng }))
      if (others.length) map.showOtherGuesses(others, r.answer.lat, r.answer.lng)
    }

    if (this.hasRevealTarget) {
      const sorted = [...r.guesses].sort((a, b) => (b.score || 0) - (a.score || 0))
      const rows = sorted.map(g => `
        <div class="flex items-center justify-between text-sm">
          <span class="truncate">${this.escape(g.username)}</span>
          <span class="text-xs text-gray-500 ml-2">${this.formatKm(g.distance_km)}</span>
          <span class="ml-3 font-semibold text-amber-600 tabular-nums">${g.score || 0}</span>
        </div>
      `).join("")
      this.revealTarget.innerHTML = `
        <div class="font-semibold mb-1.5">Round ${r.round_index} reveal</div>
        ${rows || '<div class="text-xs text-gray-400">No guesses submitted.</div>'}
      `
      this.revealTarget.classList.remove("hidden")
    }
  }

  applyScoreboard(state) {
    if (!this.hasScoreboardTarget) return
    const players = [...state.players].sort((a, b) => b.total_score - a.total_score)
    this.scoreboardTarget.innerHTML = players.map((p, i) => `
      <div class="flex items-center gap-3 px-3 py-2 ${p.left ? 'opacity-50' : ''}">
        <span class="w-5 text-right text-sm text-gray-400">${i + 1}</span>
        <img src="${this.escape(p.avatar_url)}" class="w-6 h-6 rounded-full" alt="" />
        <span class="flex-1 truncate text-sm text-forest-900">
          ${this.escape(p.username)}
          ${p.locked_in ? '<span class="ml-1 text-xs text-emerald-600">✓</span>' : ''}
        </span>
        <span class="font-semibold text-amber-500 tabular-nums">${p.total_score}</span>
      </div>
    `).join("")
  }

  applyFinished(state) {
    if (state.match.status !== "finished") return
    if (this.hasFinishedTarget) this.finishedTarget.classList.remove("hidden")
    if (this.hasGuessHintTarget) this.guessHintTarget.classList.add("hidden")
    // Stop polling — nothing else will change.
    if (this.pollTimer) {
      clearInterval(this.pollTimer)
      this.pollTimer = null
    }
  }

  updateCountdown() {
    if (!this.deadlineMs || !this.hasTimerTarget) return
    if (this.state?.current_round == null) {
      this.timerTarget.textContent = ""
      return
    }
    const serverNowMs = Date.now() - this.serverOffsetMs
    const remainingMs = this.deadlineMs - serverNowMs
    const seconds = Math.max(0, Math.ceil(remainingMs / 1000))
    this.timerTarget.textContent = `${seconds}s`
    if (seconds <= 5) {
      this.timerTarget.classList.add("text-red-600")
    } else {
      this.timerTarget.classList.remove("text-red-600")
    }
  }

  onPinned(e) {
    if (this.guessInFlight) return
    if (this.revealedRoundIndex === this.currentRoundIndex) return  // round already ended
    const { lat, lng } = e.detail
    this.sendGuess(lat, lng)
  }

  async sendGuess(lat, lng) {
    this.guessInFlight = true
    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.content || ""
      const res = await fetch(this.guessUrlValue, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "X-CSRF-Token": csrf
        },
        body: JSON.stringify({ lat, lng })
      })
      if (res.ok) {
        this.markGuessAccepted()
        this.tick()  // refresh state so other players see us locked in faster
      } else {
        // 409 (round ended/expired) or 422 (bad coords) — let the next poll
        // resync; clear the in-flight flag so the player can try a different
        // pin if the round is still open.
        this.guessInFlight = false
      }
    } catch (_) {
      this.guessInFlight = false
    }
  }

  markGuessAccepted() {
    this.guessInFlight = true
    this.mapController?.lock()
    if (this.hasGuessHintTarget)   this.guessHintTarget.classList.add("hidden")
    if (this.hasLockedBadgeTarget) this.lockedBadgeTarget.classList.remove("hidden")
  }

  get mapController() {
    const el = this.element.querySelector("[data-controller~='guess-map']")
    if (!el) return null
    return this.application.getControllerForElementAndIdentifier(el, "guess-map")
  }

  escape(s) {
    return String(s ?? "").replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]))
  }

  formatKm(km) {
    if (km == null) return ""
    if (km < 1)   return `${Math.round(km * 1000)} m`
    if (km < 10)  return `${km.toFixed(1)} km`
    return `${Math.round(km).toLocaleString()} km`
  }
}
