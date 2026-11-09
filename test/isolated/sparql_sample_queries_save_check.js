/**
 * test/isolated/sparql_sample_queries_save_check.js
 *
 * ONTO-T-J01: saving sample queries reports success only after the update action redirects
 * back to the edited resource, reports an error otherwise (keeping the editor tabs), blocks
 * duplicate submissions while pending, and sends an explicit empty list.
 * Real sparql_controller on a real Stimulus application in headless Chrome. useYasgui is
 * replaced by a finite editor double. Fixtures come from a local 127.0.0.1 server because
 * Chrome fetch does not follow redirects fulfilled by page.route; other requests are aborted and counted.
 */
const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');
const http = require('http');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const SUB = '/ontologies/ONT/submissions/3';

const yasguiDouble = {
  name: 'yasgui-double',
  setup(build) {
    build.onResolve({ filter: /mixins\/useYasgui$/ }, () => ({ path: 'yasgui', namespace: 'double' }));
    build.onLoad({ filter: /.*/, namespace: 'double' }, () => ({
      contents: `export function getYasgui(element) {
        const tabs = window.__tabs = new Map();
        let n = 0;
        const container = document.querySelector('.edit_sparql_container');
        const yasgui = {
          getTab(id) { return id === undefined ? { close() {} } : tabs.get(id); },
          addTab(_active, opts) {
            const id = 't' + (++n); const el = document.createElement('div');
            el.setAttribute('role', 'tab'); el.id = 'tab-' + id; container.appendChild(el);
            const tab = { query: '', setQuery(q) { this.query = q }, getQuery() { return this.query }, el };
            tabs.set(id, tab); return tab;
          }
        };
        return yasgui;
      }`,
      loader: 'js'
    }));
  }
};

const page_html = (graph) => `<!doctype html><head><meta name="csrf-token" content="tok"></head><body>
  <div class="sparql-notifications" data-success-message="Saved (localized)" data-error-message="Not saved (localized)"></div>
  <div class="edit_sparql_container"><div data-controller="sparql" data-sparql-graph-value="${graph}"
       data-sparql-sample-queries-value='["SELECT 1", "SELECT 22"]' data-sparql-proxy-value="/p" data-sparql-apikey-value="k"></div></div>
  <button id="queries-save-button">Save</button></body>`;

