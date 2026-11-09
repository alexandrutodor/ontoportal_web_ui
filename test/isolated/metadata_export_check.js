/**
 * test/isolated/metadata_export_check.js
 *
 * ONTO-T-U02: metadata export must produce well-formed RDF/XML that keeps the subject,
 * declares every prefix it uses and escapes values; CSV must quote values and give
 * multivalued properties one row per value; each download must carry a matching MIME type.
 * Real rdf_highlighter controller (with jsonld and highlight.js) on Stimulus in headless Chrome.
 */
const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const OMV = 'http://omv.ontoware.org/2005/05/ontology#';
const DCT = 'http://purl.org/dc/terms/';

const metadata = {
  URI: 'http://ex.org/ont', id: 'http://data.ex/ontologies/ONT', links: { self: 'x' }, context: {}, metrics: {},
  name: 'A & B <x>', description: 'He said "hi", ok\nsecond line',
  hasDomain: ['http://ex.org/d1', 'http://ex.org/d2'], keywords: ['k1', 'k,2'], custom: "it's custom", empty: []
};
const context = {
  URI: `${OMV}URI`, name: `${OMV}name`, description: `${DCT}description`, hasDomain: `${OMV}hasDomain`,
  keywords: `${OMV}keywords`, custom: 'http://other.example/vocab#custom', empty: `${OMV}empty`
};
const namespaces = { omv: OMV, dct: DCT };

const page_html = (format) => `<!doctype html><body>
  <div id="x" data-controller="rdf-highlighter"
       data-rdf-highlighter-metadata-value='${JSON.stringify(metadata).replace(/'/g, '&#39;')}'
       data-rdf-highlighter-context-value='${JSON.stringify(context)}'
       data-rdf-highlighter-namespaces-value='${JSON.stringify(namespaces)}'
       data-rdf-highlighter-format-value="${format}">
    <code data-rdf-highlighter-target="content"></code><div class="d-none" data-rdf-highlighter-target="loader"></div>
  </div></body>`;

function parseCsv(text) {
  const rows = []; let row = []; let field = ''; let q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"' && text[i + 1] === '"') { field += '"'; i++; } else if (c === '"') q = false; else field += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\r' && text[i + 1] === '\n') { row.push(field); rows.push(row); row = []; field = ''; i++; }
    else field += c;
  }
  row.push(field); rows.push(row);
  return rows;
}

