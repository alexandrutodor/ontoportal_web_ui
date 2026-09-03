/**
 * Modern Widgets & SDK Test Suite (Node.js)
 * Tests OntoPortalClient, LRU Cache, Custom Elements, Shim, and View Templates.
 */

import assert from 'node:assert';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '../..');

// ----------------------------------------------------
// Minimal DOM Mock for Node Environment
// ----------------------------------------------------
class MockElement {
  constructor(tagName = 'DIV') {
    this.tagName = (tagName || 'DIV').toUpperCase();
    this.attributes = new Map();
    this.children = [];
    this.parentElement = null;
    this.shadowRoot = null;
    this.classList = {
      _classes: new Set(),
      add: (c) => this.classList._classes.add(c),
      remove: (c) => this.classList._classes.delete(c),
      contains: (c) => this.classList._classes.has(c),
      toggle: (c, force) => {
        if (force === undefined) {
          if (this.classList._classes.has(c)) this.classList._classes.delete(c);
          else this.classList._classes.add(c);
        } else if (force) {
          this.classList._classes.add(c);
        } else {
          this.classList._classes.delete(c);
        }
      }
    };
    this.dataset = {};
    this.listeners = new Map();
    this.style = {};
    this.value = '';
    this.placeholder = '';
    this.textContent = '';
  }

  get id() {
    return this.getAttribute('id') || this._id || '';
  }
  set id(val) {
    this._id = val;
    this.setAttribute('id', val);
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }
  setAttribute(name, val) {
    const old = this.attributes.get(name);
    this.attributes.set(name, String(val));
    if (name === 'id') this._id = String(val);
    if (typeof this.attributeChangedCallback === 'function' && old !== String(val)) {
      this.attributeChangedCallback(name, old, String(val));
    }
  }
  hasAttribute(name) {
    return this.attributes.has(name);
  }
  removeAttribute(name) {
    this.attributes.delete(name);
  }

  attachShadow() {
    this.shadowRoot = new MockElement('shadow-root');
    return this.shadowRoot;
  }

  appendChild(child) {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }

  querySelector(selector) {
    if (selector.includes('#')) {
      const parts = selector.split('#');
      const tag = parts[0];
      const id = parts[1];
      return this._findRecursive((el) => (!tag || el.tagName.toLowerCase() === tag.toLowerCase()) && el.id === id);
    }
    if (selector.startsWith('.')) {
      const cls = selector.slice(1);
      return this._findRecursive((el) => el.classList.contains(cls));
    }
    return this._findRecursive((el) => el.tagName.toLowerCase() === selector.toLowerCase());
  }

  querySelectorAll(selector) {
    const results = [];
    this._findAllRecursive(selector, results);
    return results;
  }

  getElementById(id) {
    return this._findRecursive((el) => el.id === id);
  }

  closest(selector) {
    let curr = this;
    while (curr) {
      if (selector.startsWith('.') && curr.classList.contains(selector.slice(1))) return curr;
      if (selector.startsWith('#') && curr.id === selector.slice(1)) return curr;
      if (curr.tagName.toLowerCase() === selector.toLowerCase()) return curr;
      curr = curr.parentElement;
    }
    return null;
  }

  _findRecursive(predicate) {
    for (const child of this.children) {
      if (predicate(child)) return child;
      const found = child._findRecursive(predicate);
      if (found) return found;
    }
    return null;
  }

  _findAllRecursive(selector, acc) {
    for (const child of this.children) {
      if (selector.startsWith('.') && child.classList.contains(selector.slice(1))) {
        acc.push(child);
      } else if (selector.startsWith('#') && child.id === selector.slice(1)) {
        acc.push(child);
      } else if (child.tagName.toLowerCase() === selector.toLowerCase()) {
        acc.push(child);
      }
      child._findAllRecursive(selector, acc);
    }
  }

  addEventListener(type, cb) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(cb);
  }

  dispatchEvent(event) {
    const list = this.listeners.get(event.type) || [];
    for (const cb of list) cb(event);
    return true;
  }

  focus() {}
  scrollIntoView() {}

  set innerHTML(html) {
    this._innerHTML = html;
    this.children = [];
    if (!html) return;

    // Lightweight tag scanner for mock elements
    const tagRegex = /<([a-zA-Z0-9-]+)([^>]*)>/g;
    let match;
    while ((match = tagRegex.exec(html)) !== null) {
      const tag = match[1];
      if (tag.toLowerCase() === 'style' || tag.toLowerCase() === 'script' || tag.startsWith('/')) continue;
      const attrsStr = match[2];
      const el = new MockElement(tag);

      const classMatch = attrsStr.match(/class=["']([^"']+)["']/);
      if (classMatch) {
        classMatch[1].split(/\s+/).forEach((c) => el.classList.add(c));
      }
      const idMatch = attrsStr.match(/id=["']([^"']+)["']/);
      if (idMatch) {
        el.id = idMatch[1];
      }
      this.appendChild(el);
    }
  }
  get innerHTML() {
    return this._innerHTML || '';
  }

  replaceWith(newEl) {
    if (!this.parentElement) return;
    const idx = this.parentElement.children.indexOf(this);
    if (idx !== -1) {
      this.parentElement.children[idx] = newEl;
      newEl.parentElement = this.parentElement;
    }
  }
}

