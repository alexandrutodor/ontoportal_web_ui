import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "prompt", "submit", "status", "messages"]

  connect() {
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
  }

  async submit(event) {
    event.preventDefault()
    const prompt = this.promptTarget.value.trim()
    if (!prompt) return

    this.setBusy(true, "Sending…")
    const message = document.createElement("p")
    message.className = "assistant-message mb-2"
    message.textContent = ""
    this.messagesTarget.append(message)

    try {
      const response = await fetch("/assistant/stream", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Accept": "text/event-stream",
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken || ""
        },
        body: JSON.stringify({ prompt })
      })
      if (!response.ok) throw new Error(await this.errorMessage(response))
      if (!response.body) throw new Error("The assistant returned no stream.")

      await this.readStream(response.body, message)
      this.setBusy(false, "Response received")
      this.promptTarget.focus()
    } catch (error) {
      message.textContent = error.message || "The assistant is unavailable."
      this.setBusy(false, "Request failed")
      this.promptTarget.focus()
    }
  }

  async errorMessage(response) {
    try {
      const body = await response.json()
      return body.error || "The assistant is unavailable."
    } catch (_error) {
      return "The assistant is unavailable."
    }
  }

  async readStream(body, message) {
    const reader = body.getReader()
    const decoder = new TextDecoder()
    let buffer = ""
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split("\n")
      buffer = lines.pop() || ""
      lines.forEach((line) => {
        if (!line.startsWith("data:")) return
        const data = line.slice(5).trim()
        if (!data || data === "[DONE]") return
        message.textContent += this.textFromEvent(data)
      })
    }
    buffer += decoder.decode()
    buffer.split("\n").forEach((line) => {
      if (!line.startsWith("data:")) return
      const data = line.slice(5).trim()
      if (!data || data === "[DONE]") return
      message.textContent += this.textFromEvent(data)
    })
  }

  textFromEvent(data) {
    try {
      const parsed = JSON.parse(data)
      if (parsed.error) return "Assistant backend is unavailable."
      return String(parsed.delta ?? parsed.text ?? parsed.content ?? "")
    } catch (_error) {
      return data
    }
  }

  setBusy(busy, status) {
    this.submitTarget.disabled = busy
    this.promptTarget.disabled = busy
    this.statusTarget.textContent = status
  }
}
