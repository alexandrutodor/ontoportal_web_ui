/**
 * <ontoportal-concept-card> Custom Element
 * Self-contained card rendering ontology concept details, definitions, synonyms, and CURIE/IRI copy actions.
 */

import { OntoPortalClient } from '../../sdk/ontoportal_client.js';

export class OntoPortalConceptCard extends HTMLElement {
  static get observedAttributes() {
    return ['api-url', 'api-key', 'ontology', 'concept-id', 'compact', 'portal-url'];
  }

  constructor() {
    super();
    this.attachShadow({ mode: 'open' });

    this._client = null;
    this._concept = null;
  }

  connectedCallback() {
    this._initClient();
    this._render();
    this.loadConcept();
  }

  attributeChangedCallback(name, oldValue, newValue) {
    if (oldValue === newValue) return;
    if (name === 'api-url' || name === 'api-key') {
      this._initClient();
    } else if (name === 'ontology' || name === 'concept-id') {
      this.loadConcept();
    }
  }

  _initClient() {
    const apiURL = this.getAttribute('api-url') || (typeof window !== 'undefined' && window.ONTOPORTAL_API_URL) || '';
    const apiKey = this.getAttribute('api-key') || (typeof window !== 'undefined' && window.ONTOPORTAL_API_KEY) || '';
    this._client = new OntoPortalClient({ apiURL, apiKey });
  }

  async loadConcept() {
    const ontology = this.getAttribute('ontology');
    const conceptId = this.getAttribute('concept-id');
    if (!ontology || !conceptId || !this._client || !this._containerEl) return;

    this._setLoading(true);
    try {
      this._concept = await this._client.getClass(ontology, conceptId);
      this._renderCard();
      this.dispatchEvent(
        new CustomEvent('ontoportal:concept-loaded', {
          bubbles: true,
          composed: true,
          detail: { concept: this._concept }
        })
      );
    } catch (err) {
      this._renderError(err.message || 'Failed to load concept');
    } finally {
      this._setLoading(false);
    }
  }

