// Standalone isolated check for clipboard_component_controller.js (ONTO-T-U03)
// Imports the actual ClipboardComponent controller and validates all copy, extraction,
// whitespace, escaping, rejection, retry, and feedback contracts against mocked clipboard.

import assert from 'node:assert/strict'
import ClipboardController from '../../app/components/clipboard_component/clipboard_component_controller.js'

// Minimal finite DOM double satisfying Stimulus Controller expectations
class ClassList {
  constructor(initial = []) {
    this.classes = new Set(initial)
  }
  add(cls) {
    this.classes.add(cls)
  }
  remove(cls) {
    this.classes.delete(cls)
  }
  contains(cls) {
    return this.classes.has(cls)
  }
  toggle(cls) {
    if (this.classes.has(cls)) this.classes.delete(cls)
    else this.classes.add(cls)
  }
  toArray() {
    return Array.from(this.classes)
  }
}

class FakeElement {
  constructor({ tagName = 'DIV', value = undefined, textContent = '', classes = [] } = {}) {
    this.tagName = tagName.toUpperCase()
    this.value = value
    this.textContent = textContent
    this.classList = new ClassList(classes)
    this.children = []
  }

  appendChild(child) {
    this.children.push(child)
    return child
  }

  querySelector(selector) {
    const sel = selector.toLowerCase()
    for (const child of this.children) {
      if (sel.includes(child.tagName.toLowerCase())) return child
      const nested = child.querySelector(selector)
      if (nested) return nested
    }
    return null
  }
}

function createController({
  contentElem,
  copyElem,
  checkElem,
  failElem,
  buttonElem,
  feedbackElem,
  values = {}
}) {
  const controller = new ClipboardController()
  
  // Wire finite Stimulus targets & values
  controller.hasContentTarget = Boolean(contentElem)
  controller.contentTarget = contentElem

  controller.hasCopyTarget = Boolean(copyElem)
  controller.copyTarget = copyElem

  controller.hasCheckTarget = Boolean(checkElem)
  controller.checkTarget = checkElem

  controller.hasFailTarget = Boolean(failElem)
  controller.failTarget = failElem

  controller.hasButtonTarget = Boolean(buttonElem)
  controller.buttonTarget = buttonElem

  controller.hasFeedbackTarget = Boolean(feedbackElem)
  controller.feedbackTarget = feedbackElem

  controller.hiddenCssValue = values.hiddenCss || 'd-none'
  controller.successDurationValue = values.successDuration || 2000
  controller.copiedMessageValue = values.copiedMessage || 'Copied!'
  controller.failedMessageValue = values.failedMessage || 'Copy failed'

  return controller
}

