/**
 * <ontoportal-autocomplete> Custom Element
 * Accessible ARIA 1.2 Combobox with form association, Shadow DOM, and legacy hidden input sync.
 */

import { OntoPortalClient } from '../../sdk/ontoportal_client.js';

export class OntoPortalAutocomplete extends HTMLElement {
  static formAssociated = true;

  static get observedAttributes() {
    return [
      'api-url',
      'api-key',
      'ontologies',
      'value-field',
      'placeholder',
      'debounce-ms',
      'name',
      'disabled',
      'required',
      'value'
    ];
  }

  constructor() {
    super();
    if (this.attachInternals) {
      this._internals = this.attachInternals();
    }
    this.attachShadow({ mode: 'open' });

    this._client = null;
    this._value = '';
    this._selectedConcept = null;
    this._results = [];
    this._activeIndex = -1;
    this._debounceTimer = null;
    this._abortController = null;

    this._onInput = this._onInput.bind(this);
    this._onKeyDown = this._onKeyDown.bind(this);
    this._onFocus = this._onFocus.bind(this);
    this._onBlur = this._onBlur.bind(this);
    this._onClearClick = this._onClearClick.bind(this);
  }

  connectedCallback() {
    this._initClient();
    this._render();
    this._syncLightDomInputs();
  }

  disconnectedCallback() {
    clearTimeout(this._debounceTimer);
    if (this._abortController) this._abortController.abort();
  }

  attributeChangedCallback(name, oldValue, newValue) {
    if (oldValue === newValue) return;
    if (name === 'api-url' || name === 'api-key') {
      this._initClient();
    } else if (name === 'value') {
      this._value = newValue || '';
      if (this._inputEl) this._inputEl.value = this._value;
      if (this._internals) this._internals.setFormValue(this._value);
    } else if (name === 'placeholder' && this._inputEl) {
      this._inputEl.placeholder = newValue;
    } else if (name === 'disabled' && this._inputEl) {
      this._inputEl.disabled = this.hasAttribute('disabled');
    }
  }

  // Form association getters / setters
  get form() {
    return this._internals ? this._internals.form : null;
  }
  get name() {
    return this.getAttribute('name') || '';
  }
  set name(val) {
    this.setAttribute('name', val);
  }
  get value() {
    return this._value;
  }
  set value(val) {
    this._value = val || '';
    this.setAttribute('value', this._value);
    if (this._inputEl) this._inputEl.value = this._value;
    if (this._internals) this._internals.setFormValue(this._value);
    this._syncLightDomInputs();
  }
  get selectedConcept() {
    return this._selectedConcept;
  }

  _initClient() {
    const apiURL = this.getAttribute('api-url') || (typeof window !== 'undefined' && window.ONTOPORTAL_API_URL) || '';
    const apiKey = this.getAttribute('api-key') || (typeof window !== 'undefined' && window.ONTOPORTAL_API_KEY) || '';
    this._client = new OntoPortalClient({ apiURL, apiKey });
  }

  _syncLightDomInputs() {
    const fieldName = this.getAttribute('name');
    if (!fieldName) return;

    const concept = this._selectedConcept || {};
    const updates = [
      { id: `${fieldName}_bioportal_preferred_name`, value: concept.prefLabel || '' },
      { id: `${fieldName}_bioportal_concept_id`, value: concept['@id'] || concept.id || this._value || '' },
      { id: `${fieldName}_bioportal_ontology_id`, value: concept.links?.ontology ? concept.links.ontology.split('/').pop() : (this.getAttribute('ontologies') || '') },
      { id: `${fieldName}_bioportal_full_id`, value: concept['@id'] || concept.id || '' }
    ];

    updates.forEach(({ id, value }) => {
      let hidden = this.querySelector(`input#${id}`);
      if (!hidden) {
        hidden = document.createElement('input');
        hidden.type = 'hidden';
        hidden.id = id;
        hidden.name = id;
        this.appendChild(hidden);
      }
      hidden.value = value;
    });
  }