globalThis.HTMLElement = MockElement;
globalThis.CSS = {
  escape: (s) => (s || '').replace(/[^a-zA-Z0-9_-]/g, '\\$&')
};

globalThis.CustomEvent = class CustomEvent {
  constructor(type, init = {}) {
    this.type = type;
    this.detail = init.detail;
    this.bubbles = !!init.bubbles;
  }
};

const definedElements = new Map();
globalThis.customElements = {
  define: (name, constructor) => definedElements.set(name, constructor),
  get: (name) => definedElements.get(name)
};

globalThis.document = {
  createElement: (tag) => {
    const CustomCtor = definedElements.get(tag);
    const el = CustomCtor ? new CustomCtor() : new MockElement(tag);
    el.tagName = tag.toUpperCase();
    return el;
  },
  head: new MockElement('head'),
  body: new MockElement('body'),
  addEventListener: () => {}
};

globalThis.window = {
  location: { origin: 'https://data.stage.matportal.org' },
  document: globalThis.document,
  customElements: globalThis.customElements
};

// ----------------------------------------------------
// Dynamic Imports of Modules
// ----------------------------------------------------
const { OntoPortalClient, OntoPortalError, SimpleLRUCache } = await import('../../app/javascript/sdk/ontoportal_client.js');
const { OntoPortalAutocomplete } = await import('../../app/javascript/components/widgets/ontoportal_autocomplete.js');
const { OntoPortalTree } = await import('../../app/javascript/components/widgets/ontoportal_tree.js');
const { OntoPortalConceptCard } = await import('../../app/javascript/components/widgets/ontoportal_concept_card.js');

let passedTests = 0;
let totalTests = 0;

function test(name, fn) {
  totalTests++;
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passedTests++;
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(err);
    process.exitCode = 1;
  }
}

async function asyncTest(name, fn) {
  totalTests++;
  try {
    await fn();
    console.log(`  ✓ ${name}`);
    passedTests++;
  } catch (err) {
    console.error(`  ✗ ${name}`);
    console.error(err);
    process.exitCode = 1;
  }
}

console.log('--- Running Modern Widgets & SDK Test Suite ---');

// 1. LRU Cache Tests
test('SimpleLRUCache: eviction and capacity', () => {
  const cache = new SimpleLRUCache(2);
  cache.set('a', 1);
  cache.set('b', 2);
  assert.strictEqual(cache.get('a'), 1);
  cache.set('c', 3); // should evict 'b' since 'a' was accessed last
  assert.strictEqual(cache.get('b'), undefined);
  assert.strictEqual(cache.get('a'), 1);
  assert.strictEqual(cache.get('c'), 3);
  cache.clear();
  assert.strictEqual(cache.get('a'), undefined);
});

// 2. OntoPortalClient URL construction & headers
test('OntoPortalClient: URL building with API key and query params', () => {
  const client = new OntoPortalClient({
    apiURL: 'https://data.stage.matportal.org',
    apiKey: 'test-api-token-123'
  });

  const url = client._buildURL('/search', { q: 'nano', ontologies: 'CHMO' });
  assert(url.includes('apikey=test-api-token-123'), 'Includes apikey in URL');
  assert(url.includes('q=nano'), 'Includes q query');
  assert(url.includes('ontologies=CHMO'), 'Includes ontologies param');
});

