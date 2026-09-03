/**
 * <ontoportal-tree> Custom Element
 * Accessible ARIA 1.2 Tree widget with lazy child loading, keyboard navigation, and embedded search.
 */

import { OntoPortalClient } from '../../sdk/ontoportal_client.js';

function safeNodeId(nodeId) {
  if (typeof CSS !== 'undefined' && CSS.escape) return CSS.escape(nodeId);
  return encodeURIComponent(nodeId);
}

export class OntoPortalTree extends HTMLElement {
  static get observedAttributes() {
    return ['api-url', 'api-key', 'ontology', 'starting-class', 'selectable', 'searchable', 'theme'];
  }

  constructor() {
    super();
    this.attachShadow({ mode: 'open' });

    this._client = null;
    this._nodes = new Map(); // id -> nodeData
    this._selectedId = null;
    this._focusedId = null;
    this._rootIds = [];

    this._onTreeKeyDown = this._onTreeKeyDown.bind(this);
    this._onSearchInput = this._onSearchInput.bind(this);
  }

  connectedCallback() {
    this._initClient();
    this._render();
    this.reload();
  }

  attributeChangedCallback(name, oldValue, newValue) {
    if (oldValue === newValue) return;
    if (name === 'api-url' || name === 'api-key') {
      this._initClient();
    } else if (name === 'ontology') {
      this.reload();
    }
  }

  _initClient() {
    const apiURL = this.getAttribute('api-url') || (typeof window !== 'undefined' && window.ONTOPORTAL_API_URL) || '';
    const apiKey = this.getAttribute('api-key') || (typeof window !== 'undefined' && window.ONTOPORTAL_API_KEY) || '';
    this._client = new OntoPortalClient({ apiURL, apiKey });
  }

  async reload() {
    const ontology = this.getAttribute('ontology');
    if (!ontology || !this._client || !this._containerEl) return;

    this._nodes.clear();
    this._rootIds = [];
    this._selectedId = null;
    this._focusedId = null;

    this._setLoading(true);
    try {
      const startingClass = this.getAttribute('starting-class');
      if (startingClass) {
        // Load starting class and its children
        const classData = await this._client.getClass(ontology, startingClass);
        const nodeId = classData['@id'] || classData.id;
        this._nodes.set(nodeId, {
          ...classData,
          id: nodeId,
          label: classData.prefLabel || classData.name || nodeId,
          expanded: true,
          loaded: false,
          children: []
        });
        this._rootIds = [nodeId];
        await this._loadNodeChildren(nodeId);
      } else {
        // Load ontology roots
        const rootsData = await this._client.getRoots(ontology);
        const roots = Array.isArray(rootsData) ? rootsData : (rootsData.collection || []);
        this._rootIds = roots.map((root) => {
          const id = root['@id'] || root.id;
          this._nodes.set(id, {
            ...root,
            id,
            label: root.prefLabel || root.name || id,
            expanded: false,
            loaded: false,
            children: []
          });
          return id;
        });
      }
      this._renderTree();
    } catch (err) {
      this._renderError(err.message || 'Failed to load ontology hierarchy');
    } finally {
      this._setLoading(false);
    }
  }

  async _loadNodeChildren(nodeId) {
    const node = this._nodes.get(nodeId);
    if (!node || node.loaded) return;

    const ontology = this.getAttribute('ontology');
    try {
      node.loading = true;
      this._updateNodeDOM(nodeId);

      const childrenData = await this._client.getChildren(ontology, nodeId);
      const list = Array.isArray(childrenData) ? childrenData : (childrenData.collection || []);

      node.children = list.map((child) => {
        const id = child['@id'] || child.id;
        if (!this._nodes.has(id)) {
          this._nodes.set(id, {
            ...child,
            id,
            parentId: nodeId,
            label: child.prefLabel || child.name || id,
            expanded: false,
            loaded: false,
            children: []
          });
        }
        return id;
      });

      node.loaded = true;
      node.hasChildren = node.children.length > 0;
    } catch (err) {
      console.error(`Failed to load children for ${nodeId}:`, err);
      node.error = err.message;
    } finally {
      node.loading = false;
      this._updateNodeDOM(nodeId);
    }
  }

