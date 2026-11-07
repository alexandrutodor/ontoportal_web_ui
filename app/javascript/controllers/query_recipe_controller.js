import { Controller } from "@hotwired/stimulus"

const BROWSE_ALLOWED_KEYS = [
  'search',
  'format',
  'sort_by',
  'Sort_by',
  'show_views',
  'views',
  'show_retired',
  'retired',
  'user_ontologies_only',
  'private_only',
  'public_only',
  'categories',
  'groups',
  'naturalLanguage',
  'natural_language',
  'isOfType',
  'hasFormalityLevel',
  'portals'
]

const SEARCH_ALLOWED_KEYS = [
  'q',
  'query',
  'lang',
  'ontologies',
  'categories',
  'also_search_properties',
  'also_search_obsolete',
  'also_search_views',
  'require_exact_match',
  'require_definition',
  'portals'
]

const BROWSE_SET = new Set(BROWSE_ALLOWED_KEYS)
const SEARCH_SET = new Set(SEARCH_ALLOWED_KEYS)

export default class extends Controller {
  static targets = [
    "triggerButton",
    "panel",
    "closeButton",
    "nameInput",
    "saveButton",
    "message",
    "list",
    "emptyState",
    "importButton",
    "fileInput",
    "clearAllButton"
  ]

  static values = {
    kind: { type: String, default: "browse" },
    portal: { type: String, default: "MatPortal" },
    locale: { type: String, default: "en" },
    storageKey: { type: String, default: "ontoportal_query_recipes_v1" }
  }

  connect() {
    this.boundOnEscape = this.onEscape.bind(this)
    document.addEventListener("keydown", this.boundOnEscape)
    this.renderList()
  }

  disconnect() {
    document.removeEventListener("keydown", this.boundOnEscape)
  }

  get allowedSet() {
    return this.kindValue === "search" ? SEARCH_SET : BROWSE_SET
  }

  // Panel toggle & keyboard management
  togglePanel() {
    const isClosed = this.panelTarget.classList.contains("d-none")
    if (isClosed) {
      this.openPanel()
    } else {
      this.closePanel()
    }
  }

  openPanel() {
    this.panelTarget.classList.remove("d-none")
    if (this.hasTriggerButtonTarget) {
      this.triggerButtonTarget.setAttribute("aria-expanded", "true")
    }
    this.clearMessage()
    this.renderList()
    if (this.hasNameInputTarget) {
      this.nameInputTarget.focus()
    }
  }

  closePanel() {
    this.panelTarget.classList.add("d-none")
    if (this.hasTriggerButtonTarget) {
      this.triggerButtonTarget.setAttribute("aria-expanded", "false")
      this.triggerButtonTarget.focus()
    }
  }

  onEscape(e) {
    if (e.key === "Escape" && !this.panelTarget.classList.contains("d-none")) {
      e.preventDefault()
      this.closePanel()
    }
  }

  onNameKeydown(e) {
    if (e.key === "Enter") {
      e.preventDefault()
      this.saveCurrent()
    }
  }

