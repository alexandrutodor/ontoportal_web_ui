/**
 * test/isolated/widget_stylesheet_scope_check.js
 *
 * ONTO-AT-R01: the published tree widget stylesheet must style its own autocomplete without
 * changing unrelated jQuery UI controls on the host page. Compares computed styles of host
 * controls with no widget stylesheet, the original stylesheet (git HEAD~ blob passed in) and the
 * current one, then checks keyboard highlighting inside the real 2.0.2 widget and autocomplete
 * with local fixtures. Both the plain and the minified stylesheet are exercised.
 */
const { chromium } = require('playwright');
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const BASE = process.env.CSS_BASE_REV || 'HEAD~1';
const read = (f) => fs.readFileSync(path.join(ROOT_DIR, f), 'utf8');
const old = (f) => execFileSync('git', ['-C', ROOT_DIR, 'show', `${BASE}:${f}`], { encoding: 'utf8' });
const JQUERY = fs.readFileSync(require.resolve('jquery/dist/jquery.min.js'), 'utf8');
const TREE = read('public/widgets/jquery.ncbo.tree-2.0.2.js');
const AUTOCOMPLETE = read('public/widgets/jquery.ncbo.autocomplete.js');
const PROPS = ['color', 'background-color', 'background-image', 'border-top-color', 'font-weight', 'font-family', 'font-size'];

const HOST = `
  <div class="ui-widget host"><select id="h-select"><option>a</option></select><textarea id="h-textarea"></textarea><button id="h-button">b</button></div>
  <div class="ui-widget-content host"><span id="h-default" class="ui-state-default">d</span><span id="h-hover" class="ui-state-hover">h</span>
    <span id="h-active" class="ui-state-active"><a id="h-active-a" href="#x">a</a></span></div>
  <span id="h-focus" class="ui-state-focus">f</span>
  <span class="ui-state-default"><a id="h-default-a" href="#y">l</a></span>
  <div id="tree"></div>`;

async function computed(page, ids) {
  return page.evaluate(({ ids, PROPS }) => Object.fromEntries(ids.map(id => {
    const cs = getComputedStyle(document.getElementById(id));
    return [id, Object.fromEntries(PROPS.map(p => [p, cs.getPropertyValue(p)]))];
  })), { ids, PROPS });
}

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  let css = '';
  try {
    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/*', route => {
      const url = new URL(route.request().url());
      if (url.href === 'http://host.fixture/') return route.fulfill({ contentType: 'text/html', body: `<!doctype html><head><style>${css}</style></head><body>${HOST}</body>` });
      if (url.href.startsWith('http://ui.fixture/widgets/jquery.ncbo.autocomplete.js')) return route.fulfill({ contentType: 'application/javascript', body: AUTOCOMPLETE });
      if (url.host === 'api.fixture' && url.pathname === '/ontologies/ONT/classes/roots') {
        return route.fulfill({ contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: '[]' });
      }
      if (url.host === 'api.fixture' && url.pathname === '/search') {
        const item = (n) => ({ '@id': `http://ex/${n}`, prefLabel: n, links: { self: `http://api.fixture/c/${n}`, ontology: 'http://api.fixture/ontologies/ONT' } });
        return route.fulfill({ contentType: 'application/json', headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ collection: [item('Alpha'), item('Alpine')] }) });
      }
      outside.push(url.href);
      return route.abort();
    });
    const load = async (stylesheet) => { css = stylesheet; await page.goto('http://host.fixture/'); };
    const hostIds = ['h-select', 'h-textarea', 'h-button', 'h-default', 'h-hover', 'h-active', 'h-active-a', 'h-focus', 'h-default-a'];

    for (const file of ['public/widgets/jquery.ncbo.tree.css', 'public/widgets/minified/jquery.ncbo.tree.min.css']) {
      await load('');
      const bare = await computed(page, hostIds);
      await load(old(file));
      const before = await computed(page, hostIds);
      await load(read(file));
      const after = await computed(page, hostIds);
      const leaked = hostIds.filter(id => JSON.stringify(before[id]) !== JSON.stringify(bare[id]));
      assert.ok(leaked.length >= 5, `${file}: original stylesheet changes host controls (reproduction): ${leaked}`);
      assert.deepStrictEqual(after, bare, `${file}: scoped stylesheet leaves every host control unchanged`);
      console.log(`  ${file}: original changed ${leaked.length}/${hostIds.length} host controls; scoped changes 0`);
    }

    // Widget states stay styled: real 2.0.2 tree + autocomplete, keyboard selection in the results.
    const widgetState = async (stylesheet) => {
      await load(stylesheet);
      await page.addScriptTag({ content: JQUERY });
      await page.evaluate(() => { $.fn.size = function () { return this.length; }; }); // embed doc uses jQuery 1.10.2
      await page.addScriptTag({ content: TREE });
      await page.evaluate(() => $('#tree').NCBOTree({ apikey: 'k', ontology: 'ONT', ncboAPIURL: 'http://api.fixture', ncboUIURL: 'http://ui.fixture' }));
      await page.waitForSelector('#tree input.ncboAutocomplete');
      await page.focus('#tree input.ncboAutocomplete');
      await page.keyboard.type('Alp');
      await page.waitForSelector('#tree .jsonSuggest li a', { state: 'visible', timeout: 5000 });
      await page.keyboard.press('ArrowDown');
      await page.waitForSelector('#tree .jsonSuggest a.ui-state-hover', { timeout: 5000 });
      return page.evaluate((PROPS) => {
        const pick = (el) => Object.fromEntries(PROPS.map(p => [p, getComputedStyle(el).getPropertyValue(p)]));
        return {
          focused: document.activeElement.classList.contains('ncboAutocomplete'),
          inside: !!document.querySelector('#tree .ncboAutocomplete .jsonSuggest'),
          hovered: pick(document.querySelector('#tree .jsonSuggest a.ui-state-hover')),
          menu: pick(document.querySelector('#tree .jsonSuggest'))
        };
      }, PROPS);
    };
    const file = 'public/widgets/jquery.ncbo.tree.css';
    const w0 = await widgetState(old(file));
    const w1 = await widgetState(read(file));
    assert.ok(w1.focused && w1.inside, 'focus stays in the widget input; results render inside .ncboAutocomplete');
    assert.deepStrictEqual(w1, w0, 'widget results and keyboard-highlighted item keep their styling');

    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');
    console.log(`PASS widget stylesheet scope; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e); process.exit(1); });