  _render() {
    const searchable = this.getAttribute('searchable') !== 'false';

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
          padding: 12px;
          box-sizing: border-box;
          max-height: var(--op-tree-max-height, 500px);
          overflow-y: auto;
        }
        *, *::before, *::after {
          box-sizing: inherit;
        }
        .op-tree-search {
          margin-bottom: 10px;
          position: relative;
        }
        .op-tree-search-input {
          width: 100%;
          padding: 6px 10px;
          border: 1px solid var(--op-border-color, #cbd5e1);
          border-radius: 6px;
          font-size: 13px;
          outline: none;
        }
        .op-tree-search-input:focus {
          border-color: var(--op-primary-color, #1a7f5a);
          box-shadow: 0 0 0 2px rgba(26, 127, 90, 0.15);
        }
        .op-tree-container {
          list-style: none;
          margin: 0;
          padding: 0;
        }
        .op-tree-node {
          list-style: none;
          margin: 0;
          padding: 0;
        }
        .op-node-row {
          display: flex;
          align-items: center;
          gap: 6px;
          padding: 4px 6px;
          border-radius: 4px;
          cursor: pointer;
          user-select: none;
          transition: background 0.1s ease;
        }
        .op-node-row:hover {
          background: #f1f5f9;
        }
        .op-node-row.selected {
          background: #e6f4ea;
          color: #0d6832;
          font-weight: 500;
        }
        .op-node-row:focus-visible, .op-node-row.focused {
          outline: 2px solid var(--op-primary-color, #1a7f5a);
          outline-offset: -1px;
        }
        .op-toggle-btn {
          width: 18px;
          height: 18px;
          display: inline-flex;
          align-items: center;
          justify-content: center;
          border: none;
          background: none;
          cursor: pointer;
          font-size: 10px;
          color: #64748b;
          border-radius: 3px;
          padding: 0;
          line-height: 1;
        }
        .op-toggle-btn:hover {
          background: #e2e8f0;
          color: #1e293b;
        }
        .op-toggle-placeholder {
          width: 18px;
          height: 18px;
          display: inline-block;
        }
        .op-node-icon {
          font-size: 12px;
          color: #94a3b8;
        }
        .op-node-label {
          flex: 1;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
        }
        .op-node-children {
          list-style: none;
          margin: 0;
          padding-left: 18px;
          display: none;
        }
        .op-node-children.expanded {
          display: block;
        }
        .op-spinner {
          width: 12px;
          height: 12px;
          border: 2px solid #cbd5e1;
          border-top-color: #1a7f5a;
          border-radius: 50%;
          animation: op-spin 0.6s linear infinite;
        }
        @keyframes op-spin {
          to { transform: rotate(360deg); }
        }
        .op-tree-loading, .op-tree-error, .op-tree-empty {
          padding: 16px;
          text-align: center;
          color: #64748b;
          font-size: 13px;
        }
        .op-tree-error {
          color: #dc2626;
        }
      </style>

      ${searchable ? `
        <div class="op-tree-search">
          <input type="text" class="op-tree-search-input" placeholder="Filter tree..." aria-label="Filter tree nodes" />
        </div>
      ` : ''}

      <div class="op-tree-wrapper">
        <ul class="op-tree-container" role="tree" tabindex="0" aria-label="Ontology Tree"></ul>
      </div>
    `;

    this._containerEl = this.shadowRoot.querySelector('.op-tree-container');
    this._containerEl.addEventListener('keydown', this._onTreeKeyDown);

    if (searchable) {
      const searchInput = this.shadowRoot.querySelector('.op-tree-search-input');
      searchInput.addEventListener('input', this._onSearchInput);
    }
  }

  _setLoading(loading) {
    if (!this._containerEl) return;
    if (loading) {
      this._containerEl.innerHTML = '<div class="op-tree-loading"><div class="op-spinner" style="display:inline-block; margin-right:8px;"></div>Loading hierarchy...</div>';
    }
  }

  _renderError(message) {
    if (!this._containerEl) return;
    this._containerEl.innerHTML = `<div class="op-tree-error">${message}</div>`;
  }

  _renderTree() {
    this._containerEl.innerHTML = '';
    if (this._rootIds.length === 0) {
      this._containerEl.innerHTML = '<div class="op-tree-empty">No root classes available.</div>';
      return;
    }

    this._rootIds.forEach((id) => {
      const nodeEl = this._createNodeElement(id);
      this._containerEl.appendChild(nodeEl);
    });

    if (this._rootIds.length > 0 && !this._focusedId) {
      this._focusedId = this._rootIds[0];
    }
  }

  _createNodeElement(nodeId) {
    const node = this._nodes.get(nodeId);
    if (!node) return document.createElement('li');

    const li = document.createElement('li');
    li.className = 'op-tree-node';
    li.setAttribute('role', 'treeitem');
    li.setAttribute('id', `op-tree-${safeNodeId(nodeId)}`);
    li.setAttribute('aria-selected', this._selectedId === nodeId ? 'true' : 'false');
    li.setAttribute('aria-expanded', node.hasChildren !== false ? (node.expanded ? 'true' : 'false') : 'false');

    const row = document.createElement('div');
    row.className = `op-node-row ${this._selectedId === nodeId ? 'selected' : ''} ${this._focusedId === nodeId ? 'focused' : ''}`;
    row.dataset.id = nodeId;

    // Toggle button or spacer
    const hasChildren = node.hasChildren !== false;
    if (hasChildren) {
      const toggle = document.createElement('button');
      toggle.className = 'op-toggle-btn';
      toggle.setAttribute('aria-label', node.expanded ? 'Collapse node' : 'Expand node');
      toggle.innerHTML = node.loading ? '<div class="op-spinner"></div>' : (node.expanded ? '&#x25BC;' : '&#x25B6;');
      toggle.addEventListener('click', (e) => {
        e.stopPropagation();
        this.toggleNode(nodeId);
      });
      row.appendChild(toggle);
    } else {
      const spacer = document.createElement('span');
      spacer.className = 'op-toggle-placeholder';
      row.appendChild(spacer);
    }

    // Label
    const labelSpan = document.createElement('span');
    labelSpan.className = 'op-node-label';
    labelSpan.textContent = node.label || nodeId;
    row.appendChild(labelSpan);

    row.addEventListener('click', () => {
      this.selectNode(nodeId);
    });

    li.appendChild(row);

    // Children sublist
    const ul = document.createElement('ul');
    ul.className = `op-node-children ${node.expanded ? 'expanded' : ''}`;
    ul.setAttribute('role', 'group');

    if (node.expanded && node.children && node.children.length > 0) {
      node.children.forEach((childId) => {
        ul.appendChild(this._createNodeElement(childId));
      });
    }

    li.appendChild(ul);
    return li;
  }

  _updateNodeDOM(nodeId) {
    const existing = this.shadowRoot.getElementById(`op-tree-${safeNodeId(nodeId)}`);
    if (!existing) return;

    const fresh = this._createNodeElement(nodeId);
    existing.replaceWith(fresh);
  }

  async toggleNode(nodeId) {
    const node = this._nodes.get(nodeId);
    if (!node) return;

    if (node.expanded) {
      node.expanded = false;
      this._updateNodeDOM(nodeId);
      this.dispatchEvent(new CustomEvent('ontoportal:node-collapsed', { bubbles: true, composed: true, detail: { nodeId, node } }));
    } else {
      node.expanded = true;
      if (!node.loaded) {
        await this._loadNodeChildren(nodeId);
      } else {
        this._updateNodeDOM(nodeId);
      }
      this.dispatchEvent(new CustomEvent('ontoportal:node-expanded', { bubbles: true, composed: true, detail: { nodeId, node } }));
    }
  }

  async expandNode(nodeId) {
    const node = this._nodes.get(nodeId);
    if (node && !node.expanded) {
      await this.toggleNode(nodeId);
    }
  }

  collapseNode(nodeId) {
    const node = this._nodes.get(nodeId);
    if (node && node.expanded) {
      this.toggleNode(nodeId);
    }
  }

  selectNode(nodeId) {
    const node = this._nodes.get(nodeId);
    if (!node) return;

    this._selectedId = nodeId;
    this._focusedId = nodeId;

    this.shadowRoot.querySelectorAll('.op-node-row').forEach((r) => {
      const match = r.dataset.id === nodeId;
      r.classList.toggle('selected', match);
      r.classList.toggle('focused', match);
    });

    this.dispatchEvent(
      new CustomEvent('ontoportal:node-selected', {
        bubbles: true,
        composed: true,
        detail: {
          nodeId,
          concept: node
        }
      })
    );
  }

  _onTreeKeyDown(e) {
    if (!this._focusedId) return;

    const visibleRows = Array.from(this.shadowRoot.querySelectorAll('.op-node-row'));
    const currentIndex = visibleRows.findIndex((r) => r.dataset.id === this._focusedId);
    if (currentIndex === -1) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      const nextIndex = Math.min(currentIndex + 1, visibleRows.length - 1);
      this._focusRow(visibleRows[nextIndex]);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      const prevIndex = Math.max(currentIndex - 1, 0);
      this._focusRow(visibleRows[prevIndex]);
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      const node = this._nodes.get(this._focusedId);
      if (node && !node.expanded && node.hasChildren !== false) {
        this.toggleNode(this._focusedId);
      }
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      const node = this._nodes.get(this._focusedId);
      if (node && node.expanded) {
        this.toggleNode(this._focusedId);
      } else if (node && node.parentId) {
        const parentRow = visibleRows.find((r) => r.dataset.id === node.parentId);
        if (parentRow) this._focusRow(parentRow);
      }
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      this.selectNode(this._focusedId);
    }
  }

  _focusRow(rowEl) {
    if (!rowEl) return;
    this._focusedId = rowEl.dataset.id;
    this.shadowRoot.querySelectorAll('.op-node-row').forEach((r) => r.classList.remove('focused'));
    rowEl.classList.add('focused');
    rowEl.scrollIntoView({ block: 'nearest' });
  }

  _onSearchInput(e) {
    const filter = e.target.value.toLowerCase().trim();
    const rows = this.shadowRoot.querySelectorAll('.op-node-row');

    rows.forEach((row) => {
      const label = row.querySelector('.op-node-label')?.textContent.toLowerCase() || '';
      const visible = !filter || label.includes(filter);
      const li = row.closest('li.op-tree-node');
      if (li) {
        li.style.display = visible ? '' : 'none';
      }
    });
  }
}

if (typeof customElements !== 'undefined' && !customElements.get('ontoportal-tree')) {
  customElements.define('ontoportal-tree', OntoPortalTree);
}

export default OntoPortalTree;
