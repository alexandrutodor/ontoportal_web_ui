import { Controller } from '@hotwired/stimulus'

// Connects to data-controller="notification"
export default class extends Controller {
  // delay matches the end of the slide-in-out-right exit animation; removal never waits for animationend.
  static values = { autoRemove: Boolean, delay: { type: Number, default: 5500 } }

  connect () {
    if (this.autoRemoveValue) this.timer = setTimeout(() => this.dismiss(), this.delayValue)
  }

  disconnect () {
    clearTimeout(this.timer)
  }

  // Removing the node (not just fading it) stops the invisible notice from catching clicks or focus.
  dismiss () {
    if (this.element.contains(document.activeElement)) document.activeElement.blur()
    this.element.remove()
  }
}
