import { Controller } from "@hotwired/stimulus"

// A searchable single-select picker: a text input filters a list of options
// (already rendered + sorted server-side) and writes the chosen option's value
// into a hidden field. Used by the multiplayer "Image set" picker so a long,
// popularity-ranked list stays navigable.
//
// Markup contract:
//   data-controller="combobox"
//   input[hidden]            data-combobox-target="input"   (submits with the form)
//   input[type=text]         data-combobox-target="search"  (what the user types in)
//   div                      data-combobox-target="menu"    (the options popover)
//   button (one per option)  data-combobox-target="option"  data-value=… data-label=…
//   p                        data-combobox-target="empty"   (the "no matches" line)
export default class extends Controller {
  static targets = [ "input", "search", "menu", "option", "empty" ]

  connect() {
    this.#closeOutside = (e) => { if (!this.element.contains(e.target)) this.close() }
  }

  open() {
    this.menuTarget.classList.remove("hidden")
    document.addEventListener("click", this.#closeOutside)
    // Let the user immediately type to replace the current selection.
    this.searchTarget.select()
  }

  close() {
    this.menuTarget.classList.add("hidden")
    document.removeEventListener("click", this.#closeOutside)
  }

  // Show only options whose label contains the query (case-insensitive).
  filter() {
    if (this.menuTarget.classList.contains("hidden")) this.open()
    const q = this.searchTarget.value.trim().toLowerCase()
    let visible = 0
    this.optionTargets.forEach((opt) => {
      const match = opt.dataset.label.toLowerCase().includes(q)
      opt.classList.toggle("hidden", !match)
      if (match) visible++
    })
    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle("hidden", visible > 0)
  }

  pick(event) {
    const { value, label } = event.currentTarget.dataset
    this.inputTarget.value = value
    this.searchTarget.value = label
    this.close()
  }

  // In a form, Enter would submit; instead pick the first visible option (so
  // typing a query + Enter selects it) and keep Escape as a plain close.
  keydown(event) {
    if (event.key === "Escape") {
      this.close()
    } else if (event.key === "Enter") {
      const first = this.optionTargets.find((o) => !o.classList.contains("hidden"))
      if (first) {
        event.preventDefault()
        first.click()
      }
    }
  }

  disconnect() {
    document.removeEventListener("click", this.#closeOutside)
  }

  #closeOutside
}
