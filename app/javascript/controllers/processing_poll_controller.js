import { Controller } from "@hotwired/stimulus"

// Polls a JSON endpoint every couple seconds while ProcessImageJob is
// finishing background work, then swaps "Processing..." placeholders
// for the real thumbnail as each image is marked processed. Stops as
// soon as nothing pending — no-cost when idle.
//
// HTML wiring:
//   <... data-controller="processing-poll"
//        data-processing-poll-url-value="<%= processing_status_image_set_path(set) %>"
//        data-processing-poll-banner-id-value="processing-banner">
//     <div data-item-id="123" data-processing="true">
//       <div class="processing-placeholder ...">Processing…</div>
//       ...
//     </div>
//   </...>
export default class extends Controller {
  static values = {
    url:      String,
    bannerId: String,
    interval: { type: Number, default: 2000 },
  }

  connect() {
    if (this.#anyPending()) this.#schedule(0)
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  #schedule(delay) {
    this.timer = setTimeout(() => this.#poll(), delay)
  }

  async #poll() {
    try {
      const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
      if (res.ok) {
        const data = await res.json()
        this.#applyUpdate(data)
      }
    } catch (e) {
      console.warn("[processing-poll]", e)
    }

    if (this.#anyPending()) {
      this.#schedule(this.intervalValue)
    } else {
      const banner = document.getElementById(this.bannerIdValue)
      if (banner) banner.remove()
    }
  }

  #anyPending() {
    return this.element.querySelector('[data-processing="true"]') !== null
  }

  #applyUpdate(data) {
    const banner = document.getElementById(this.bannerIdValue)
    if (banner) {
      const countEl = banner.querySelector("[data-processing-count]")
      if (countEl) countEl.textContent = data.processing_count
      if (data.processing_count === 0) banner.remove()
    }

    for (const item of data.items) {
      if (!item.processed || !item.photo_url) continue
      const row = this.element.querySelector(`[data-item-id="${item.id}"]`)
      if (!row || row.dataset.processing !== "true") continue

      const placeholder = row.querySelector(".processing-placeholder")
      if (placeholder) {
        const img = document.createElement("img")
        img.src = item.photo_url
        img.alt = placeholder.dataset.title || ""
        img.className = "w-full sm:w-24 h-20 sm:h-16 object-cover rounded-md border border-gray-100 shrink-0"
        placeholder.replaceWith(img)
      }
      row.dataset.processing = "false"
    }
  }
}