  // Storage helpers (strictly namespaced to storageKeyValue)
  #loadRecipes() {
    try {
      const raw = window.localStorage.getItem(this.storageKeyValue)
      if (!raw) return []
      const parsed = JSON.parse(raw)
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      this.#showStorageError()
      return null
    }
  }

  #writeRecipes(recipes) {
    try {
      window.localStorage.setItem(this.storageKeyValue, JSON.stringify(recipes))
      return true
    } catch (e) {
      this.#showStorageError()
      return false
    }
  }

  #showStorageError() {
    const isFr = (this.localeValue || "").startsWith("fr")
    const msg = isFr
      ? "Le stockage local est indisponible dans ce navigateur. Impossible d'enregistrer les recettes."
      : "Local storage is unavailable in this browser. Recipes cannot be saved."
    this.showMessage(msg, "danger")
  }

  // Read current filters from DOM and URL (filtering out any non-allowed params)
  getCurrentFilters() {
    const allowed = this.allowedSet
    const filters = {}

    // 1. Read allowlisted params from current URL search
    try {
      const searchParams = new URLSearchParams(window.location.search)
      for (const [k, v] of searchParams.entries()) {
        const cleanKey = k.replace(/\[\]$/, "")
        if (allowed.has(k) || allowed.has(cleanKey)) {
          // Never persist pagination
          if (k === "page" || k === "pagesize" || cleanKey === "page" || cleanKey === "pagesize") continue
          const targetKey = allowed.has(k) ? k : cleanKey
          if (filters[targetKey]) {
            const parts = filters[targetKey].split(",")
            if (!parts.includes(v)) parts.push(v)
            filters[targetKey] = parts.join(",")
          } else {
            filters[targetKey] = v
          }
        }
      }
    } catch (_) {}

    // 2. Read allowlisted inputs from active form or browse container
    const root = this.element.closest("form") || this.element.closest(".browse-container") || document
    const inputs = root.querySelectorAll("input, select, textarea")
    inputs.forEach(el => {
      const rawName = el.name || el.id
      if (!rawName) return
      const cleanName = rawName.replace(/\[\]$/, "")
      if (!allowed.has(rawName) && !allowed.has(cleanName)) return
      if (rawName === "page" || rawName === "pagesize" || cleanName === "page" || cleanName === "pagesize") return

      const targetKey = allowed.has(rawName) ? rawName : cleanName

      if (el.type === "checkbox" || el.type === "radio") {
        if (el.checked) {
          const val = el.value && el.value !== "on" ? el.value : "true"
          if (filters[targetKey]) {
            const parts = filters[targetKey].split(",")
            if (!parts.includes(val)) parts.push(val)
            filters[targetKey] = parts.join(",")
          } else {
            filters[targetKey] = val
          }
        }
      } else if (el.tagName === "SELECT") {
        if (el.multiple) {
          const selected = Array.from(el.selectedOptions).map(o => o.value).filter(Boolean)
          if (selected.length > 0) filters[targetKey] = selected.join(",")
        } else if (el.value) {
          filters[targetKey] = el.value
        }
      } else if (el.value) {
        filters[targetKey] = el.value
      }
    })

    return filters
  }

  // Save current query recipe
  saveCurrent() {
    this.clearMessage()
    const name = (this.hasNameInputTarget ? this.nameInputTarget.value : "").trim()
    if (!name) {
      const isFr = (this.localeValue || "").startsWith("fr")
      this.showMessage(isFr ? "Veuillez entrer un nom pour la recette." : "Please enter a recipe name.", "warning")
      if (this.hasNameInputTarget) this.nameInputTarget.focus()
      return
    }

    const filters = this.getCurrentFilters()
    const recipe = {
      version: 1,
      id: "rec_" + Date.now() + "_" + Math.random().toString(36).slice(2, 7),
      label: name,
      kind: this.kindValue,
      portal: this.portalValue,
      locale: this.localeValue,
      filters: filters,
      createdAt: new Date().toISOString()
    }

    const recipes = this.#loadRecipes()
    if (recipes === null) return

    recipes.unshift(recipe)
    if (this.#writeRecipes(recipes)) {
      if (this.hasNameInputTarget) this.nameInputTarget.value = ""
      this.renderList()
      const isFr = (this.localeValue || "").startsWith("fr")
      this.showMessage(isFr ? "Recette enregistrée avec succès." : "Recipe saved successfully.", "success")
      // Return focus to first recipe reopen button or trigger button
      const firstReopen = this.listTarget.querySelector(".query-recipe-reopen-btn")
      if (firstReopen) {
        firstReopen.focus()
      } else if (this.hasTriggerButtonTarget) {
        this.triggerButtonTarget.focus()
      }
    }
  }

  // Reopen/Apply recipe
  reopen(event) {
    this.clearMessage()
    const id = event.currentTarget.dataset.id
    const recipes = this.#loadRecipes()
    if (!recipes) return

    const recipe = recipes.find(r => r.id === id)
    if (!recipe) return

    const isFr = (this.localeValue || "").startsWith("fr")

    // Review portal mismatch
    if (recipe.portal && recipe.portal !== this.portalValue) {
      const warningText = isFr
        ? `Portail d'origine : ${recipe.portal} (Actuel : ${this.portalValue}). Paramètres appliqués pour révision.`
        : `Originating portal: ${recipe.portal} (Current: ${this.portalValue}). Applied for review.`
      this.showMessage(warningText, "warning")
    }

    // Apply filters to DOM elements
    const root = this.element.closest("form") || this.element.closest(".browse-container") || document
    const missingOntologies = []

    // 1. Reset inputs that belong to allowedSet
    const allInputs = root.querySelectorAll("input, select, textarea")
    allInputs.forEach(el => {
      const rawName = el.name || el.id
      if (!rawName) return
      const cleanName = rawName.replace(/\[\]$/, "")
      if (!this.allowedSet.has(rawName) && !this.allowedSet.has(cleanName)) return
      if (rawName === "page" || rawName === "pagesize" || cleanName === "page" || cleanName === "pagesize") return

      if (el.type === "checkbox" || el.type === "radio") {
        el.checked = false
      } else if (el.tagName === "SELECT") {
        if (el.multiple) {
          Array.from(el.options).forEach(o => { o.selected = false })
        } else {
          el.value = ""
        }
      } else if (el.type !== "hidden") {
        el.value = ""
      }
    })

    // 2. Set recipe filters
    for (const [key, rawVal] of Object.entries(recipe.filters || {})) {
      if (!this.allowedSet.has(key)) continue
      const valStr = String(rawVal)
      const valArray = valStr.split(",").map(s => s.trim())

      // Find matching DOM elements
      const selector = `[name="${key}"], [name="${key}[]"], #${key}, #${key.toLowerCase()}`
      const matches = root.querySelectorAll(selector)

      if (matches.length > 0) {
        matches.forEach(el => {
          if (el.type === "checkbox" || el.type === "radio") {
            const matchesValue = valArray.includes(el.value) || valStr === "true" || valStr === "1"
            el.checked = matchesValue
            el.dispatchEvent(new Event("change", { bubbles: true }))
          } else if (el.tagName === "SELECT") {
            if (el.multiple) {
              Array.from(el.options).forEach(opt => {
                opt.selected = valArray.includes(opt.value)
              })
            } else {
              el.value = valStr
            }
            el.dispatchEvent(new Event("change", { bubbles: true }))
          } else {
            el.value = valStr
            el.dispatchEvent(new Event("input", { bubbles: true }))
            el.dispatchEvent(new Event("change", { bubbles: true }))
          }
        })
      } else if (key === "ontologies") {
        // Track ontologies missing from DOM catalog
        valArray.forEach(o => missingOntologies.push(o))
      }
    }

    if (missingOntologies.length > 0) {
      const ontMsg = isFr
        ? `Ontologie(s) non trouvée(s) dans le catalogue actuel : ${missingOntologies.join(", ")}`
        : `Ontology(ies) not found in current catalog: ${missingOntologies.join(", ")}`
      this.showMessage(ontMsg, "info")
    }

    // 3. Update URL search params and reset pagination
    try {
      const url = new URL(window.location.href)
      // Delete old allowed params and pagination
      this.allowedSet.forEach(k => {
        url.searchParams.delete(k)
        url.searchParams.delete(`${k}[]`)
      })
      url.searchParams.delete("page")
      url.searchParams.delete("pagesize")

      // Add recipe filters
      for (const [k, v] of Object.entries(recipe.filters || {})) {
        if (this.allowedSet.has(k)) {
          url.searchParams.set(k, String(v))
        }
      }

      window.history.pushState({}, "", url.pathname + url.search)
    } catch (_) {}

    // Close panel and return focus to trigger button
    this.closePanel()
  }

  // Rename recipe
  rename(event) {
    this.clearMessage()
    const id = event.currentTarget.dataset.id
    const recipes = this.#loadRecipes()
    if (!recipes) return

    const recipe = recipes.find(r => r.id === id)
    if (!recipe) return

    const isFr = (this.localeValue || "").startsWith("fr")
    const promptMsg = isFr ? "Nouveau nom de la recette :" : "New recipe name:"
    const newName = window.prompt(promptMsg, recipe.label)
    if (newName && newName.trim() && newName.trim() !== recipe.label) {
      recipe.label = newName.trim()
      if (this.#writeRecipes(recipes)) {
        this.renderList()
        this.showMessage(isFr ? "Recette renommée." : "Recipe renamed.", "success")
        if (this.hasTriggerButtonTarget) this.triggerButtonTarget.focus()
      }
    }
  }

  // Delete recipe
  delete(event) {
    this.clearMessage()
    const id = event.currentTarget.dataset.id
    let recipes = this.#loadRecipes()
    if (!recipes) return

    recipes = recipes.filter(r => r.id !== id)
    if (this.#writeRecipes(recipes)) {
      this.renderList()
      const isFr = (this.localeValue || "").startsWith("fr")
      this.showMessage(isFr ? "Recette supprimée." : "Recipe deleted.", "info")
      this.closePanel()
    }
  }

  // Clear all recipes (affects only recipe namespace)
  clearAll() {
    this.clearMessage()
    const isFr = (this.localeValue || "").startsWith("fr")
    const confirmMsg = isFr
      ? "Êtes-vous sûr de vouloir effacer toutes les recettes sur cet appareil ?"
      : "Are you sure you want to clear all recipes on this device?"

    if (window.confirm(confirmMsg)) {
      try {
        window.localStorage.removeItem(this.storageKeyValue)
        this.renderList()
        this.showMessage(isFr ? "Toutes les recettes ont été effacées." : "All recipes cleared.", "info")
        if (this.hasTriggerButtonTarget) this.triggerButtonTarget.focus()
      } catch (e) {
        this.#showStorageError()
      }
    }
  }

  // Export recipe: contains ONLY documented schema keys, never session/apikey/HTML
  export(event) {
    this.clearMessage()
    const id = event.currentTarget.dataset.id
    const recipes = this.#loadRecipes()
    if (!recipes) return

    const recipe = recipes.find(r => r.id === id)
    if (!recipe) return

    // Strict schema construction
    const exportObject = {
      version: 1,
      label: String(recipe.label || "Query Recipe"),
      kind: String(recipe.kind || this.kindValue),
      portal: String(recipe.portal || this.portalValue),
      locale: String(recipe.locale || this.localeValue),
      filters: {}
    }

    const allowed = exportObject.kind === "search" ? SEARCH_SET : BROWSE_SET
    for (const [k, v] of Object.entries(recipe.filters || {})) {
      if (allowed.has(k)) {
        exportObject.filters[k] = v
      }
    }

    const jsonText = JSON.stringify(exportObject, null, 2)
    const blob = new Blob([jsonText], { type: "application/json" })
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    const slug = exportObject.label.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")
    a.href = url
    a.download = `recipe-${exportObject.kind}-${slug || "export"}.json`
    document.body.appendChild(a)
    a.click()
    document.body.removeChild(a)
    URL.revokeObjectURL(url)

    if (this.hasTriggerButtonTarget) this.triggerButtonTarget.focus()
  }

  // Trigger file dialog
  triggerImport() {
    this.clearMessage()
    if (this.hasFileInputTarget) {
      this.fileInputTarget.value = ""
      this.fileInputTarget.click()
    }
  }

  // Handle file import
  handleFileImport(event) {
    const file = event.target.files && event.target.files[0]
    if (!file) return

    const isFr = (this.localeValue || "").startsWith("fr")
    const reader = new FileReader()

    reader.onload = (e) => {
      let data
      try {
        data = JSON.parse(e.target.result)
      } catch (_) {
        this.showMessage(
          isFr ? "Échec de l'importation : format JSON invalide." : "Failed to import recipe: invalid JSON.",
          "danger"
        )
        return
      }

      if (!this.#validateImportData(data)) {
        this.showMessage(
          isFr
            ? "Échec de l'importation : schéma ou filtres non autorisés."
            : "Failed to import recipe: invalid schema or disallowed filters.",
          "danger"
        )
        return
      }

      // Valid: import into recipes collection without touching active form
      const newRecipe = {
        version: 1,
        id: "rec_" + Date.now() + "_" + Math.random().toString(36).slice(2, 7),
        label: data.label.trim(),
        kind: data.kind,
        portal: data.portal,
        locale: data.locale,
        filters: data.filters,
        createdAt: new Date().toISOString()
      }

      const recipes = this.#loadRecipes()
      if (recipes === null) return

      recipes.unshift(newRecipe)
      if (this.#writeRecipes(recipes)) {
        this.renderList()
        this.showMessage(
          isFr ? "Recette importée avec succès." : "Recipe imported successfully.",
          "success"
        )
        if (this.hasTriggerButtonTarget) this.triggerButtonTarget.focus()
      }
    }

    reader.readAsText(file)
  }

  // Validation: schema, version, view kind, allowlisted filter keys, zero outside URLs
  #validateImportData(obj) {
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return false
    if (obj.version !== 1) return false
    if (typeof obj.label !== "string" || !obj.label.trim()) return false
    if (obj.kind !== "browse" && obj.kind !== "search") return false
    if (typeof obj.portal !== "string" || typeof obj.locale !== "string") return false
    if (!obj.filters || typeof obj.filters !== "object" || Array.isArray(obj.filters)) return false

    // Check top-level keys
    const allowedTopKeys = new Set(["version", "label", "kind", "portal", "locale", "filters"])
    for (const key of Object.keys(obj)) {
      if (!allowedTopKeys.has(key)) return false
    }

    // Check filters against allowlist and forbid any external URLs or dangerous schemes
    const allowed = obj.kind === "search" ? SEARCH_SET : BROWSE_SET
    for (const [k, v] of Object.entries(obj.filters)) {
      if (!allowed.has(k)) return false
      if (typeof v !== "string" && typeof v !== "number" && typeof v !== "boolean" && !Array.isArray(v)) {
        return false
      }
      const strVal = String(v).trim()
      if (/^(https?:|\/\/|javascript:|data:)/i.test(strVal)) {
        return false
      }
    }

    return true
  }

  // UI rendering of recipes list
  renderList() {
    if (!this.hasListTarget) return

    const recipes = this.#loadRecipes() || []
    const isFr = (this.localeValue || "").startsWith("fr")

    if (recipes.length === 0) {
      if (this.hasEmptyStateTarget) this.emptyStateTarget.classList.remove("d-none")
      this.listTarget.innerHTML = `
        <div class="text-muted small query-recipe-empty p-2 text-center" data-query-recipe-target="emptyState">
          ${isFr ? "Aucune recette enregistrée sur cet appareil." : "No saved recipes yet on this device."}
        </div>
      `
      return
    }

    const reopenLabel = isFr ? "Appliquer" : "Apply"
    const exportLabel = isFr ? "Exporter" : "Export"
    const renameLabel = isFr ? "Renommer" : "Rename"
    const deleteLabel = isFr ? "Supprimer" : "Delete"

    const itemsHtml = recipes.map(recipe => {
      const isMismatch = recipe.portal && recipe.portal !== this.portalValue
      const badgeHtml = isMismatch
        ? `<span class="badge badge-warning text-dark ml-1" style="font-size: 0.65rem;" title="${isFr ? 'Portail' : 'Portal'}: ${recipe.portal}">${recipe.portal}</span>`
        : ""

      return `
        <div class="query-recipe-item p-2 border-bottom d-flex flex-column" data-recipe-id="${recipe.id}">
          <div class="d-flex justify-content-between align-items-center mb-1">
            <span class="font-weight-bold text-truncate mr-2 query-recipe-title" title="${escapeHtml(recipe.label)}">
              ${escapeHtml(recipe.label)}
            </span>
            ${badgeHtml}
          </div>
          <div class="d-flex align-items-center justify-content-between">
            <button type="button"
                    class="btn btn-sm btn-outline-primary query-recipe-reopen-btn py-0 px-2"
                    data-action="click->query-recipe#reopen"
                    data-id="${recipe.id}"
                    aria-label="${reopenLabel} ${escapeHtml(recipe.label)}">${reopenLabel}</button>
            <div class="btn-group btn-group-sm">
              <button type="button"
                      class="btn btn-sm btn-link text-secondary p-0 mr-2 query-recipe-export-btn"
                      data-action="click->query-recipe#export"
                      data-id="${recipe.id}"
                      aria-label="${exportLabel} ${escapeHtml(recipe.label)}">${exportLabel}</button>
              <button type="button"
                      class="btn btn-sm btn-link text-secondary p-0 mr-2 query-recipe-rename-btn"
                      data-action="click->query-recipe#rename"
                      data-id="${recipe.id}"
                      aria-label="${renameLabel} ${escapeHtml(recipe.label)}">${renameLabel}</button>
              <button type="button"
                      class="btn btn-sm btn-link text-danger p-0 query-recipe-delete-btn"
                      data-action="click->query-recipe#delete"
                      data-id="${recipe.id}"
                      aria-label="${deleteLabel} ${escapeHtml(recipe.label)}">${deleteLabel}</button>
            </div>
          </div>
        </div>
      `
    }).join("")

    this.listTarget.innerHTML = itemsHtml
  }

  showMessage(msg, type = "info") {
    if (!this.hasMessageTarget) return
    this.messageTarget.className = `query-recipe-message alert alert-${type} py-1 px-2 small mb-2`
    this.messageTarget.textContent = msg
    this.messageTarget.classList.remove("d-none")
  }

  clearMessage() {
    if (!this.hasMessageTarget) return
    this.messageTarget.textContent = ""
    this.messageTarget.classList.add("d-none")
  }
}

function escapeHtml(str) {
  if (!str) return ""
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}