  _render() {
    const placeholder = this.getAttribute('placeholder') || 'Search classes...';
    const disabled = this.hasAttribute('disabled');

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
          position: relative;
          font-family: var(--op-font-family, system-ui, -apple-system, sans-serif);
          font-size: 14px;
          color: var(--op-text-color, #1e293b);
          box-sizing: border-box;
        }
        *, *::before, *::after {
          box-sizing: inherit;
        }
        .op-combobox {
          position: relative;
          width: 100%;
        }
        .op-input-wrapper {
          display: flex;
          align-items: center;
          border: 1px solid var(--op-border-color, #cbd5e1);
          border-radius: 6px;
          background: var(--op-bg-color, #ffffff);
          transition: border-color 0.15s ease, box-shadow 0.15s ease;
          padding: 0 8px;
        }
        .op-input-wrapper:focus-within {
          border-color: var(--op-primary-color, #1a7f5a);
          box-shadow: 0 0 0 3px rgba(26, 127, 90, 0.15);
        }
        .op-input {
          flex: 1;
          border: none;
          outline: none;
          background: transparent;
          font-family: inherit;
          font-size: inherit;
          color: inherit;
          padding: 8px 4px;
          min-width: 0;
        }
        .op-input:disabled {
          cursor: not-allowed;
          opacity: 0.6;
        }
        .op-clear-btn {
          background: none;
          border: none;
          cursor: pointer;
          font-size: 16px;
          color: #94a3b8;
          padding: 2px 6px;
          line-height: 1;
          display: none;
        }
        .op-clear-btn:hover {
          color: #475569;
        }
        .op-clear-btn.visible {
          display: block;
        }
        .op-spinner {
          display: none;
          width: 14px;
          height: 14px;
          border: 2px solid #e2e8f0;
          border-top-color: var(--op-primary-color, #1a7f5a);
          border-radius: 50%;
          animation: op-spin 0.6s linear infinite;
          margin-right: 4px;
        }
        .op-spinner.loading {
          display: inline-block;
        }
        @keyframes op-spin {
          to { transform: rotate(360deg); }
        }
        .op-dropdown {
          position: absolute;
          top: calc(100% + 4px);
          left: 0;
          right: 0;
          max-height: 280px;
          overflow-y: auto;
          background: var(--op-bg-color, #ffffff);
          border: 1px solid var(--op-border-color, #cbd5e1);
          border-radius: 6px;
          box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
          z-index: 1000;
          display: none;
          list-style: none;
          margin: 0;
          padding: 4px 0;
        }
        .op-dropdown.open {
          display: block;
        }
        .op-option {
          padding: 8px 12px;
          cursor: pointer;
          display: flex;
          flex-direction: column;
          gap: 2px;
          transition: background-color 0.1s ease;
        }
        .op-option:hover, .op-option.active {
          background-color: #f1f5f9;
        }
        .op-option-header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          font-weight: 500;
        }
        .op-option-label {
          color: var(--op-text-color, #1e293b);
        }
        .op-option-ontology {
          font-size: 11px;
          font-weight: 600;
          padding: 1px 6px;
          border-radius: 4px;
          background: #e2e8f0;
          color: #475569;
        }
        .op-option-uri {
          font-size: 11px;
          color: #64748b;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .op-no-results, .op-error {
          padding: 10px 12px;
          color: #64748b;
          font-style: italic;
          text-align: center;
        }
        .op-error {
          color: #dc2626;
        }
      </style>

      <div class="op-combobox">
        <div class="op-input-wrapper">
          <input
            type="text"
            class="op-input"
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="false"
            aria-haspopup="listbox"
            placeholder="${placeholder}"
            ${disabled ? 'disabled' : ''}
            value="${this._value}"
          />
          <div class="op-spinner" aria-hidden="true"></div>
          <button type="button" class="op-clear-btn" aria-label="Clear selection">&times;</button>
        </div>
        <ul class="op-dropdown" role="listbox" aria-label="Ontology search results"></ul>
      </div>
    `;

    this._inputEl = this.shadowRoot.querySelector('.op-input');
    this._dropdownEl = this.shadowRoot.querySelector('.op-dropdown');
    this._spinnerEl = this.shadowRoot.querySelector('.op-spinner');
    this._clearBtn = this.shadowRoot.querySelector('.op-clear-btn');

    this._inputEl.addEventListener('input', this._onInput);
    this._inputEl.addEventListener('keydown', this._onKeyDown);
    this._inputEl.addEventListener('focus', this._onFocus);
    this._inputEl.addEventListener('blur', this._onBlur);
    this._clearBtn.addEventListener('click', this._onClearClick);

    if (this._value) {
      this._clearBtn.classList.add('visible');
    }
  }

  _onInput(e) {
    const val = e.target.value;
    this._value = val;
    this._clearBtn.classList.toggle('visible', val.length > 0);

    clearTimeout(this._debounceTimer);
    if (!val || val.trim().length < 2) {
      this._closeDropdown();
      return;
    }

    const delay = parseInt(this.getAttribute('debounce-ms') || '250', 10);
    this._debounceTimer = setTimeout(() => this._executeSearch(val), delay);
  }

  async _executeSearch(query) {
    if (this._abortController) this._abortController.abort();
    this._abortController = new AbortController();

    this._spinnerEl.classList.add('loading');
    try {
      const ontologies = this.getAttribute('ontologies') || '';
      const data = await this._client.search(query, {
        ontologies,
        pageSize: 15,
        signal: this._abortController.signal
      });

      this._results = (data && data.collection) ? data.collection : [];
      this._renderDropdown();
    } catch (err) {
      if (err.status === 408 || err.name === 'AbortError') return;
      this._renderError(err.message || 'Error searching classes');
    } finally {
      this._spinnerEl.classList.remove('loading');
    }
  }

  _renderDropdown() {
    this._dropdownEl.innerHTML = '';
    this._activeIndex = -1;

    if (this._results.length === 0) {
      const emptyLi = document.createElement('li');
      emptyLi.className = 'op-no-results';
      emptyLi.textContent = 'No matching classes found';
      this._dropdownEl.appendChild(emptyLi);
      this._openDropdown();
      return;
    }

    this._results.forEach((item, index) => {
      const li = document.createElement('li');
      li.className = 'op-option';
      li.setAttribute('role', 'option');
      li.setAttribute('id', `op-option-${index}`);
      li.dataset.index = index;

      const ontAcronym = item.links?.ontology ? item.links.ontology.split('/').pop() : '';
      const prefLabel = item.prefLabel || item.name || item['@id'];
      const uri = item['@id'] || item.id || '';

      li.innerHTML = `
        <div class="op-option-header">
          <span class="op-option-label">${prefLabel}</span>
          ${ontAcronym ? `<span class="op-option-ontology">${ontAcronym}</span>` : ''}
        </div>
        <div class="op-option-uri">${uri}</div>
      `;

      li.addEventListener('mousedown', (e) => {
        e.preventDefault(); // Prevent blur before click
        this._selectItem(index);
      });

      this._dropdownEl.appendChild(li);
    });

    this._openDropdown();
  }

  _renderError(message) {
    this._dropdownEl.innerHTML = `<li class="op-error">${message}</li>`;
    this._openDropdown();
  }

  _openDropdown() {
    this._dropdownEl.classList.add('open');
    this._inputEl.setAttribute('aria-expanded', 'true');
  }

  _closeDropdown() {
    this._dropdownEl.classList.remove('open');
    this._inputEl.setAttribute('aria-expanded', 'false');
    this._inputEl.removeAttribute('aria-activedescendant');
    this._activeIndex = -1;
  }

  _onKeyDown(e) {
    if (!this._dropdownEl.classList.contains('open')) {
      if (e.key === 'ArrowDown' || e.key === 'Enter') {
        this._onInput({ target: this._inputEl });
      }
      return;
    }

    const options = this.shadowRoot.querySelectorAll('.op-option');
    if (options.length === 0) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      this._activeIndex = (this._activeIndex + 1) % options.length;
      this._highlightOption(options);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      this._activeIndex = (this._activeIndex - 1 + options.length) % options.length;
      this._highlightOption(options);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      if (this._activeIndex >= 0 && this._activeIndex < options.length) {
        this._selectItem(this._activeIndex);
      }
    } else if (e.key === 'Escape') {
      this._closeDropdown();
    }
  }

  _highlightOption(options) {
    options.forEach((opt, idx) => {
      const active = idx === this._activeIndex;
      opt.classList.toggle('active', active);
      opt.setAttribute('aria-selected', active ? 'true' : 'false');
      if (active) {
        opt.scrollIntoView({ block: 'nearest' });
        this._inputEl.setAttribute('aria-activedescendant', opt.id);
      }
    });
  }

  _selectItem(index) {
    const item = this._results[index];
    if (!item) return;

    this._selectedConcept = item;
    const valueField = this.getAttribute('value-field') || 'uri';

    let displayVal = item['@id'] || item.id;
    if (valueField === 'shortid') {
      displayVal = (item['@id'] || item.id || '').split('/').pop().split('#').pop();
    } else if (valueField === 'name') {
      displayVal = item.prefLabel || item.name || displayVal;
    }

    this.value = displayVal;
    this._inputEl.value = displayVal;
    this._clearBtn.classList.add('visible');
    this._closeDropdown();
    this._syncLightDomInputs();

    this.dispatchEvent(
      new CustomEvent('ontoportal:select', {
        bubbles: true,
        composed: true,
        detail: {
          concept: item,
          value: displayVal,
          valueField
        }
      })
    );
  }

  _onClearClick() {
    this.value = '';
    this._selectedConcept = null;
    this._inputEl.value = '';
    this._clearBtn.classList.remove('visible');
    this._closeDropdown();
    this._syncLightDomInputs();

    this.dispatchEvent(
      new CustomEvent('ontoportal:clear', {
        bubbles: true,
        composed: true
      })
    );
    this._inputEl.focus();
  }

  _onFocus() {
    if (this._results.length > 0 && this._inputEl.value.trim().length >= 2) {
      this._openDropdown();
    }
  }

  _onBlur() {
    // Delay slightly to let click register
    setTimeout(() => this._closeDropdown(), 150);
  }
}

if (typeof customElements !== 'undefined' && !customElements.get('ontoportal-autocomplete')) {
  customElements.define('ontoportal-autocomplete', OntoPortalAutocomplete);
}

export default OntoPortalAutocomplete;
