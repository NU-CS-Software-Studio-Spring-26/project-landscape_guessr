import { Controller } from "@hotwired/stimulus"

// Hides this element if a child <img> fails to load. Defense-in-depth
// against broken Commons URLs that server-side validation missed —
// either because they were deleted after we checked, or because the
// data path is somewhere validation doesn't run yet.
//
// Wire on the wrapper (the <a> or card div), not on the <img> itself
// — that way the broken-image icon doesn't sit in an empty wrapper.
//
// HTML:
//   <a data-controller="hide-broken-image" href=...>
//     <img src=... />
//   </a>
export default class extends Controller {
  connect() {
    this.element.querySelectorAll("img").forEach((img) => {
      // Detect "already failed" only for images the browser has
      // actually attempted to fetch. For lazy-loaded images that
      // haven't entered the viewport yet, img.complete=true and
      // naturalWidth=0 too — but currentSrc is "" because the
      // browser hasn't issued the request. Without the currentSrc
      // guard, a paginated gallery with loading="lazy" would hide
      // every below-the-fold image on connect.
      if (img.complete && img.naturalWidth === 0 && img.currentSrc) {
        this.#hide()
        return
      }
      img.addEventListener("error", () => this.#hide(), { once: true })
    })
  }

  #hide() {
    this.element.style.display = "none"
  }
}
