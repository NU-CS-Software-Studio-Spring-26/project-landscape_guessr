import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["uploadPanel", "urlPanel", "uploadTab", "urlTab"]

  showUpload() {
    this.uploadPanelTarget.classList.remove("hidden")
    this.urlPanelTarget.classList.add("hidden")
    this.uploadTabTarget.classList.add("bg-white", "shadow", "text-gray-900")
    this.uploadTabTarget.classList.remove("text-gray-600")
    this.urlTabTarget.classList.remove("bg-white", "shadow", "text-gray-900")
    this.urlTabTarget.classList.add("text-gray-600")
  }

  showUrl() {
    this.urlPanelTarget.classList.remove("hidden")
    this.uploadPanelTarget.classList.add("hidden")
    this.urlTabTarget.classList.add("bg-white", "shadow", "text-gray-900")
    this.urlTabTarget.classList.remove("text-gray-600")
    this.uploadTabTarget.classList.remove("bg-white", "shadow", "text-gray-900")
    this.uploadTabTarget.classList.add("text-gray-600")
  }
}