// 3. OntoPortalClient Fetch Mocking & Caching
await asyncTest('OntoPortalClient: search with mocked fetch and cache', async () => {
  let fetchCallCount = 0;
  const mockResponse = {
    collection: [
      { '@id': 'http://purl.obolibrary.org/obo/CHMO_0000001', prefLabel: 'spectroscopy' }
    ],
    page: 1,
    pageCount: 1
  };

  globalThis.fetch = async (url, opts) => {
    fetchCallCount++;
    assert(opts.headers['Authorization'].includes('test-token'));
    return {
      ok: true,
      status: 200,
      json: async () => mockResponse
    };
  };

  const client = new OntoPortalClient({
    apiURL: 'https://data.stage.matportal.org',
    apiKey: 'test-token'
  });

  const res1 = await client.search('spectroscopy', { ontologies: 'CHMO' });
  assert.strictEqual(res1.collection.length, 1);
  assert.strictEqual(res1.collection[0].prefLabel, 'spectroscopy');
  assert.strictEqual(fetchCallCount, 1);

  // Second call with same params should hit cache
  const res2 = await client.search('spectroscopy', { ontologies: 'CHMO' });
  assert.strictEqual(res2.collection.length, 1);
  assert.strictEqual(fetchCallCount, 1, 'Second fetch should be cached');
});

// 4. OntoPortalClient Error Handling
await asyncTest('OntoPortalClient: handles HTTP error response correctly', async () => {
  globalThis.fetch = async () => ({
    ok: false,
    status: 404,
    statusText: 'Not Found',
    json: async () => ({ error: 'Ontology not found' })
  });

  const client = new OntoPortalClient({ apiURL: 'https://data.stage.matportal.org' });
  try {
    await client.getClass('UNKNOWN', 'http://example.org/1');
    assert.fail('Should have thrown OntoPortalError');
  } catch (err) {
    assert(err instanceof OntoPortalError);
    assert.strictEqual(err.status, 404);
    assert.strictEqual(err.message, 'Ontology not found');
  }
});

// 5. <ontoportal-autocomplete> Custom Element Tests
test('Custom Elements: registration in registry', () => {
  assert(customElements.get('ontoportal-autocomplete'), '<ontoportal-autocomplete> registered');
  assert(customElements.get('ontoportal-tree'), '<ontoportal-tree> registered');
  assert(customElements.get('ontoportal-concept-card'), '<ontoportal-concept-card> registered');
});

test('<ontoportal-autocomplete>: attributes, value setter, and event dispatch', () => {
  const el = new OntoPortalAutocomplete();
  el.setAttribute('name', 'selected_class');
  el.setAttribute('ontologies', 'CHMO');
  el.setAttribute('value-field', 'uri');

  assert.strictEqual(el.getAttribute('name'), 'selected_class');
  assert.strictEqual(el.getAttribute('ontologies'), 'CHMO');

  el.connectedCallback();
  assert(el.shadowRoot, 'Shadow root created');

  let selectedEvent = null;
  el.addEventListener('ontoportal:select', (e) => {
    selectedEvent = e;
  });

  // Emulate selection
  el._results = [
    { '@id': 'http://example.org/CHMO_1', prefLabel: 'Mass Spec', id: 'http://example.org/CHMO_1' }
  ];
  el._selectItem(0);

  assert.strictEqual(el.value, 'http://example.org/CHMO_1');
  assert(selectedEvent !== null, 'ontoportal:select fired');
  assert.strictEqual(selectedEvent.detail.value, 'http://example.org/CHMO_1');
  assert.strictEqual(selectedEvent.detail.concept.prefLabel, 'Mass Spec');

  // Verify legacy hidden inputs synced
  const hiddenPref = el.querySelector('#selected_class_bioportal_preferred_name');
  assert(hiddenPref, 'Hidden preferred_name input generated');
  assert.strictEqual(hiddenPref.value, 'Mass Spec');
});

// 6. <ontoportal-tree> Custom Element Tests
await asyncTest('<ontoportal-tree>: node hierarchy, expansion, and selection', async () => {
  const treeEl = new OntoPortalTree();
  treeEl.setAttribute('ontology', 'CHMO');

  const mockRoots = [
    { '@id': 'http://example.org/root1', prefLabel: 'Chemical Entity', hasChildren: true }
  ];
  const mockChildren = [
    { '@id': 'http://example.org/child1', prefLabel: 'Molecule', hasChildren: false }
  ];

  globalThis.fetch = async (url) => {
    if (url.includes('/roots')) {
      return { ok: true, status: 200, json: async () => mockRoots };
    }
    if (url.includes('/children')) {
      return { ok: true, status: 200, json: async () => mockChildren };
    }
    return { ok: true, status: 200, json: async () => ({}) };
  };

  treeEl.connectedCallback();
  await treeEl.reload();

  assert.strictEqual(treeEl._rootIds.length, 1);
  const rootNode = treeEl._nodes.get('http://example.org/root1');
  assert.strictEqual(rootNode.label, 'Chemical Entity');

  let expandedEvent = null;
  treeEl.addEventListener('ontoportal:node-expanded', (e) => {
    expandedEvent = e;
  });

  await treeEl.expandNode('http://example.org/root1');
  assert(expandedEvent !== null, 'ontoportal:node-expanded event fired');
  assert.strictEqual(rootNode.children.length, 1);
  assert.strictEqual(treeEl._nodes.get('http://example.org/child1').label, 'Molecule');

  let selectEvent = null;
  treeEl.addEventListener('ontoportal:node-selected', (e) => {
    selectEvent = e;
  });
  treeEl.selectNode('http://example.org/child1');
  assert(selectEvent !== null, 'ontoportal:node-selected event fired');
  assert.strictEqual(selectEvent.detail.nodeId, 'http://example.org/child1');
});

