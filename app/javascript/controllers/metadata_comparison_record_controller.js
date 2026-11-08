import { Controller } from "@hotwired/stimulus";

export default class MetadataComparisonRecordController extends Controller {
  static targets = ["container", "error", "fileInput", "summary", "timestamp"];
  static values = {
    package: Object
  };

  connect() {
    if (this.hasPackageValue && this.packageValue && Object.keys(this.packageValue).length > 0) {
      this.renderPackage(this.packageValue, false);
    }
  }

  triggerFileInput(event) {
    if (event) event.preventDefault();
    if (this.hasFileInputTarget) {
      this.fileInputTarget.click();
    }
  }

  onFileChange(event) {
    const file = event.target.files && event.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const text = e.target.result;
        this.reopenFromText(text);
      } catch (err) {
        this.showError("Invalid comparison package: file read error");
      }
    };
    reader.onerror = () => {
      this.showError("Invalid comparison package: failed to read file");
    };
    reader.readAsText(file);
  }

  reopenFromText(jsonText) {
    let pkg;
    try {
      pkg = JSON.parse(jsonText);
    } catch (e) {
      this.showError("Invalid comparison package: malformed JSON");
      return;
    }
    this.reopen(pkg);
  }

  reopen(pkg) {
    if (!pkg || typeof pkg !== "object" || Array.isArray(pkg)) {
      this.showError("Invalid comparison package: expected JSON object");
      return;
    }
    if (!pkg.properties || !Array.isArray(pkg.properties) || !pkg.records || !Array.isArray(pkg.records)) {
      this.showError("Invalid comparison package: missing required properties or records");
      return;
    }

    this.clearError();
    this.renderPackage(pkg, true);
  }

  showError(message) {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = message;
      this.errorTarget.classList.remove("d-none");
    }
  }

  clearError() {
    if (this.hasErrorTarget) {
      this.errorTarget.textContent = "";
      this.errorTarget.classList.add("d-none");
    }
  }

  renderPackage(pkg, isReopened = false) {
    if (this.hasTimestampTarget) {
      const ts = pkg.retrieval_timestamp || "Unknown";
      this.timestampTarget.textContent = isReopened
        ? `Reopened Local Snapshot (captured at ${ts})`
        : `Captured at ${ts} (Read-only capture)`;
    }

    if (this.hasSummaryTarget) {
      const count = pkg.records ? pkg.records.length : 0;
      const mode = isReopened ? "Local read-only snapshot (0 network requests)" : "Live capture";
      this.summaryTarget.textContent = `| ${count} submission(s) captured (${mode})`;
    }

    if (!this.hasContainerTarget) return;

    const props = pkg.properties || [];
    const records = pkg.records || [];

    let html = '<table class="table table-bordered table-striped comparison-matrix mb-0" role="table" aria-label="Metadata Comparison Matrix">';
    html += '<thead class="table-light"><tr>';
    html += '<th scope="col" class="align-middle">Submission / Version</th>';

    for (const prop of props) {
      const isOntology = prop.level === "ontology";
      const badgeClass = isOntology ? "badge bg-info text-dark" : "badge bg-secondary";
      const levelLabel = isOntology ? "Ontology level (current at capture)" : "Submission level";
      html += `<th scope="col" class="align-middle" data-prop-id="${this.escapeHtml(prop.id)}">`;
      html += `<div class="fw-bold">${this.escapeHtml(prop.label || prop.id)}</div>`;
      html += `<small class="${badgeClass}">${this.escapeHtml(levelLabel)}</small>`;
      html += '</th>';
    }
    html += '</tr></thead>';

    html += '<tbody>';
    for (const rec of records) {
      const isUnavailable = rec.status === "unavailable";
      const rowClass = isUnavailable ? "table-warning unavailable-row" : "";
      html += `<tr class="${rowClass}" data-row-key="${this.escapeHtml(rec.row_key)}">`;

      // Row header cell
      html += '<th scope="row" class="align-middle">';
      html += `<div class="fw-bold">${this.escapeHtml(rec.row_key)}</div>`;
      if (rec.version_identifier) {
        html += `<div class="small text-muted">v: ${this.escapeHtml(rec.version_identifier)}</div>`;
      }
      if (isUnavailable) {
        html += '<span class="badge bg-danger">Unavailable</span>';
        if (rec.error) {
          html += `<div class="small text-danger">${this.escapeHtml(rec.error)}</div>`;
        }
      } else {
        html += '<span class="badge bg-success">Available</span>';
      }
      html += '</th>';

      // Value cells
      for (const prop of props) {
        const cell = (rec.values && rec.values[prop.id]) || { state: "empty", value: null };
        html += `<td class="align-middle state-${this.escapeHtml(cell.state)}" data-prop-id="${this.escapeHtml(prop.id)}">`;
        if (cell.state === "unavailable") {
          html += '<span class="badge bg-danger">[Unavailable]</span>';
        } else if (cell.state === "unknown") {
          html += '<span class="badge bg-warning text-dark">[Unknown]</span>';
        } else if (cell.state === "empty") {
          html += '<span class="text-muted fst-italic">[Empty]</span>';
        } else {
          html += this.formatCellValue(cell.value);
        }
        html += '</td>';
      }

      html += '</tr>';
    }
    html += '</tbody></table>';

    this.containerTarget.innerHTML = html;
  }

  formatCellValue(val) {
    if (val === null || val === undefined) return '<span class="text-muted fst-italic">[Empty]</span>';
    if (typeof val === "boolean") {
      return `<code>${val ? "true" : "false"}</code>`;
    }
    if (Array.isArray(val)) {
      if (val.length === 0) return '<span class="text-muted fst-italic">[Empty]</span>';
      const items = val.map(x => `<li>${this.formatCellValue(x)}</li>`).join("");
      return `<ul class="list-unstyled mb-0">${items}</ul>`;
    }
    if (typeof val === "object") {
      if (val["@value"] !== undefined) {
        const lang = val["@language"] ? ` <small class="text-muted">(${this.escapeHtml(val["@language"])})</small>` : "";
        return `${this.escapeHtml(String(val["@value"]))}${lang}`;
      }
      return `<code>${this.escapeHtml(JSON.stringify(val))}</code>`;
    }
    return this.escapeHtml(String(val));
  }

  escapeHtml(str) {
    if (str === null || str === undefined) return "";
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }
}
