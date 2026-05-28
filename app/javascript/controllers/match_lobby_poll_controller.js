import { Controller } from "@hotwired/stimulus"

// Polls /matches/:code/state.json while the match is still in the lobby:
// re-renders the player list as people join/leave, and reloads the page
// once the host flips status to "active" (or anything non-lobby) so the
// server-rendered play view takes over.
export default class extends Controller {
  static values = {
    stateUrl:   String,
    intervalMs: { type: Number, default: 2000 }
  }
  static targets = ["playerList", "playerCount"]

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), this.intervalMsValue)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  async tick() {
    try {
      const res = await fetch(this.stateUrlValue, {
        headers: { "Accept": "application/json" },
        credentials: "same-origin"
      })
      if (!res.ok) return
      const state = await res.json()

      if (state.match.status !== "lobby") {
        // Host started (or match was deleted). Reload so the play / finished
        // view renders with all the server-side state we don't have here.
        clearInterval(this.timer)
        window.location.reload()
        return
      }

      this.renderPlayers(state)
    } catch (_) {
      // network blip — next tick tries again
    }
  }

  renderPlayers(state) {
    if (this.hasPlayerCountTarget) {
      this.playerCountTarget.textContent = `${state.players.length}/100`
    }
    if (!this.hasPlayerListTarget) return

    const youId = state.you.user_id
    this.playerListTarget.innerHTML = state.players.map(p => `
      <div class="flex items-center gap-4 px-5 py-3.5 bg-white">
        <span class="flex items-center gap-2 flex-1 min-w-0">
          <img src="${this.esc(p.avatar_url)}" alt=""
               class="w-7 h-7 rounded-full shrink-0" width="40" height="40">
          <span class="font-medium text-forest-900 truncate">${this.esc(p.username)}</span>
          ${p.is_host ? '<span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-semibold bg-forest-100 text-forest-700">Host</span>' : ''}
          ${p.user_id === youId ? '<span class="text-xs text-gray-400">(you)</span>' : ''}
        </span>
      </div>
    `).join("")
  }

  esc(s) {
    return String(s ?? "").replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]))
  }
}
