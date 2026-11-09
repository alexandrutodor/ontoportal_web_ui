import { Controller } from "@hotwired/stimulus"
import debounce from "debounce"

// Connects to data-controller="ror-search"
// When agent type is organization, typing in the name field searches
// https://api.ror.org/v2/organizations and fills name, acronym, homepage,
// and the ROR identifier from the selected result.
export default class extends Controller {
    static targets = ["nameInput", "results", "acronymInput", "homepageInput", "identifierInput", "organizationRadio"]
    static values = {
        apiUrl: { type: String, default: "https://api.ror.org/v2/organizations" },
        minLength: { type: Number, default: 2 },
        debounceMs: { type: Number, default: 300 },
        namePlaceholder: { type: String, default: "" },
        // shortcut: lookup unavailable message is plain English, add i18n value when translations exist
        lookupUnavailableText: { type: String, default: "Organization lookup unavailable" }
    }

    connect() {
        this.requestId = 0
        this.currentAbortController = null
        this.lastAutoFilled = {}
        this.search = debounce(this.search.bind(this), this.debounceMsValue)
        this.updatePlaceholder()
    }

    disconnect() {
        if (this.search?.clear) this.search.clear()
        this.#abortCurrentRequest()
    }

    updatePlaceholder() {
        if (!this.hasNameInputTarget) return
        this.nameInputTarget.placeholder = this.#isOrganizationMode() ? this.namePlaceholderValue : ""
    }

    search() {
        if (!this.#isOrganizationMode()) {
            this.#abortCurrentRequest()
            this.hideResults()
            return
        }

        const query = this.hasNameInputTarget ? this.nameInputTarget.value.trim() : ""
        if (query.length < this.minLengthValue) {
            this.#abortCurrentRequest()
            this.hideResults()
            return
        }

        if (this.lastSelectedName && query === this.lastSelectedName) {
            this.#abortCurrentRequest()
            this.hideResults()
            return
        }

        this.#abortCurrentRequest()
        const controller = new AbortController()
        this.currentAbortController = controller
        const requestId = ++this.requestId

        fetch(`${this.apiUrlValue}?query=${encodeURIComponent(query)}`, { signal: controller.signal })
            .then(r => r.ok ? r.json() : Promise.reject(new Error(r.statusText || "Lookup failed")))
            .then(data => {
                if (requestId !== this.requestId || !this.#isOrganizationMode() || !this.hasNameInputTarget || this.nameInputTarget.value.trim() !== query) {
                    return
                }
                this.renderResults(data.items || [])
            })
            .catch(err => {
                if (err.name === "AbortError") return
                if (requestId !== this.requestId || !this.#isOrganizationMode() || !this.hasNameInputTarget || this.nameInputTarget.value.trim() !== query) {
                    return
                }
                console.error("ROR search error", err)
                this.renderUnavailable()
            })
    }

    prevent(event) {
        event.preventDefault()
    }

    blur() {
        if (this.hasResultsTarget) this.resultsTarget.style.display = "none"
    }

    hide() {
        if (this.search?.clear) this.search.clear()
        this.#abortCurrentRequest()
        this.hideResults()
    }

