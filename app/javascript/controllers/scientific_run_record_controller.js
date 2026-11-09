import { Controller } from "@hotwired/stimulus"

export default class ScientificRunRecordController extends Controller {
  static targets = [
    "fileInput",
    "status",
    "includeInputText",
    "includeResults",
    "downloadBtn",
    "importBtn",
    "recordPayload",
    "settingsNote"
  ]

  static values = {
    tool: String,
    formSelector: { type: String, default: "form" }
  }

  connect() {
    this.recordedDigest = null
    this.boundHandleInput = this.handleTextareaInput.bind(this)
    const form = this.findForm()
    if (form) {
      const textarea = form.querySelector('textarea[name="text"], textarea[name="input"], textarea')
      if (textarea) {
        textarea.addEventListener("input", this.boundHandleInput)
      }
    }
  }

  disconnect() {
    const form = this.findForm()
    if (form) {
      const textarea = form.querySelector('textarea[name="text"], textarea[name="input"], textarea')
      if (textarea && this.boundHandleInput) {
        textarea.removeEventListener("input", this.boundHandleInput)
      }
    }
  }

  findForm() {
    if (this.formSelectorValue) {
      const form = document.querySelector(this.formSelectorValue)
      if (form) return form
    }
    return this.element.closest("form") || document.querySelector("form")
  }

  triggerImport() {
    if (this.hasFileInputTarget) {
      this.fileInputTarget.value = ""
      this.fileInputTarget.click()
    }
  }

  async importFile(event) {
    const file = event.target.files && event.target.files[0]
    if (!file) return

    try {
      let text
      if (typeof file.text === "function") {
        text = await file.text()
      } else {
        text = await new Promise((resolve, reject) => {
          const reader = new FileReader()
          reader.onload = () => resolve(reader.result)
          reader.onerror = () => reject(reader.error)
          reader.readAsText(file)
        })
      }
      this.processImport(text)
    } catch (err) {
      this.showError("Failed to read file: " + (err.message || "Unknown error"))
    } finally {
      event.target.value = ""
    }
  }

  processImport(jsonString) {
    let record
    try {
      record = JSON.parse(jsonString)
    } catch (e) {
      this.showError("Invalid record: file is not valid JSON.")
      return false
    }

    if (!record || typeof record !== "object" || Array.isArray(record)) {
      this.showError("Invalid record: expected JSON object.")
      return false
    }

    // 1. Schema check
    if (!record.schema_version || !String(record.schema_version).startsWith("1.")) {
      this.showError(`Unsupported schema version: ${record.schema_version || "missing"}.`)
      return false
    }

    // 2. Tool check
    const currentTool = this.toolValue || "annotator"
    const recordTool = record.tool
    if (!this.isCompatibleTool(currentTool, recordTool)) {
      this.showError(`Unsupported tool: record tool '${recordTool}' does not match '${currentTool}'.`)
      return false
    }

    // 3. Security check: Reject credential fields
    if (this.containsCredentials(record)) {
      this.showError("Rejected: record contains credential or authentication fields.")
      return false
    }

    // 4. Security check: Reject foreign endpoint URLs in settings
    if (this.containsForeignUrls(record.settings)) {
      this.showError("Rejected: record contains foreign endpoint URLs.")
      return false
    }

    // Validation passed! Populate form WITHOUT submitting
    const form = this.findForm()
    if (!form) {
      this.showError("Form not found to populate.")
      return false
    }

    this.populateForm(form, record)
    return true
  }

  isCompatibleTool(current, imported) {
    const annotatorTools = ["annotator", "annotatorplus", "ncbo_annotatorplus"]
    if (annotatorTools.includes(current)) {
      return annotatorTools.includes(imported)
    }
    if (current === "recommender") {
      return imported === "recommender"
    }
    return current === imported
  }

  containsCredentials(obj) {
    const credRegex = /apikey|api_key|token|password|secret|credential|session|cookie|auth/i
    const check = (val, key = "") => {
      if (key && credRegex.test(key)) return true
      if (val === null || val === undefined) return false
      if (typeof val === "string") {
        if (/apikey=|api_key=/i.test(val)) return true
        return false
      }
      if (typeof val === "object") {
        for (const k of Object.keys(val)) {
          if (credRegex.test(k)) return true
          if (check(val[k], k)) return true
        }
      }
      return false
    }
    return check(obj)
  }