(async () => {
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const $ = require('jquery');
        window.$ = window.jQuery = $;
        $(document).data('bp', { ontology: { acronym: 'ONT' } });
        window.__downloads = [];
        HTMLAnchorElement.prototype.click = function () {
          window.__downloads.push({ href: this.getAttribute('href'), name: this.getAttribute('download') });
        };
        const { Application } = require('@hotwired/stimulus');
        const Rdf = require('../../app/components/display/rdf_highlighter_component/rdf_highlighter_component_controller.js').default;
        const app = window.__app = Application.start();
        window.__stimulusErrors = [];
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('rdf-highlighter', Rdf);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true, format: 'iife', write: false, platform: 'browser', logLevel: 'silent',
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  })).outputFiles[0].text;

  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  try {
    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));
    let format = 'xml';
    await page.route('**/*', route => {
      if (route.request().url() === 'http://export.fixture/') return route.fulfill({ contentType: 'text/html', body: page_html(format) });
      outside.push(route.request().url());
      return route.abort();
    });
    const open = async (f) => {
      format = f;
      await page.goto('http://export.fixture/');
      await page.addScriptTag({ content: bundle });
      await page.waitForFunction(() => window.__app.getControllerForElementAndIdentifier(document.getElementById('x'), 'rdf-highlighter'));
    };
    const download = async (n) => {
      await page.evaluate(() => window.__app.getControllerForElementAndIdentifier(document.getElementById('x'), 'rdf-highlighter').download());
      await page.waitForFunction((n) => window.__downloads.length >= n, n, { timeout: 5000 });
      const d = await page.evaluate((n) => window.__downloads[n - 1], n);
      const [, mime, data] = d.href.match(/^data:([^;]+);charset=utf-8,(.*)$/s);
      return { name: d.name, mime, text: decodeURIComponent(data) };
    };

    // RDF/XML
    await open('xml');
    const preview = await page.evaluate(() => document.querySelector('[data-rdf-highlighter-target="content"]').textContent);
    const d1 = await download(1);
    const d2 = await download(2);
    assert.strictEqual(d1.name, 'ONT_metadata.rdf');
    assert.strictEqual(d1.mime, 'application/rdf+xml');
    assert.strictEqual(d1.text, preview, 'download equals preview');
    assert.strictEqual(d2.text, d1.text, 'repeated export is unchanged (no mutation)');
    const xml = await page.evaluate((text) => {
      const doc = new DOMParser().parseFromString(text, 'application/xml');
      if (doc.getElementsByTagName('parsererror').length) return { error: doc.getElementsByTagName('parsererror')[0].textContent };
      const RDF = 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
      const desc = doc.getElementsByTagNameNS(RDF, 'Description')[0];
      const byNS = (ns, local) => [...doc.getElementsByTagNameNS(ns, local)];
      return {
        about: desc.getAttributeNS(RDF, 'about'),
        type: byNS(RDF, 'type')[0].getAttributeNS(RDF, 'resource'),
        name: byNS('http://omv.ontoware.org/2005/05/ontology#', 'name').map(e => e.textContent),
        description: byNS('http://purl.org/dc/terms/', 'description').map(e => e.textContent),
        domains: byNS('http://omv.ontoware.org/2005/05/ontology#', 'hasDomain').map(e => e.getAttributeNS(RDF, 'resource')),
        keywords: byNS('http://omv.ontoware.org/2005/05/ontology#', 'keywords').map(e => e.textContent),
        custom: byNS('http://other.example/vocab#', 'custom').map(e => e.textContent),
        empty: byNS('http://omv.ontoware.org/2005/05/ontology#', 'empty').length
      };
    }, d1.text);
    assert.deepStrictEqual(xml, {
      about: 'http://ex.org/ont', type: 'http://www.w3.org/2002/07/owl#Ontology',
      name: ['A & B <x>'], description: ['He said "hi", ok\nsecond line'],
      domains: ['http://ex.org/d1', 'http://ex.org/d2'], keywords: ['k1', 'k,2'], custom: ["it's custom"], empty: 0
    }, 'well-formed RDF/XML with subject, prefixes and escaped values');

    // CSV
    await open('csv');
    const csv = await download(1);
    assert.strictEqual(csv.name, 'ONT_metadata.csv');
    assert.strictEqual(csv.mime, 'text/csv');
    const rows = parseCsv(csv.text);
    assert.deepStrictEqual(rows[0], ['property', 'value']);
    assert.ok(rows.every(r => r.length === 2), 'every row has exactly two fields');
    const get = (k) => rows.filter(r => r[0] === k).map(r => r[1]);
    assert.deepStrictEqual(get(`${DCT}description`), ['He said "hi", ok\nsecond line']);
    assert.deepStrictEqual(get(`${OMV}keywords`), ['k1', 'k,2'], 'one row per value');
    assert.deepStrictEqual(get('@id'), ['http://ex.org/ont']);

    // JSON-LD and N-Triples MIME types
    await open('json');
    const json = await download(1);
    assert.strictEqual(json.mime, 'application/ld+json');
    assert.strictEqual(JSON.parse(json.text)['@id'] || JSON.parse(json.text).id, 'http://ex.org/ont');
    await open('triples');
    const nt = await download(1);
    assert.strictEqual(nt.mime, 'application/n-triples');
    assert.ok(nt.text.includes('<http://ex.org/ont> <http://omv.ontoware.org/2005/05/ontology#name> "A & B <x>" .'));

    assert.deepStrictEqual(await page.evaluate(() => window.__stimulusErrors), []);
    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');
    console.log(`PASS metadata export xml/csv/json/nt; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e); process.exit(1); });