// 7. <ontoportal-concept-card> Custom Element Tests
await asyncTest('<ontoportal-concept-card>: loads metadata and dispatches loaded event', async () => {
  const cardEl = new OntoPortalConceptCard();
  cardEl.setAttribute('ontology', 'CHMO');
  cardEl.setAttribute('concept-id', 'http://example.org/CHMO_1');

  const mockConcept = {
    '@id': 'http://example.org/CHMO_1',
    prefLabel: 'Infrared Spectroscopy',
    definition: ['A technique measuring infrared absorption.'],
    synonym: ['IR Spectroscopy', 'Vibrational Spectroscopy']
  };

  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => mockConcept
  });

  let loadedEvent = null;
  cardEl.addEventListener('ontoportal:concept-loaded', (e) => {
    loadedEvent = e;
  });

  cardEl.connectedCallback();
  await cardEl.loadConcept();

  assert(loadedEvent !== null, 'ontoportal:concept-loaded event fired');
  assert.strictEqual(loadedEvent.detail.concept.prefLabel, 'Infrared Spectroscopy');
  assert(cardEl._containerEl.innerHTML.includes('Infrared Spectroscopy'), 'Card renders concept title');
  assert(cardEl._containerEl.innerHTML.includes('IR Spectroscopy'), 'Card renders synonyms');
});

// 8. Legacy Shim Tests
await asyncTest('Legacy Shim: $.fn.NCBOTree instantiates <ontoportal-tree>', async () => {
  const mockJqueryContainer = new MockElement('div');
  mockJqueryContainer.each = function(cb) {
    cb.call(this);
    return this;
  };
  mockJqueryContainer.data = function(key, val) {
    if (val !== undefined) this._data = val;
    return this._data;
  };

  const fake$ = function(selector) {
    return mockJqueryContainer;
  };
  fake$.fn = {};

  // Load shim content
  const shimCode = fs.readFileSync(path.join(rootDir, 'public/widgets/jquery.ncbo.tree.shim.js'), 'utf8');
  // Evaluate with fake$
  const fn = new Function('jQuery', '$', 'customElements', shimCode);
  fn(fake$, fake$, globalThis.customElements);

  assert(typeof fake$.fn.NCBOTree === 'function', '$.fn.NCBOTree defined');

  let selectTriggered = false;
  fake$.fn.NCBOTree.call(mockJqueryContainer, {
    ontology: 'CHMO',
    apikey: 'sample-key',
    afterSelect: (id) => {
      selectTriggered = true;
    }
  });

  // Allow promise resolution
  await new Promise((resolve) => setTimeout(resolve, 10));

  const treeChild = mockJqueryContainer.children.find((c) => c.tagName.toLowerCase() === 'ontoportal-tree');
  assert(treeChild, 'Child <ontoportal-tree> created in container');
  assert.strictEqual(treeChild.getAttribute('ontology'), 'CHMO');
  assert.strictEqual(treeChild.getAttribute('api-key'), 'sample-key');
});

// 9. Rails Haml View Template Validation
test('Rails View: _widgets.html.haml contains modern custom elements & shims', () => {
  const hamlPath = path.join(rootDir, 'app/views/ontologies/_widgets.html.haml');
  const content = fs.readFileSync(hamlPath, 'utf8');

  assert(content.includes('ontoportal-autocomplete'), 'Haml includes <ontoportal-autocomplete>');
  assert(content.includes('ontoportal-tree'), 'Haml includes <ontoportal-tree>');
  assert(content.includes('ontoportal-concept-card'), 'Haml includes <ontoportal-concept-card>');
  assert(content.includes('/widgets/modern/ontoportal-widgets.js'), 'Haml includes modern widgets script');
  assert(content.includes('/widgets/modern/ontoportal-widgets.css'), 'Haml includes modern widgets stylesheet');
  assert(content.includes('jquery.ncbo.tree.shim.js'), 'Haml preserves shim fallback for legacy users');
});

console.log(`\nAll ${passedTests}/${totalTests} tests passed successfully.`);