  containsForeignUrls(settings) {
    if (!settings || typeof settings !== "object") return false
    const check = (val) => {
      if (typeof val === "string") {
        if (/^https?:\/\//i.test(val.trim())) return true
      } else if (Array.isArray(val)) {
        for (const item of val) {
          if (check(item)) return true
        }
      } else if (val && typeof val === "object") {
        for (const k of Object.keys(val)) {
          if (check(val[k])) return true
        }
      }
      return false
    }
    return check(settings)
  }

  populateForm(form, record) {
    const settings = record.settings?.selected || record.settings?.effective || {}

    // Populate input text
    const textarea = form.querySelector('textarea[name="text"], textarea[name="input"], textarea')
    if (textarea) {
      if (record.input && record.input.text !== undefined && record.input.text !== null) {
        textarea.value = record.input.text
        textarea.dispatchEvent(new Event("input", { bubbles: true }))
        textarea.dispatchEvent(new Event("change", { bubbles: true }))
        this.recordedDigest = record.input.sha256 || null
        this.showSuccess("Record loaded for inspection. Click Run to execute.")
      } else {
        this.recordedDigest = record.input?.sha256 || null
        if (textarea.value) {
          this.checkDigestMatch(textarea.value)
        } else {
          this.showInfo("Settings-only record loaded. Supply original input text to rerun.")
        }
      }
    }

    // Populate settings
    for (const [key, val] of Object.entries(settings)) {
      if (val === undefined || val === null) continue

      // Checkbox
      const checkbox = form.querySelector(`input[type="checkbox"][name="${key}"]`)
      if (checkbox) {
        checkbox.checked = Boolean(val)
        checkbox.dispatchEvent(new Event("change", { bubbles: true }))
        continue
      }

      // Radios
      const radio = form.querySelector(`input[type="radio"][name="${key}"][value="${val}"]`)
      if (radio) {
        radio.checked = true
        radio.dispatchEvent(new Event("change", { bubbles: true }))
        continue
      }

      // Selects
      const select = form.querySelector(`select[name="${key}"], select[name="${key}[]"]`)
      if (select) {
        if (select.multiple) {
          const arr = Array.isArray(val) ? val.map(String) : String(val).split(",").map(s => s.trim())
          for (const opt of select.options) {
            opt.selected = arr.includes(opt.value)
          }
        } else {
          select.value = String(val)
        }
        select.dispatchEvent(new Event("change", { bubbles: true }))
        continue
      }

      // Text / Number / Range inputs
      const input = form.querySelector(`input[name="${key}"]`)
      if (input) {
        input.value = String(val)
        input.dispatchEvent(new Event("input", { bubbles: true }))
        input.dispatchEvent(new Event("change", { bubbles: true }))
        continue
      }
    }
  }

  handleTextareaInput(event) {
    if (!this.recordedDigest) return
    const text = event.target.value
    this.checkDigestMatch(text)
  }

  checkDigestMatch(text) {
    if (!this.recordedDigest) return
    const digest = this.computeSha256(text)
    if (digest.toLowerCase() === this.recordedDigest.toLowerCase()) {
      this.showSuccess("Input text matches recorded SHA-256 digest. Ready to run.")
    } else {
      this.showWarning("Input text does not match recorded digest. Original input required for an exact rerun.")
    }
  }

  downloadRecord() {
    if (!this.hasRecordPayloadTarget) {
      this.showError("No run record available to download.")
      return
    }

    let record
    try {
      record = JSON.parse(this.recordPayloadTarget.textContent)
    } catch (e) {
      this.showError("Failed to parse record data.")
      return
    }

    const includeText = this.hasIncludeInputTextTarget ? this.includeInputTextTarget.checked : false
    const includeResults = this.hasIncludeResultsTarget ? this.includeResultsTarget.checked : true

    const exportRecord = JSON.parse(JSON.stringify(record))

    if (!includeText) {
      if (exportRecord.input) {
        delete exportRecord.input.text
        exportRecord.input.mode = "digest"
      }
    } else {
      if (exportRecord.input) {
        exportRecord.input.mode = "text"
      }
    }

    if (!includeResults) {
      delete exportRecord.captured_result
    }

    const jsonStr = JSON.stringify(exportRecord, null, 2)
    const blob = new Blob([jsonStr], { type: "application/json;charset=utf-8" })
    const url = URL.createObjectURL(blob)
    const link = document.createElement("a")
    const dateStr = new Date().toISOString().replace(/[:.]/g, "-")
    link.href = url
    link.download = `${this.toolValue || "scientific"}-run-record-${dateStr}.json`
    document.body.appendChild(link)
    link.click()
    document.body.removeChild(link)
    setTimeout(() => URL.revokeObjectURL(url), 1000)

    this.showSuccess("Run record downloaded.")
  }

  showError(msg) {
    this.displayStatus(msg, "alert alert-danger")
  }

  showSuccess(msg) {
    this.displayStatus(msg, "alert alert-success")
  }

  showWarning(msg) {
    this.displayStatus(msg, "alert alert-warning")
  }

  showInfo(msg) {
    this.displayStatus(msg, "alert alert-info")
  }

  displayStatus(msg, className) {
    if (this.hasStatusTarget) {
      this.statusTarget.className = `scientific-run-record-status ${className}`
      this.statusTarget.textContent = msg
      this.statusTarget.classList.remove("d-none")
    }
  }

  computeSha256(ascii) {
    function rightRotate(value, amount) {
      return (value >>> amount) | (value << (32 - amount))
    }
    let i, j, result = ""
    const words = []
    const utf8Bytes = []

    for (let ci = 0; ci < ascii.length; ci++) {
      let charcode = ascii.charCodeAt(ci)
      if (charcode < 0x80) {
        utf8Bytes.push(charcode)
      } else if (charcode < 0x800) {
        utf8Bytes.push(0xc0 | (charcode >> 6), 0x80 | (charcode & 0x3f))
      } else if (charcode < 0xd800 || charcode >= 0xe000) {
        utf8Bytes.push(0xe0 | (charcode >> 12), 0x80 | ((charcode >> 6) & 0x3f), 0x80 | (charcode & 0x3f))
      } else {
        ci++
        charcode = 0x10000 + (((charcode & 0x3ff) << 10) | (ascii.charCodeAt(ci) & 0x3ff))
        utf8Bytes.push(0xf0 | (charcode >> 18), 0x80 | ((charcode >> 12) & 0x3f), 0x80 | ((charcode >> 6) & 0x3f), 0x80 | (charcode & 0x3f))
      }
    }

    const byteLen = utf8Bytes.length
    for (i = 0; i < byteLen; i++) {
      words[i >> 2] |= utf8Bytes[i] << ((3 - (i % 4)) * 8)
    }
    words[byteLen >> 2] |= 0x80 << ((3 - (byteLen % 4)) * 8)
    words[(((byteLen + 8) >> 6) << 4) + 15] = byteLen * 8

    const hash = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    const k = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    const w = new Array(64)
    for (i = 0; i < words.length; i += 16) {
      let a = hash[0], b = hash[1], c = hash[2], d = hash[3]
      let e = hash[4], f = hash[5], g = hash[6], h = hash[7]

      for (j = 0; j < 64; j++) {
        if (j < 16) {
          w[j] = words[i + j] | 0
        } else {
          const s0 = rightRotate(w[j - 15], 7) ^ rightRotate(w[j - 15], 18) ^ (w[j - 15] >>> 3)
          const s1 = rightRotate(w[j - 2], 17) ^ rightRotate(w[j - 2], 19) ^ (w[j - 2] >>> 10)
          w[j] = (w[j - 16] + s0 + w[j - 7] + s1) | 0
        }

        const t1 = (h + (rightRotate(e, 6) ^ rightRotate(e, 11) ^ rightRotate(e, 25)) + ((e & f) ^ (~e & g)) + k[j] + w[j]) | 0
        const t2 = ((rightRotate(a, 2) ^ rightRotate(a, 13) ^ rightRotate(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0

        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0
      }

      hash[0] = (hash[0] + a) | 0; hash[1] = (hash[1] + b) | 0; hash[2] = (hash[2] + c) | 0; hash[3] = (hash[3] + d) | 0
      hash[4] = (hash[4] + e) | 0; hash[5] = (hash[5] + f) | 0; hash[6] = (hash[6] + g) | 0; hash[7] = (hash[7] + h) | 0
    }

    for (i = 0; i < 8; i++) {
      for (j = 3; j >= 0; j--) {
        const b = (hash[i] >> (8 * j)) & 255
        result += (b < 16 ? "0" : "") + b.toString(16)
      }
    }
    return result
  }
}