    renderResults(items) {
        if (!this.hasResultsTarget) return
        if (items.length === 0) {
            this.hideResults()
            return
        }

        this.resultsTarget.innerHTML = ""
        items.slice(0, 10).forEach(item => {
            const display = this.#displayName(item)
            const acronym = this.#acronym(item)
            const country = item.locations?.[0]?.geonames_details?.country_name || ""
            const rorId = item.id?.split("/").pop() || ""

            const a = document.createElement("a")
            a.href = "#"
            a.className = "search-content"
            a.innerHTML = `
                <p class="search-element">
                    <strong>${this.#escape(display)}</strong>
                    ${acronym ? `<small> (${this.#escape(acronym)})</small>` : ""}
                    ${country ? `<small> — ${this.#escape(country)}</small>` : ""}
                </p>
                <p class="home-result-type"><small>${this.#escape(rorId)}</small></p>
            `
            a.addEventListener("click", (e) => {
                e.preventDefault()
                this.select(item)
            })
            this.resultsTarget.appendChild(a)
        })

        this.resultsTarget.style.display = "block"
    }

    renderUnavailable() {
        if (!this.hasResultsTarget) return
        this.resultsTarget.innerHTML = `
            <div class="search-content text-muted" data-ror-error="true">
                <small>${this.#escape(this.lookupUnavailableTextValue)}</small>
            </div>
        `
        this.resultsTarget.style.display = "block"
    }

    select(item) {
        if (this.search?.clear) this.search.clear()
        this.#abortCurrentRequest()

        const englishName = this.#englishName(item)
        const acronym = this.#acronym(item)
        const homepage = this.#homepage(item)
        const rorId = item.id || ""

        const finalName = englishName || this.#rorDisplayName(item) || acronym
        if (finalName && this.hasNameInputTarget) {
            this.lastSelectedName = finalName.trim()
            this.#setValue(this.nameInputTarget, finalName)
            if (this.search?.clear) this.search.clear()
        }

        this.#updateAutoFilledField(this.hasAcronymInputTarget ? this.acronymInputTarget : null, acronym, "acronym")
        this.#updateAutoFilledField(this.hasHomepageInputTarget ? this.homepageInputTarget : null, homepage, "homepage")
        this.#updateAutoFilledField(this.hasIdentifierInputTarget ? this.identifierInputTarget : null, rorId, "identifier")

        if (this.hasNameInputTarget) this.nameInputTarget.blur()
        this.hideResults()
    }

    hideResults() {
        if (!this.hasResultsTarget) return
        this.resultsTarget.style.display = "none"
        this.resultsTarget.innerHTML = ""
    }

    #abortCurrentRequest() {
        this.requestId = (this.requestId || 0) + 1
        if (this.currentAbortController) {
            this.currentAbortController.abort()
            this.currentAbortController = null
        }
    }

    #updateAutoFilledField(input, value, key) {
        if (!input) return
        this.lastAutoFilled = this.lastAutoFilled || {}
        const current = (input.value || "").trim()
        const previous = this.lastAutoFilled[key]
        const canOverwrite = current === "" || (previous !== undefined && previous !== "" && current === previous)

        if (canOverwrite) {
            const nextValue = value ? value.trim() : ""
            if (input.value !== nextValue) {
                this.#setValue(input, nextValue)
            }
            if (nextValue) {
                this.lastAutoFilled[key] = nextValue
            } else {
                delete this.lastAutoFilled[key]
            }
        } else {
            delete this.lastAutoFilled[key]
        }
    }

    #isOrganizationMode() {
        if (!this.hasOrganizationRadioTarget) return true
        return this.organizationRadioTarget.checked
    }

    #setValue(input, value) {
        input.value = value
        input.dispatchEvent(new Event("input", { bubbles: true }))
        input.dispatchEvent(new Event("change", { bubbles: true }))
    }

    #displayName(item) {
        return this.#englishName(item) || this.#rorDisplayName(item) || (item.names?.[0]?.value ?? "")
    }

    #englishName(item) {
        const en = (item.names || []).find(n => n.lang === "en" && (n.types || []).includes("label"))
        return en?.value || ""
    }

    #rorDisplayName(item) {
        const d = (item.names || []).find(n => (n.types || []).includes("ror_display"))
        return d?.value || ""
    }

    #acronym(item) {
        const ac = (item.names || []).find(n => (n.types || []).includes("acronym"))
        return ac?.value || ""
    }

    #homepage(item) {
        const domain = (item.domains || [])[0]
        if (domain) {
            return domain.startsWith("http") ? domain : `https://${domain}`
        }
        const link = (item.links || []).find(l => l.type === "website")
        return link?.value || ""
    }

    #escape(str) {
        return String(str)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;")
    }
}
