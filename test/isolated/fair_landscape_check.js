/**
 * test/isolated/fair_landscape_check.js
 *
 * ONTO-T-J04: the FAIR landscape filter must not throw, must send "all" for an empty
 * selection, must keep one controller mount with one chart updated in place, and must
 * dispose the chart on disconnect. Real controller + useFairScore mixin on a real Stimulus
 * application in headless Chrome. Chart is a recording double (the runtime Chart.js is a
 * separately loaded global); all requests are fixtures or aborted and counted.
 */
const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const PARTIAL = fs.readFileSync(path.join(ROOT_DIR, 'app/views/landscape/_fair_score_landscape.html.haml'), 'utf8');

// Mirrors _fair_score_landscape.html.haml after the fix: one mount, selector inside it.
const HTML = `<!doctype html><body><div id="host">
  <div class="card mb-3" data-controller="fair-score-landscape">
    <span id="fair-score-average"></span><span><span><span id="fair-score-min"></span></span></span>
    <span><span><span id="fair-score-max"></span></span></span><span><span><span id="fair-score-median"></span></span></span>
    <div class="landscape_ontologies_selector" data-action="change->fair-score-landscape#update">
      <select id="sel" multiple><option value="A">A</option><option value="B">B</option></select>
    </div>
    <div class="card-body">
      <div id="fair-score-charts-container" data-error-message="FAIR service unreachable">
        <canvas id="ont-fair-scores-criteria-bars-canvas" data-labels="[]" data-scores="[]" data-max-credits="[]" data-portal-max-credits="[]"></canvas>
        <div id="chartjs-tooltip-container"></div>
      </div>
    </div>
  </div></div></body>`;

const payload = (n) => ({
  score: n, normalizedScore: n, resourceCount: 1, maxCredits: 10, minScore: 0, maxScore: n, medianScore: n,
  criteria: { labels: ['F1'], scores: [n], normalizedScores: [n], maxCredits: [10], portalMaxCredits: [10], questions: {}, descriptions: {} }
});

(async () => {
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const $ = require('jquery');
        window.$ = window.jQuery = $;
        window.__charts = [];
        window.Chart = class { constructor(canvas, config) { this.canvas = canvas[0] || canvas; this.config = config; this.data = config.data || {}; this.updates = 0; this.destroyed = false; window.__charts.push(this); }
          update() { this.updates += 1 } destroy() { this.destroyed = true }
          getDatasetMeta() { return { data: [{ getCenterPoint: () => ({ x: 1, y: 1 }) }] } } };
        const { Application } = require('@hotwired/stimulus');
        const Landscape = require('../../app/javascript/controllers/fair_score_landscape_controller.js').default;
        window.__stimulusErrors = [];
        const app = window.__app = Application.start();
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('fair-score-landscape', Landscape);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true, format: 'iife', write: false,
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  })).outputFiles[0].text;

  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  const fairRequests = [];
  let failNext = false;
  try {
    assert.strictEqual((PARTIAL.match(/controller['"]?:\s*['"]fair-score-landscape['"]/g) || []).length, 1, 'partial mounts the controller once');

    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/*', route => {
      const url = new URL(route.request().url());
      if (url.href === 'http://fair.fixture/') return route.fulfill({ contentType: 'text/html', body: HTML });
      if (url.pathname === '/ajax/fair_score/json/') {
        fairRequests.push(url.searchParams.get('ontologies'));
        if (failNext) { failNext = false; return route.fulfill({ status: 500, body: '' }); }
        return route.fulfill({ contentType: 'application/json', body: JSON.stringify(payload(fairRequests.length)) });
      }
      outside.push(url.href);
      return route.abort();
    });
    await page.goto('http://fair.fixture/');
    await page.addScriptTag({ content: bundle });
    const settled = (n) => page.waitForFunction((n) => window.__charts.length > 0 && window.__charts[0].updates + 1 >= n, n, { timeout: 5000 });
    const view = () => page.evaluate(() => ({
      charts: window.__charts.length,
      destroyed: window.__charts.map(c => c.destroyed),
      errMsgs: document.querySelectorAll('#fair-msg-container').length,
      errVisible: [...document.querySelectorAll('#fair-msg-container')].some(e => e.style.display !== 'none'),
      average: document.getElementById('fair-score-average')?.textContent
    }));
    const select = (values) => page.evaluate((values) => {
      const sel = document.getElementById('sel');
      [...sel.options].forEach(o => { o.selected = values.includes(o.value) });
      sel.dispatchEvent(new Event('change', { bubbles: true }));
    }, values);

    await settled(1);
    await select(['A', 'B']);
    await settled(2);
    await select([]);
    await settled(3);
    let v = await view();
    assert.deepStrictEqual(fairRequests, ['all', 'A,B', 'all'], 'initial all, joined selection, empty selection means all');
    assert.strictEqual(v.charts, 1, 'one chart instance, updated in place');
    assert.strictEqual(v.errMsgs, 1, 'one error container for the single mount');
    assert.strictEqual(v.average, '3 (3%)', 'latest data rendered');

    failNext = true;
    await select(['B']);
    await page.waitForFunction(() => [...document.querySelectorAll('#fair-msg-container')].some(e => e.style.display !== 'none'), null, { timeout: 5000 });
    v = await view();
    assert.ok(v.errVisible && v.errMsgs === 1 && v.charts === 1, 'service error shown once, chart kept');

    await select(['A']);
    await settled(4);
    v = await view();
    assert.ok(!v.errVisible, 'error cleared after a later success');

    await page.evaluate(() => document.getElementById('host').remove());
    await page.waitForFunction(() => window.__charts[0].destroyed, null, { timeout: 5000 });
    v = await view();
    assert.deepStrictEqual(v.destroyed, [true], 'chart disposed on disconnect');
    assert.strictEqual(v.errMsgs, 0);

    assert.deepStrictEqual(await page.evaluate(() => window.__stimulusErrors), [], 'no Stimulus errors');
    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');
    console.log(`PASS fair landscape; requests=${JSON.stringify(fairRequests)}; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e); process.exit(1); });