async function runTests() {
  console.log('Running ClipboardController isolated tests (ONTO-T-U03)...')

  let originalNavigator
  try {
    originalNavigator = globalThis.navigator
  } catch (_) {
    originalNavigator = undefined
  }

  // 1. Exact URI query separators & in container textContent
  {
    const uri = 'https://stage.matportal.org/ontologies/TEST?concept=http%3A%2F%2Fexample.org%2Fc1&opt=2&filter=all'
    const content = new FakeElement({ tagName: 'DIV', textContent: uri })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), uri, 'Exact URI query separators (&) must be preserved')
  }

  // 2. XML brackets in container textContent
  {
    const xml = '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n  <owl:Class rdf:about="http://example.org#Foo"/>\n</rdf:RDF>'
    const content = new FakeElement({ tagName: 'DIV', textContent: xml })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), xml, 'Decoded XML brackets must be preserved')
  }

  // 3. Highlight markup excluded and text decoded
  {
    // A container where child highlight spans existed; DOM textContent naturally extracts only the text
    const decodedText = 'http://example.org/onto#Item a owl:Class ; rdfs:label "Example" .'
    const content = new FakeElement({ tagName: 'DIV', textContent: decodedText })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), decodedText, 'Highlight markup excluded, decoded text extracted')
  }

  // 4. Multiline configs (htaccess / nginx)
  {
    const htaccess = 'RewriteEngine On\nRewriteCond %{HTTP_ACCEPT} text/turtle\nRewriteRule ^(.*)$ http://data.matportal.org/$1 [R=303,L]\n'
    const content = new FakeElement({ tagName: 'DIV', textContent: htaccess })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), htaccess, 'Multiline config newlines must be preserved')
  }

  // 5. Meaningful whitespace (leading and trailing whitespace/newlines must NOT be trimmed)
  {
    const whitespaceText = '   \n\t leading and trailing spaces with indent \t\n   '
    const content = new FakeElement({ tagName: 'DIV', textContent: whitespaceText })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), whitespaceText, 'Meaningful leading and trailing whitespace must not be trimmed')
  }

  // 6. Input target.value extracted
  {
    const sampleInputVal = 'fixture-synthetic-account-token-42'
    const input = new FakeElement({ tagName: 'INPUT', value: sampleInputVal })
    const controller = createController({ contentElem: input })
    assert.equal(controller.getText(), sampleInputVal, 'Input element value must be extracted')
  }

  // 7. Input target with empty value ""
  {
    const input = new FakeElement({ tagName: 'INPUT', value: '' })
    const controller = createController({ contentElem: input })
    assert.equal(controller.getText(), '', 'Input element empty value must be preserved as empty string')
  }

  // 8. Textarea target.value with multiline & whitespace
  {
    const config = 'server {\n    listen 80;\n    server_name example.org;\n}'
    const textarea = new FakeElement({ tagName: 'TEXTAREA', value: config })
    const controller = createController({ contentElem: textarea })
    assert.equal(controller.getText(), config, 'Textarea value must be extracted without alteration')
  }

  // 9. Nested input inside container
  {
    const container = new FakeElement({ tagName: 'DIV', textContent: 'Fallback label' })
    const nested = new FakeElement({ tagName: 'INPUT', value: 'nested-val-123' })
    container.appendChild(nested)
    const controller = createController({ contentElem: container })
    assert.equal(controller.getText(), 'nested-val-123', 'Nested input value should be extracted when present')
  }

  // 10. Missing navigator.clipboard API -> failure state, no false success, button retryable
  {
    globalThis.navigator = {} // no clipboard property
    const copy = new FakeElement({ classes: [] })
    const check = new FakeElement({ classes: ['d-none'] })
    const fail = new FakeElement({ classes: ['d-none'] })
    const button = new FakeElement({ tagName: 'BUTTON' })
    const feedback = new FakeElement({ tagName: 'SPAN' })
    const content = new FakeElement({ textContent: 'text-to-copy' })

    const controller = createController({
      contentElem: content,
      copyElem: copy,
      checkElem: check,
      failElem: fail,
      buttonElem: button,
      feedbackElem: feedback
    })

    await controller.copy()

    assert.equal(copy.classList.contains('d-none'), true, 'Copy icon hidden on failure')
    assert.equal(check.classList.contains('d-none'), true, 'Check icon MUST NOT be shown on failure (no false success)')
    assert.equal(fail.classList.contains('d-none'), false, 'Fail icon visible on failure')
    assert.equal(feedback.textContent, 'Copy failed', 'Feedback announces localized failure')
    assert.equal(button.classList.contains('d-none'), false, 'Button remains visible and retryable')

    controller.disconnect()
  }

  // 11. Rejected navigator.clipboard.writeText promise -> failure state, no false checkmark, retryable
  {
    globalThis.navigator = {
      clipboard: {
        writeText: () => Promise.reject(new Error('Permission denied'))
      }
    }
    const copy = new FakeElement({ classes: [] })
    const check = new FakeElement({ classes: ['d-none'] })
    const fail = new FakeElement({ classes: ['d-none'] })
    const button = new FakeElement({ tagName: 'BUTTON' })
    const feedback = new FakeElement({ tagName: 'SPAN' })
    const content = new FakeElement({ textContent: 'secret' })

    const controller = createController({
      contentElem: content,
      copyElem: copy,
      checkElem: check,
      failElem: fail,
      buttonElem: button,
      feedbackElem: feedback
    })

    await controller.copy()

    assert.equal(copy.classList.contains('d-none'), true, 'Copy icon hidden on rejected promise')
    assert.equal(check.classList.contains('d-none'), true, 'Check icon MUST NOT be shown on rejection (no false checkmark)')
    assert.equal(fail.classList.contains('d-none'), false, 'Fail icon visible on rejection')
    assert.equal(feedback.textContent, 'Copy failed', 'Announced failure')
    assert.equal(button.classList.contains('d-none'), false, 'Button remains retryable')

    controller.disconnect()
  }

  // 12. Successful copy -> visible check, announced success, copy hidden
  {
    let writtenText = null
    globalThis.navigator = {
      clipboard: {
        writeText: (t) => {
          writtenText = t
          return Promise.resolve()
        }
      }
    }

    const payload = 'https://matportal.org/resource?id=1&name=test'
    const copy = new FakeElement({ classes: [] })
    const check = new FakeElement({ classes: ['d-none'] })
    const fail = new FakeElement({ classes: ['d-none'] })
    const feedback = new FakeElement({ tagName: 'SPAN' })
    const content = new FakeElement({ textContent: payload })

    const controller = createController({
      contentElem: content,
      copyElem: copy,
      checkElem: check,
      failElem: fail,
      feedbackElem: feedback,
      values: { successDuration: 50, copiedMessage: 'Copied!' }
    })

    await controller.copy()

    assert.equal(writtenText, payload, 'Exact text written to clipboard')
    assert.equal(copy.classList.contains('d-none'), true, 'Copy icon hidden on success')
    assert.equal(check.classList.contains('d-none'), false, 'Check icon visible on success')
    assert.equal(fail.classList.contains('d-none'), true, 'Fail icon hidden on success')
    assert.equal(feedback.textContent, 'Copied!', 'Feedback announces success')

    // Wait for timeout reset
    await new Promise((r) => setTimeout(r, 70))

    assert.equal(copy.classList.contains('d-none'), false, 'Copy icon restored after duration')
    assert.equal(check.classList.contains('d-none'), true, 'Check icon hidden after duration')
    assert.equal(fail.classList.contains('d-none'), true, 'Fail icon hidden after duration')
    assert.equal(feedback.textContent, '', 'Feedback cleared after duration')

    controller.disconnect()
  }

  // 13. Retry after failure -> transitions to checkmark on subsequent success
  {
    let shouldFail = true
    globalThis.navigator = {
      clipboard: {
        writeText: () => {
          if (shouldFail) return Promise.reject(new Error('First try fail'))
          return Promise.resolve()
        }
      }
    }

    const copy = new FakeElement({ classes: [] })
    const check = new FakeElement({ classes: ['d-none'] })
    const fail = new FakeElement({ classes: ['d-none'] })
    const feedback = new FakeElement({ tagName: 'SPAN' })
    const content = new FakeElement({ textContent: 'retry-test' })

    const controller = createController({
      contentElem: content,
      copyElem: copy,
      checkElem: check,
      failElem: fail,
      feedbackElem: feedback
    })

    // First attempt fails
    await controller.copy()
    assert.equal(fail.classList.contains('d-none'), false, 'Fail shown on first attempt')
    assert.equal(check.classList.contains('d-none'), true, 'Check hidden on first attempt')

    // Retry succeeds
    shouldFail = false
    await controller.copy()
    assert.equal(fail.classList.contains('d-none'), true, 'Fail hidden after successful retry')
    assert.equal(check.classList.contains('d-none'), false, 'Check visible after successful retry')
    assert.equal(feedback.textContent, 'Copied!', 'Feedback announces success on retry')

    controller.disconnect()
  }

  // 14. Idempotent repeated success -> multiple rapid clicks do NOT toggle/invert state
  {
    globalThis.navigator = {
      clipboard: {
        writeText: () => Promise.resolve()
      }
    }

    const copy = new FakeElement({ classes: [] })
    const check = new FakeElement({ classes: ['d-none'] })
    const fail = new FakeElement({ classes: ['d-none'] })
    const feedback = new FakeElement({ tagName: 'SPAN' })
    const content = new FakeElement({ textContent: 'rapid-click' })

    const controller = createController({
      contentElem: content,
      copyElem: copy,
      checkElem: check,
      failElem: fail,
      feedbackElem: feedback,
      values: { successDuration: 100 }
    })

    // 1st click
    await controller.copy()
    assert.equal(check.classList.contains('d-none'), false, 'Check shown on click 1')
    assert.equal(copy.classList.contains('d-none'), true, 'Copy hidden on click 1')

    // 2nd rapid click (before timeout)
    await controller.copy()
    assert.equal(check.classList.contains('d-none'), false, 'Check MUST still be visible on click 2 (no toggle inversion!)')
    assert.equal(copy.classList.contains('d-none'), true, 'Copy MUST still be hidden on click 2')

    // 3rd rapid click
    await controller.copy()
    assert.equal(check.classList.contains('d-none'), false, 'Check MUST still be visible on click 3')
    assert.equal(copy.classList.contains('d-none'), true, 'Copy MUST still be hidden on click 3')

    // Wait for final timeout
    await new Promise((r) => setTimeout(r, 120))
    assert.equal(copy.classList.contains('d-none'), false, 'Copy restored after idle timeout')
    assert.equal(check.classList.contains('d-none'), true, 'Check hidden after idle timeout')

    controller.disconnect()
  }

  // Clean up global
  globalThis.navigator = originalNavigator

  console.log('All 14 ClipboardController isolated checks PASSED!')
}

runTests().catch((err) => {
  console.error('Test failure:', err)
  process.exit(1)
})
