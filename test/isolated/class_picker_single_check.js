/**
 * test/isolated/class_picker_single_check.js
 *
 * ONTO-T-J06: a single-class picker must keep a usable search control after a value is
 * picked and removed, keep exactly one hidden value, and leave other form fields alone.
 * Real class_picker_controller on a real Stimulus application in headless Chrome; no network.
 */
const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

// Mirrors the single branch of ontology_class_search_input_component.html.haml; the search
// wrapper content stands in for ontology_classes_content_autocomplete.
const HTML = `<!doctype html><body><form id="f">
  <input name="other" value="keep-me">
  <div class="ontology-class-single-picker" data-controller="class-picker"
       data-class-picker-name-prefix-value="submission[obsoleteParent]" data-class-picker-single-value="true">
    <template data-class-picker-target="deleteIconTemplate"><svg class="del"></svg></template>
    <div class="search-wrapper" data-class-picker-target="searchWrapper">
      <input id="q" type="text">
      <a href="#" class="result" data-action="click->class-picker#addResult">
        <p class="class-label_name">Alpha</p><small class="class-uri">http://ex/Alpha</small></a>
      <a href="#" class="result2" data-action="click->class-picker#addResult">
        <p class="class-label_name">Beta</p><small class="class-uri">http://ex/Beta</small></a>
    </div>
    <div class="picked-class" data-class-picker-target="picked">
      <input type="hidden" name="submission[obsoleteParent]" value="">
    </div>
  </div></form></body>`;

(async () => {
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const { Application } = require('@hotwired/stimulus');
        const ClassPicker = require('../../app/javascript/controllers/class_picker_controller.js').default;
        window.__stimulusErrors = [];
        const app = window.__app = Application.start();
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('class-picker', ClassPicker);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true, format: 'iife', write: false,
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  })).outputFiles[0].text;

  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  try {
    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/*', route => {
      if (route.request().url() === 'http://picker.fixture/') return route.fulfill({ contentType: 'text/html', body: HTML });
      outside.push(route.request().url());
      return route.abort();
    });
    await page.goto('http://picker.fixture/');
    await page.addScriptTag({ content: bundle });
    await page.waitForFunction(() => window.__app.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="class-picker"]'), 'class-picker') !== null);

    const state = () => page.evaluate(() => {
      const fd = new FormData(document.getElementById('f'));
      const w = document.querySelector('.search-wrapper');
      return {
        values: fd.getAll('submission[obsoleteParent]'),
        other: fd.get('other'),
        searchPresent: document.body.contains(w),
        searchVisible: !!w && !w.hidden && w.offsetParent !== null,
        query: document.getElementById('q')?.value ?? null,
        label: document.querySelector('.picked-class .class-label_name')?.textContent ?? null
      };
    });

    await page.fill('#q', 'alp');
    await page.click('.result');
    let s = await state();
    assert.deepStrictEqual(s.values, ['http://ex/Alpha'], 'one hidden value after pick');
    assert.strictEqual(s.label, 'Alpha');
    assert.ok(s.searchPresent && !s.searchVisible, 'search hidden, not removed, after pick');

    await page.click('.picked-class .delete');
    s = await state();
    assert.deepStrictEqual(s.values, [''], 'one empty hidden value after removal');
    assert.ok(s.searchVisible, 'search control visible again after removal');
    assert.strictEqual(s.query, '', 'search input reset after removal');

    await page.click('.result2');
    s = await state();
    assert.deepStrictEqual(s.values, ['http://ex/Beta'], 'second pick after removal works with one value');
    assert.strictEqual(s.other, 'keep-me', 'other form fields preserved');

    assert.deepStrictEqual(await page.evaluate(() => window.__stimulusErrors), []);
    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');
    console.log(`PASS pick/remove/re-pick; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e); process.exit(1); });