  _render() {
    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
          font-family: var(--op-font-family, system-ui, -apple-system, sans-serif);
          font-size: 14px;
          color: var(--op-text-color, #1e293b);
          background: var(--op-bg-color, #ffffff);
          border: 1px solid var(--op-border-color, #e2e8f0);
          border-radius: 8px;
          box-sizing: border-box;
          box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05);
          overflow: hidden;
        }
        *, *::before, *::after {
          box-sizing: inherit;
        }
        .op-card-container {
          padding: 14px 16px;
        }
        .op-card-header {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 12px;
          margin-bottom: 8px;
        }
        .op-card-title-group {
          flex: 1;
        }
        .op-card-title {
          font-size: 16px;
          font-weight: 600;
          color: #0f172a;
          margin: 0 0 4px 0;
          line-height: 1.3;
        }
        .op-card-badge {
          display: inline-block;
          font-size: 11px;
          font-weight: 600;
          padding: 2px 8px;
          border-radius: 9999px;
          background: #ecfdf5;
          color: #065f46;
          border: 1px solid #a7f3d0;
        }
        .op-card-uri-row {
          display: flex;
          align-items: center;
          gap: 6px;
          font-size: 12px;
          color: #64748b;
          margin-bottom: 12px;
          word-break: break-all;
        }
        .op-card-uri {
          font-family: ui-monospace, SFMono-Regular, monospace;
          background: #f8fafc;
          padding: 2px 6px;
          border-radius: 4px;
          border: 1px solid #f1f5f9;
        }
        .op-copy-btn {
          background: none;
          border: 1px solid #cbd5e1;
          border-radius: 4px;
          padding: 2px 6px;
          font-size: 11px;
          cursor: pointer;
          color: #475569;
          transition: all 0.1s ease;
        }
        .op-copy-btn:hover {
          background: #f1f5f9;
          color: #0f172a;
        }
        .op-card-section {
          margin-bottom: 10px;
        }
        .op-section-label {
          font-size: 11px;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: #94a3b8;
          margin-bottom: 4px;
        }
        .op-section-content {
          font-size: 13px;
          color: #334155;
          line-height: 1.5;
        }
        .op-synonyms-list {
          display: flex;
          flex-wrap: wrap;
          gap: 4px;
          margin: 0;
          padding: 0;
          list-style: none;
        }
        .op-synonym-tag {
          font-size: 12px;
          background: #f1f5f9;
          color: #475569;
          padding: 2px 8px;
          border-radius: 4px;
        }
        .op-card-footer {
          margin-top: 14px;
          padding-top: 10px;
          border-top: 1px solid #f1f5f9;
          display: flex;
          align-items: center;
          justify-content: flex-end;
        }
        .op-portal-link {
          font-size: 12px;
          font-weight: 500;
          color: #1a7f5a;
          text-decoration: none;
          display: inline-flex;
          align-items: center;
          gap: 4px;
        }
        .op-portal-link:hover {
          text-decoration: underline;
        }
        .op-loading, .op-error {
          padding: 20px;
          text-align: center;
          color: #64748b;
        }
        .op-error {
          color: #dc2626;
        }
      </style>
      <div class="op-card-container">
        <div class="op-loading">Select or specify a concept to display...</div>
      </div>
    `;

    this._containerEl = this.shadowRoot.querySelector('.op-card-container');
  }

  _setLoading(loading) {
    if (!this._containerEl) return;
    if (loading) {
      this._containerEl.innerHTML = '<div class="op-loading">Loading concept details...</div>';
    }
  }

  _renderError(message) {
    if (!this._containerEl) return;
    this._containerEl.innerHTML = `<div class="op-error">${message}</div>`;
  }

  _renderCard() {
    if (!this._concept) return;

    const ontology = this.getAttribute('ontology') || '';
    const label = this._concept.prefLabel || this._concept.name || this._concept['@id'] || 'Unnamed Concept';
    const uri = this._concept['@id'] || this._concept.id || '';
    const definitions = this._concept.definition || [];
    const synonyms = this._concept.synonym || [];
    const portalUrl = this.getAttribute('portal-url') || (typeof window !== 'undefined' ? window.location.origin : '');
    const conceptLink = `${portalUrl}/ontologies/${encodeURIComponent(ontology)}?p=classes&conceptid=${encodeURIComponent(uri)}`;

    const defHtml = Array.isArray(definitions) && definitions.length > 0
      ? definitions.map((d) => `<p class="op-section-content">${escapeHTML(d)}</p>`).join('')
      : (typeof definitions === 'string' && definitions.trim() ? `<p class="op-section-content">${escapeHTML(definitions)}</p>` : '<p class="op-section-content" style="color:#94a3b8; font-style:italic;">No definition provided</p>');

    const synList = Array.isArray(synonyms) ? synonyms : (typeof synonyms === 'string' ? synonyms.split(',') : []);
    const synHtml = synList.length > 0
      ? `<div class="op-card-section">
           <div class="op-section-label">Synonyms</div>
           <ul class="op-synonyms-list">
             ${synList.slice(0, 8).map((s) => `<li class="op-synonym-tag">${escapeHTML(s.trim())}</li>`).join('')}
             ${synList.length > 8 ? `<li class="op-synonym-tag">+${synList.length - 8} more</li>` : ''}
           </ul>
         </div>`
      : '';

    this._containerEl.innerHTML = `
      <div class="op-card-header">
        <div class="op-card-title-group">
          <h3 class="op-card-title">${escapeHTML(label)}</h3>
          <div class="op-card-uri-row">
            <span class="op-card-uri">${escapeHTML(uri)}</span>
            <button type="button" class="op-copy-btn" id="op-copy-uri" aria-label="Copy URI">Copy</button>
          </div>
        </div>
        ${ontology ? `<span class="op-card-badge">${escapeHTML(ontology)}</span>` : ''}
      </div>

      <div class="op-card-section">
        <div class="op-section-label">Definition</div>
        ${defHtml}
      </div>

      ${synHtml}

      <div class="op-card-footer">
        <a href="${conceptLink}" target="_blank" rel="noopener noreferrer" class="op-portal-link">
          View in Portal &rarr;
        </a>
      </div>
    `;

    const copyBtn = this._containerEl.querySelector('#op-copy-uri');
    if (copyBtn) {
      copyBtn.addEventListener('click', async () => {
        try {
          await navigator.clipboard.writeText(uri);
          copyBtn.textContent = 'Copied!';
          setTimeout(() => (copyBtn.textContent = 'Copy'), 1500);
        } catch (_) {
          copyBtn.textContent = 'Failed';
        }
      });
    }
  }
}

function escapeHTML(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

if (typeof customElements !== 'undefined' && !customElements.get('ontoportal-concept-card')) {
  customElements.define('ontoportal-concept-card', OntoPortalConceptCard);
}

export default OntoPortalConceptCard;