(async () => {
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const { Application } = require('@hotwired/stimulus');
        const Sparql = require('../../app/javascript/controllers/sparql_controller.js').default;
        const app = window.__app = Application.start();
        window.__stimulusErrors = [];
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('sparql', Sparql);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true, format: 'iife', write: false, plugins: [yasguiDouble],
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  })).outputFiles[0].text;

  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  const posts = [];
  let reply = null;
  let release = null;
  const servers = [];
  try {
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, 'http://127.0.0.1');
      if (req.method === 'GET' && (url.pathname === '/catalog' || url.pathname === '/ontology')) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        return res.end(page_html(url.pathname === '/ontology' ? `http://data.bioontology.org${SUB}` : ''));
      }
      if (req.method === 'GET' && ['/admin/catalog_configuration', `${SUB}/edit`, '/'].includes(url.pathname)) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        return res.end('landing');
      }
      if (req.method === 'POST') {
        let body = '';
        req.on('data', c => { body += c; });
        req.on('end', async () => {
          posts.push({ path: url.pathname, body });
          if (release) await new Promise(r => { release = r; });
          const r = reply();
          if (r.location) { res.writeHead(302, { Location: r.location }); return res.end(); }
          res.writeHead(r.status, { 'Content-Type': 'text/html' });
          res.end('x');
        });
        return;
      }
      res.writeHead(404); res.end();
    });
    await new Promise(r => server.listen(0, '127.0.0.1', r));
    servers.push(server);
    const ORIGIN = `http://127.0.0.1:${server.address().port}`;

    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/*', route => {
      if (route.request().url().startsWith(ORIGIN + '/')) return route.continue();
      outside.push(route.request().url());
      return route.abort();
    });

    const open = async (p) => {
      await page.goto(ORIGIN + p);
      await page.addScriptTag({ content: bundle });
      await page.waitForFunction(() => window.__tabs && window.__tabs.size === 2, null, { timeout: 5000 });
    };
    const save = async () => {
      const before = posts.length;
      await page.click('#queries-save-button');
      await page.waitForFunction(() => document.querySelector('.sparql-notifications').children.length > 0 &&
        !document.getElementById('queries-save-button').disabled, null, { timeout: 5000 });
      const msg = await page.evaluate(() => { const c = document.querySelector('.sparql-notifications');
        const t = c.lastElementChild.textContent; c.replaceChildren(); return t; });
      return { msg, sent: posts.length - before };
    };
    const field = (body, key) => [...body.matchAll(new RegExp(`name="${key.replace(/[[\]]/g, '\\$&')}"\\r\\n\\r\\n([\\s\\S]*?)\\r\\n--`, 'g'))].map(m => m[1]);

    // Catalog: redirect back to the configuration page is success.
    await open('/catalog');
    reply = () => ({ location: '/admin/catalog_configuration' });
    let r = await save();
    assert.deepStrictEqual(r, { msg: 'Saved (localized)', sent: 1 });
    assert.strictEqual(posts.at(-1).path, '/admin/catalog_configuration');
    assert.strictEqual(field(posts.at(-1).body, 'config[sampleQueries][]').length, 2, 'two queries sent');

    // Catalog: 422 failure and a denial redirect to home are errors; tabs stay.
    reply = () => ({ status: 422 });
    assert.strictEqual((await save()).msg, 'Not saved (localized)');
    reply = () => ({ location: '/' });
    assert.strictEqual((await save()).msg, 'Not saved (localized)', 'redirect elsewhere is not success');
    assert.strictEqual(await page.evaluate(() => window.__tabs.size), 2, 'editor tabs retained after failure');

    // Network failure is an error.
    reply = () => { throw new Error('unused'); };
    await page.route(`${ORIGIN}/admin/catalog_configuration`, route => route.request().method() === 'POST' ? route.abort() : route.fallback());
    assert.strictEqual((await save()).msg, 'Not saved (localized)');
    await page.unroute(`${ORIGIN}/admin/catalog_configuration`);

    // Duplicate clicks while pending send one request.
    reply = () => ({ location: '/admin/catalog_configuration' });
    release = true;
    const before = posts.length;
    await page.click('#queries-save-button');
    await page.waitForFunction(() => document.getElementById('queries-save-button').disabled);
    await page.evaluate(() => document.getElementById('queries-save-button').click());
    await page.waitForTimeout(100);
    assert.strictEqual(posts.length - before, 1, 'one request while pending');
    const pendingMessages = await page.evaluate(() => document.querySelector('.sparql-notifications').children.length);
    assert.strictEqual(pendingMessages, 0, 'no success before the response');
    release(); release = null;
    await page.waitForFunction(() => document.querySelector('.sparql-notifications').children.length === 1);
    await page.evaluate(() => document.querySelector('.sparql-notifications').replaceChildren());

    // Empty list: one explicit blank entry, still a request.
    await page.evaluate(() => window.__tabs.forEach(t => t.setQuery('')));
    r = await save();
    assert.deepStrictEqual(r, { msg: 'Saved (localized)', sent: 1 });
    assert.deepStrictEqual(field(posts.at(-1).body, 'config[sampleQueries][]'), [''], 'explicit empty-list payload');

    // Ontology: 200 turbo-stream error page is not success; redirect to the submission edit page is.
    await open('/ontology');
    reply = () => ({ status: 200 });
    assert.strictEqual((await save()).msg, 'Not saved (localized)', '200 without redirect is not success');
    reply = () => ({ location: `${SUB}/edit` });
    r = await save();
    assert.deepStrictEqual(r, { msg: 'Saved (localized)', sent: 1 });
    assert.strictEqual(posts.at(-1).path, SUB);
    assert.deepStrictEqual(field(posts.at(-1).body, 'ontology_id'), ['ONT']);
    assert.deepStrictEqual(field(posts.at(-1).body, '_method'), ['patch']);
    assert.strictEqual(field(posts.at(-1).body, 'ontology[sampleQueries][]').length, 2);

    assert.deepStrictEqual(await page.evaluate(() => window.__stimulusErrors), []);
    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');
    console.log(`PASS sparql sample-query save; posts=${posts.length}; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
    servers.forEach(s => s.close());
  }
})().catch(e => { console.error('FAIL', e); process.exit(1); });
