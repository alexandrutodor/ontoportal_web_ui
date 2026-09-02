import { Controller } from "@hotwired/stimulus"

const CONTEXT_LIMITS = {
  page_kind: 40,
  title: 200,
  search_query: 200,
  ontology_acronym: 80,
  ontology_name: 200,
  concept_id: 300,
  concept_label: 200,
  project_name: 200,
  project_description: 500
}

export default class extends Controller {
  static targets = ["launcher", "drawer", "prompt", "submit", "status", "context", "messages"]

  connect() {
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    this.onKeydown = (event) => {
      if (event.key === "Escape" && !this.drawerTarget.hidden) this.close()
    }
    document.addEventListener("keydown", this.onKeydown)
    const pageContext = this.pageContext()
    this.contextTarget.textContent = pageContext.title ? `Context: ${pageContext.title}` : "Context: current page"
    this.lastFocused = null
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  open() {
    this.lastFocused = document.activeElement
    this.drawerTarget.hidden = false
    this.launcherTarget.setAttribute("aria-expanded", "true")
    this.promptTarget.focus()
  }

  close() {
    this.drawerTarget.hidden = true
    this.launcherTarget.setAttribute("aria-expanded", "false")
    this.lastFocused?.focus()
  }

  async submit(event) {
    event.preventDefault()
    const prompt = this.promptTarget.value.trim()
    if (!prompt) return

    this.setBusy(true, "Sending…")
    const message = document.createElement("p")
    message.className = "mb-2"
    message.textContent = ""
    this.messagesTarget.append(message)

    try {
      const payload = { prompt }
      const context = this.pageContext()
      if (Object.keys(context).length) payload.context = context
      const response = await fetch("/assistant/stream", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Accept": "text/event-stream",
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken || ""
        },
        body: JSON.stringify(payload)
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

  pageContext() {
    const marker = document.querySelector("[data-assistant-context-kind]")
    const data = marker?.dataset || {}
    const values = {
      page_kind: data.assistantContextKind,
      title: data.assistantContextTitle,
      search_query: data.assistantContextQuery,
      ontology_acronym: data.assistantContextOntologyAcronym,
      ontology_name: data.assistantContextOntologyName,
      concept_id: data.assistantContextConceptId,
      concept_label: data.assistantContextConceptLabel,
      project_name: data.assistantContextProjectName,
      project_description: data.assistantContextProjectDescription
    }
    return Object.fromEntries(Object.entries(values)
      .map(([key, value]) => [key, this.bound(value, CONTEXT_LIMITS[key])])
      .filter(([, value]) => value))
  }

  bound(value, length) {
    return String(value || "").replace(/<[^>]*>/g, "").trim().slice(0, length)
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
