import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "panel",
    "content",
    "loading",
    "error",
    "errorMessage",
    "prevBtn",
    "nextBtn",
    "closeBtn",
    "retryBtn",
    "row"
  ];

  connect() {
    this.currentIndex = -1;
    this.originatingElement = null;
    this.currentUrl = null;
  }

  get panelEl() {
    if (this.hasPanelTarget) return this.panelTarget;
    return (
      this.element.querySelector('[data-mapping-evidence-target="panel"]') ||
      document.getElementById("mapping-evidence-panel") ||
      this.createDefaultPanel()
    );
  }

  get loadingEl() {
    if (this.hasLoadingTarget) return this.loadingTarget;
    return this.panelEl.querySelector(
      '[data-mapping-evidence-target="loading"], .panel-loading, .mapping-evidence-loading'
    );
  }

  get errorEl() {
    if (this.hasErrorTarget) return this.errorTarget;
    return this.panelEl.querySelector(
      '[data-mapping-evidence-target="error"], .panel-error, .mapping-evidence-error'
    );
  }

  get errorMessageEl() {
    if (this.hasErrorMessageTarget) return this.errorMessageTarget;
    return this.panelEl.querySelector(
      '[data-mapping-evidence-target="errorMessage"], .error-message'
    );
  }

  get contentEl() {
    if (this.hasContentTarget) return this.contentTarget;
    return this.panelEl.querySelector(
      '[data-mapping-evidence-target="content"], .panel-content, .mapping-evidence-content'
    );
  }

  get prevBtnEl() {
    if (this.hasPrevBtnTarget) return this.prevBtnTarget;
    return this.panelEl.querySelector(
      '[data-mapping-evidence-target="prevBtn"], .prev-evidence-btn'
    );
  }

  get nextBtnEl() {
    if (this.hasNextBtnTarget) return this.nextBtnTarget;
    return this.panelEl.querySelector(
      '[data-mapping-evidence-target="nextBtn"], .next-evidence-btn'
    );
  }

  getRows() {
    if (this.hasRowTarget && this.rowTargets.length > 0) {
      return this.rowTargets;
    }
    const fromContainer = this.element.querySelectorAll(
      '[data-mapping-evidence-target="row"], [data-mapping-evidence-row]'
    );
    if (fromContainer.length > 0) return Array.from(fromContainer);

    const fromDoc = document.querySelectorAll(
      '[data-mapping-evidence-target="row"], [data-mapping-evidence-row]'
    );
    if (fromDoc.length > 0) return Array.from(fromDoc);

    const btnRows = this.element.querySelectorAll("[data-evidence-url]");
    if (btnRows.length > 0) return Array.from(btnRows);

    return [];
  }

  open(event) {
    if (event) event.preventDefault();
    this.originatingElement = event ? event.currentTarget : document.activeElement;

    const rows = this.getRows();
    let index = -1;
    const trigger = event ? event.currentTarget : null;

    if (trigger) {
      const triggerRow =
        trigger.closest(
          '[data-mapping-evidence-target="row"], [data-mapping-evidence-row]'
        ) || trigger;
      index = rows.indexOf(triggerRow);
      if (index === -1) {
        const url = trigger.dataset.evidenceUrl;
        const id = trigger.dataset.mappingId;
        index = rows.findIndex((r) => {
          const rUrl =
            r.dataset.evidenceUrl ||
            r.querySelector("[data-evidence-url]")?.dataset.evidenceUrl;
          const rId =
            r.dataset.mappingId ||
            r.querySelector("[data-mapping-id]")?.dataset.mappingId;
          return (url && rUrl === url) || (id && rId === id);
        });
      }
    }

    this.currentIndex = index >= 0 ? index : 0;

    const panel = this.panelEl;
    if (panel) {
      panel.classList.remove("d-none");
      panel.removeAttribute("hidden");
      panel.setAttribute("aria-hidden", "false");
    }

    this.updateNav();
    this.loadCurrent();
  }

  updateNav() {
    const rows = this.getRows();
    const total = rows.length;
    const hasPrev = this.currentIndex > 0;
    const hasNext = this.currentIndex < total - 1;

    const prevBtn = this.prevBtnEl;
    if (prevBtn) {
      prevBtn.disabled = !hasPrev;
      prevBtn.setAttribute("aria-disabled", String(!hasPrev));
    }

    const nextBtn = this.nextBtnEl;
    if (nextBtn) {
      nextBtn.disabled = !hasNext;
      nextBtn.setAttribute("aria-disabled", String(!hasNext));
    }
  }

  async loadCurrent() {
    const rows = this.getRows();
    if (this.currentIndex < 0 || this.currentIndex >= rows.length) return;

    const row = rows[this.currentIndex];
    const url =
      row.dataset.evidenceUrl ||
      row.getAttribute("data-evidence-url") ||
      row.querySelector("[data-evidence-url]")?.dataset.evidenceUrl ||
      row.querySelector("[data-evidence-url]")?.getAttribute("data-evidence-url");

    if (!url) return;
    this.currentUrl = url;

    // Show loading state
    const loading = this.loadingEl;
    if (loading) {
      loading.classList.remove("d-none");
      loading.removeAttribute("hidden");
    }

    const error = this.errorEl;
    if (error) {
      error.classList.add("d-none");
      error.setAttribute("hidden", "");
    }

    const content = this.contentEl;
    if (content) {
      content.setAttribute("aria-busy", "true");
    }

    try {
      const res = await fetch(url, {
        headers: { Accept: "text/html" }
      });

      if (!res.ok) {
        throw new Error(`HTTP ${res.status}`);
      }

      const html = await res.text();

      // End loading state
      if (loading) {
        loading.classList.add("d-none");
        loading.setAttribute("hidden", "");
      }

      if (content) {
        content.innerHTML = html;
        content.classList.remove("d-none");
        content.removeAttribute("hidden");
        content.removeAttribute("aria-busy");
      }
    } catch (err) {
      // Failed lookups end loading state and show retry/return
      if (loading) {
        loading.classList.add("d-none");
        loading.setAttribute("hidden", "");
      }

      if (content) {
        content.classList.add("d-none");
        content.setAttribute("hidden", "");
        content.removeAttribute("aria-busy");
      }

      if (error) {
        error.classList.remove("d-none");
        error.removeAttribute("hidden");
        const msgEl = this.errorMessageEl;
        if (msgEl) {
          msgEl.textContent = err.message || "Unable to load mapping evidence";
        }
      }
    }
  }

  prev(event) {
    if (event) event.preventDefault();
    if (this.currentIndex > 0) {
      this.currentIndex--;
      this.updateNav();
      this.loadCurrent();
    }
  }

  next(event) {
    if (event) event.preventDefault();
    const rows = this.getRows();
    if (this.currentIndex < rows.length - 1) {
      this.currentIndex++;
      this.updateNav();
      this.loadCurrent();
    }
  }

  retry(event) {
    if (event) event.preventDefault();
    this.loadCurrent();
  }

  close(event) {
    if (event) event.preventDefault();
    const panel = this.panelEl;
    if (panel) {
      panel.classList.add("d-none");
      panel.setAttribute("hidden", "");
      panel.setAttribute("aria-hidden", "true");
    }

    if (
      this.originatingElement &&
      typeof this.originatingElement.focus === "function"
    ) {
      this.originatingElement.focus();
    }
  }

  createDefaultPanel() {
    let panel = document.getElementById("mapping-evidence-panel");
    if (panel) return panel;

    panel = document.createElement("div");
    panel.id = "mapping-evidence-panel";
    panel.className = "mapping-evidence-panel card shadow p-3 d-none";
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-modal", "true");
    panel.setAttribute("aria-label", "Mapping Evidence");

    panel.innerHTML = `
      <div class="d-flex justify-content-between align-items-center border-bottom pb-2">
        <h5 class="m-0">Mapping Evidence</h5>
        <button type="button" class="close" data-action="click->mapping-evidence#close" aria-label="Close">
          <span>&times;</span>
        </button>
      </div>
      <div class="d-flex justify-content-between align-items-center my-2">
        <button type="button" class="btn btn-sm btn-outline-secondary prev-evidence-btn" data-action="click->mapping-evidence#prev">
          &larr; Previous
        </button>
        <button type="button" class="btn btn-sm btn-outline-secondary next-evidence-btn" data-action="click->mapping-evidence#next">
          Next &rarr;
        </button>
      </div>
      <div class="panel-loading mapping-evidence-loading text-center py-4 d-none">
        <div class="spinner-border spinner-border-sm" role="status"></div>
        <span class="ml-2">Loading evidence...</span>
      </div>
      <div class="panel-error mapping-evidence-error alert alert-danger d-none">
        <p class="m-0 error-message">Unable to load mapping evidence.</p>
        <div class="mt-2">
          <button type="button" class="btn btn-sm btn-primary mr-2" data-action="click->mapping-evidence#retry">Retry</button>
          <button type="button" class="btn btn-sm btn-secondary" data-action="click->mapping-evidence#close">Return</button>
        </div>
      </div>
      <div class="panel-content mapping-evidence-content"></div>
    `;

    document.body.appendChild(panel);
    return panel;
  }
}
