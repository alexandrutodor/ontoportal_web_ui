/**
 * test/isolated/tree_widget_root_check.js
 *
 * ONTO-T-J08: the published tree widget (2.0.2) must not crash when a configured
 * startingRoot is absent, and must stop at the first breadth-first match.
 * Real headless Chrome; every request is served from local fixtures or aborted and counted.
 */
const { chromium } = require('playwright');
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const ORIGIN = 'http://widget.fixture';
const API = 'http://api.fixture';
const JQUERY = fs.readFileSync(require.resolve('jquery/dist/jquery.min.js'), 'utf8');
const WIDGET = fs.readFileSync(path.join(ROOT_DIR, 'public/widgets/jquery.ncbo.tree-2.0.2.js'), 'utf8');

const node = (id, label, children) => ({
  '@id': id, prefLabel: label, hasChildren: !!(children && children.length),
  links: { self: `${API}/cls/${label}`, children: `${API}/cls/${label}/children` },
  ...(children ? { children } : {})
});

// "X" occurs twice; breadth-first must pick the shallow one (label X-shallow).
const TREE = [
  node('http://ex/A', 'A', [node('http://ex/A1', 'A1', [node('http://ex/X', 'X-deep', [])])]),
  node('http://ex/B', 'B', [node('http://ex/X', 'X-shallow', [node('http://ex/X1', 'X1', [])])])
];

async function run(page, { startingRoot, tree }) {
  await page.evaluate(({ API, startingRoot, tree }) => {
    window.__tree = tree;
    document.body.innerHTML = '<div id="w"></div>';
    const opts = { apikey: 'k', ontology: 'ONT', ncboAPIURL: API, ncboUIURL: 'http://ui.fixture', startingClass: 'http://ex/A1' };
    if (startingRoot) opts.startingRoot = startingRoot;
    $('#w').NCBOTree(opts);
  }, { API, startingRoot, tree });
  await page.waitForFunction(() => !/Loading/.test(document.querySelector('#w .root')?.textContent || 'Loading'), null, { timeout: 5000 });
  return page.evaluate(() => ({
    labels: [...document.querySelectorAll('#w .root a[data-id]')].map(a => a.textContent),
    missing: document.querySelector('#w .ncboTreeRootMissing')?.textContent || null
  }));
}

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  let treeRequests = 0;
  try {
    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/*', async route => {
      const url = route.request().url();
      if (url === `${ORIGIN}/`) return route.fulfill({ contentType: 'text/html', body: '<!doctype html><body></body>' });
      if (url.startsWith('http://ui.fixture/widgets/jquery.ncbo.autocomplete.js')) {
        return route.fulfill({ contentType: 'application/javascript', body: '$.fn.NCBOAutocomplete = function () { return this; };' });
      }
      if (url.startsWith(`${API}/ontologies/ONT/classes/`) && url.includes('/tree?')) {
        treeRequests += 1;
        const tree = await page.evaluate(() => window.__tree);
        return route.fulfill({ contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify(tree) });
      }
      outside.push(url);
      return route.abort();
    });
    await page.goto(`${ORIGIN}/`);
    await page.addScriptTag({ content: JQUERY });
    // The documented embed (ncbo_tree.html) loads jQuery 1.10.2, which still has .size(); only 3.x is available offline.
    await page.evaluate(() => { $.fn.size = function () { return this.length; }; });
    await page.addScriptTag({ content: WIDGET });

    let r = await run(page, { startingRoot: 'http://ex/MISSING', tree: TREE });
    assert.strictEqual(r.missing, 'The configured starting root is not available in this tree.', 'absent root shows recoverable message');
    assert.deepStrictEqual(r.labels, [], 'absent root renders no nodes');

    r = await run(page, { startingRoot: 'http://ex/MISSING', tree: [] });
    assert.ok(r.missing, 'empty tree with configured root shows recoverable message');

    r = await run(page, { startingRoot: 'http://ex/X', tree: TREE });
    assert.strictEqual(r.missing, null);
    assert.deepStrictEqual(r.labels, ['X-shallow', 'X1'], 'first breadth-first match and only its subtree are rendered');

    r = await run(page, { tree: TREE });
    assert.strictEqual(r.missing, null);
    assert.deepStrictEqual(r.labels.slice(0, 2), ['A', 'A1'], 'default root renders the full response');
    assert.ok(r.labels.includes('B') && r.labels.includes('X-deep'));

    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');
    assert.strictEqual(treeRequests, 4);
    console.log(`PASS 4/4 scenarios; tree requests=${treeRequests}; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e); process.exit(1); });
