import { Controller } from '@hotwired/stimulus'

export default class extends Controller {

  static targets = ['content', 'copy', 'check', 'fail', 'button', 'feedback']
  static values = {
    hiddenCss: { type: String, default: 'd-none' },
    successDuration: { type: Number, default: 2000 },
    copiedMessage: { type: String, default: 'Copied!' },
    failedMessage: { type: String, default: 'Copy failed' }
  }

  disconnect () {
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }
  }

  async copy () {
    try {
      await navigator.clipboard.writeText(this.getText())
      this.#copied()
    } catch (_) {
      this.#failed()
    }
  }

  getText () {
    if (!this.hasContentTarget) return ''

    const target = this.contentTarget
    if (this.#isInputOrTextarea(target)) {
      return target.value ?? ''
    }

    return target.textContent ?? ''
  }

  #isInputOrTextarea (element) {
    if (!element || !element.tagName) return false
    const tag = element.tagName.toUpperCase()
    return tag === 'INPUT' || tag === 'TEXTAREA'
  }

  #copied () {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }

    if (this.hasCopyTarget) {
      this.copyTarget.classList.add(this.hiddenCssValue)
    }
    if (this.hasCheckTarget) {
      this.checkTarget.classList.remove(this.hiddenCssValue)
    }
    this.#hideFailure()

    if (this.hasFeedbackTarget) {
      this.feedbackTarget.textContent = this.copiedMessageValue
    }

    this.timeout = setTimeout(() => {
      this.#reset()
    }, this.successDurationValue)
  }

  #failed () {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }

    if (this.hasCopyTarget) {
      this.copyTarget.classList.add(this.hiddenCssValue)
    }
    if (this.hasCheckTarget) {
      this.checkTarget.classList.add(this.hiddenCssValue)
    }
    this.#showFailure()

    if (this.hasFeedbackTarget) {
      this.feedbackTarget.textContent = this.failedMessageValue
    }

    this.timeout = setTimeout(() => {
      this.#reset()
    }, this.successDurationValue)
  }

  #showFailure () {
    if (this.hasFailTarget) {
      this.failTarget.classList.remove(this.hiddenCssValue)
    }
  }

  #hideFailure () {
    if (this.hasFailTarget) {
      this.failTarget.classList.add(this.hiddenCssValue)
    }
  }

  #reset () {
    if (this.timeout) {
      clearTimeout(this.timeout)
      this.timeout = null
    }

    if (this.hasCopyTarget) {
      this.copyTarget.classList.remove(this.hiddenCssValue)
    }
    if (this.hasCheckTarget) {
      this.checkTarget.classList.add(this.hiddenCssValue)
    }
    this.#hideFailure()

    if (this.hasFeedbackTarget) {
      this.feedbackTarget.textContent = ''
    }
  }
}
