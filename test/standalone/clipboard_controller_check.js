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
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const uri = 'https://stage.matportal.org/ontologies/TEST?concept=http%3A%2F%2Fexample.org%2Fc1&opt=2&filter=all'
    const content = new FakeElement({ tagName: 'DIV', textContent: uri })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), uri, 'Exact URI query separators (&) must be preserved in getText')
    await controller.copy()
    assert.equal(written, uri, 'Exact URI query separators (&) payload written to clipboard')
  }

  // 2. XML brackets in container textContent
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const xml = '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n  <owl:Class rdf:about="http://example.org#Foo"/>\n</rdf:RDF>'
    const content = new FakeElement({ tagName: 'DIV', textContent: xml })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), xml, 'Decoded XML brackets must be preserved in getText')
    await controller.copy()
    assert.equal(written, xml, 'Decoded XML brackets payload written to clipboard')
  }

  // 3. Highlight markup excluded and text decoded
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const decodedText = 'http://example.org/onto#Item a owl:Class ; rdfs:label "Example" .'
    const content = new FakeElement({ tagName: 'DIV', textContent: decodedText })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), decodedText, 'Highlight markup excluded, decoded text extracted in getText')
    await controller.copy()
    assert.equal(written, decodedText, 'Highlight decoded text payload written to clipboard')
  }

  // 4. Multiline configs (htaccess / nginx)
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const htaccess = 'RewriteEngine On\nRewriteCond %{HTTP_ACCEPT} text/turtle\nRewriteRule ^(.*)$ http://data.matportal.org/$1 [R=303,L]\n'
    const content = new FakeElement({ tagName: 'DIV', textContent: htaccess })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), htaccess, 'Multiline config newlines must be preserved in getText')
    await controller.copy()
    assert.equal(written, htaccess, 'Multiline config newlines payload written to clipboard')
  }

  // 5. Meaningful whitespace (leading and trailing whitespace/newlines must NOT be trimmed)
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const whitespaceText = '   \n\t leading and trailing spaces with indent \t\n   '
    const content = new FakeElement({ tagName: 'DIV', textContent: whitespaceText })
    const controller = createController({ contentElem: content })
    assert.equal(controller.getText(), whitespaceText, 'Meaningful leading and trailing whitespace must not be trimmed in getText')
    await controller.copy()
    assert.equal(written, whitespaceText, 'Meaningful whitespace payload written to clipboard')
  }

  // 6. Input target.value extracted
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const sampleInputVal = 'fixture-synthetic-account-token-42'
    const input = new FakeElement({ tagName: 'INPUT', value: sampleInputVal })
    const controller = createController({ contentElem: input })
    assert.equal(controller.getText(), sampleInputVal, 'Input element value must be extracted in getText')
    await controller.copy()
    assert.equal(written, sampleInputVal, 'Input element value payload written to clipboard')
  }

  // 7. Input target with empty value ""
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const input = new FakeElement({ tagName: 'INPUT', value: '' })
    const controller = createController({ contentElem: input })
    assert.equal(controller.getText(), '', 'Input element empty value must be preserved as empty string in getText')
    await controller.copy()
    assert.equal(written, '', 'Input element empty value payload written to clipboard')
  }

  // 8. Textarea target.value with multiline & whitespace
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const config = 'server {\n    listen 80;\n    server_name example.org;\n}'
    const textarea = new FakeElement({ tagName: 'TEXTAREA', value: config })
    const controller = createController({ contentElem: textarea })
    assert.equal(controller.getText(), config, 'Textarea value must be extracted in getText')
    await controller.copy()
    assert.equal(written, config, 'Textarea value payload written to clipboard')
  }

  // 9. Mixed-container with descendant input (container uses whole textContent, never arbitrary descendant input)
  {
    let written = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { written = t } } }
    const containerText = 'Displayed container label and context'
    const container = new FakeElement({ tagName: 'DIV', textContent: containerText })
    const descendantInput = new FakeElement({ tagName: 'INPUT', value: 'arbitrary-child-value' })
    container.appendChild(descendantInput)
    const controller = createController({ contentElem: container })
    assert.equal(controller.getText(), containerText, 'Container uses whole textContent, not descendant input value')
    await controller.copy()
    assert.equal(written, containerText, 'Container copies whole textContent payload, never descendant input value')
    assert.notEqual(written, descendantInput.value, 'Payload must not match descendant input value')

    // Contrast with direct controls preserving value
    let directWritten = null
    globalThis.navigator = { clipboard: { writeText: async (t) => { directWritten = t } } }
    const directControl = new FakeElement({ tagName: 'INPUT', value: 'direct-control-value' })
    const directController = createController({ contentElem: directControl })
    assert.equal(directController.getText(), 'direct-control-value', 'Direct control preserves value')
    await directController.copy()
    assert.equal(directWritten, 'direct-control-value', 'Direct control payload written to clipboard')
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

  // 11. Synchronous writeText throw -> failure state, no false checkmark, retryable
  {
    globalThis.navigator = {
      clipboard: {
        writeText: () => {
          throw new Error('Synchronous clipboard failure')
        }
      }
    }
    const copy = new FakeElement({ classes: [] })
    const check = new FakeElement({ classes: ['d-none'] })
    const fail = new FakeElement({ classes: ['d-none'] })
    const button = new FakeElement({ tagName: 'BUTTON' })
    const feedback = new FakeElement({ tagName: 'SPAN' })
    const content = new FakeElement({ textContent: 'sync-error-test' })

    const controller = createController({
      contentElem: content,
      copyElem: copy,
      checkElem: check,
      failElem: fail,
      buttonElem: button,
      feedbackElem: feedback
    })

    await controller.copy()

    assert.equal(copy.classList.contains('d-none'), true, 'Copy icon hidden on synchronous throw')
    assert.equal(check.classList.contains('d-none'), true, 'Check icon MUST NOT be shown on synchronous throw (no false checkmark)')
    assert.equal(fail.classList.contains('d-none'), false, 'Fail icon visible on synchronous throw')
    assert.equal(feedback.textContent, 'Copy failed', 'Announced failure on synchronous throw')
    assert.equal(button.classList.contains('d-none'), false, 'Button remains retryable')

    controller.disconnect()
  }

  // 12. Rejected navigator.clipboard.writeText promise -> failure state, no false checkmark, retryable
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

  // 13. Successful copy -> visible check, announced success, copy hidden
  {
    let writtenText = null
    globalThis.navigator = {
      clipboard: {
        writeText: async (t) => {
          writtenText = t
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

  // 14. Retry after failure -> transitions to checkmark on subsequent success
  {
    let shouldFail = true
    globalThis.navigator = {
      clipboard: {
        writeText: async () => {
          if (shouldFail) throw new Error('First try fail')
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

  // 15. Idempotent repeated success -> multiple rapid clicks do NOT toggle/invert state
  {
    globalThis.navigator = {
      clipboard: {
        writeText: async () => {}
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

  console.log('All 15 ClipboardController isolated checks PASSED!')
}

runTests().catch((err) => {
  console.error('Test failure:', err)
  process.exit(1)
})
