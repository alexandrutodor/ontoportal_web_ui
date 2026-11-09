/**
 * test/isolated/accessible_controls_keyboard_check.js
 *
 * ONTO-T-U05: keyboard-only use of the nested-form add/remove buttons, the dropdown disclosure
 * button and the responsive menu toggle. Bundles the real app/javascript/controllers/application.js
 * (nested-form registration) with esbuild and checks Enter/Space actuation, that no enclosing form
 * is submitted, and that focus stays in the form after a row is removed.
 */
const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

const ROW = (n) => `<div class="d-flex nested-form-wrapper" data-new-record="true"><input name="row[${n}]" aria-label="row ${n}"><button class="delete" type="button" aria-label="Remove row" data-action="click->nested-form#remove">x</button></div>`;
const HTML = `<!doctype html><html><body>
<form id="f" action="/submitted" method="get">
  <input id="nav-menu" type="checkbox" aria-label="Toggle navigation"><label class="menu-btn" for="nav-menu">menu</label>
  <div class="nested-form-input-container" data-controller="nested-form">
    <template data-nested-form-target="template">${ROW('NEW_RECORD')}</template>
    ${ROW(1)}${ROW(2)}
    <div data-nested-form-target="target"></div>
    <button class="add-another-object" type="button" data-action="click->nested-form#add">Add another</button>
  </div>
  <button class="dropdown-title-bar" type="button" data-toggle="collapse" aria-expanded="false" aria-controls="sec">Formats</button>
</form></body></html>`;

(async () => {
  const bundle = await esbuild.build({
    entryPoints: [path.join(ROOT_DIR, 'app/javascript/controllers/application.js')],
    bundle: true, write: false, format: 'iife', logLevel: 'silent',
    nodePaths: (process.env.NODE_PATH || '').split(':').filter(Boolean)
  });
  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(String(e)));
    let submitted = 0;
    await page.route('**/*', route => {
      const url = route.request().url();
      if (url === 'http://fixture.test/') return route.fulfill({ contentType: 'text/html', body: HTML });
      if (url.startsWith('http://fixture.test/submitted')) submitted++;
      return route.fulfill({ contentType: 'text/html', body: '<p>submitted</p>' });
    });
    await page.goto('http://fixture.test/');
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    await page.waitForFunction(() => window.Stimulus && document.querySelector('[data-controller="nested-form"]') &&
      window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="nested-form"]'), 'nested-form'), null, { timeout: 5000 });
    const rows = () => page.locator('.nested-form-wrapper:not(template .nested-form-wrapper)').count();

    // Menu toggle: focusable, Space toggles it.
    await page.focus('#nav-menu');
    await page.keyboard.press('Space');
    assert.strictEqual(await page.isChecked('#nav-menu'), true, 'Space toggles the navigation menu');

    // Add with Enter and Space.
    await page.focus('.add-another-object');
    await page.keyboard.press('Enter');
    await page.keyboard.press('Space');
    assert.strictEqual(await rows(), 4, 'Enter and Space each add a row');

    // Remove with Enter: row gone, focus moves to the add button instead of the body.
    await page.focus('.nested-form-wrapper:not(template *) .delete');
    await page.keyboard.press('Enter');
    assert.strictEqual(await rows(), 3, 'Enter removes a row');
    assert.strictEqual(await page.evaluate(() => document.activeElement.className), 'add-another-object', 'focus moves to the add button after removal');
    await page.focus('.nested-form-wrapper:not(template *) .delete');
    await page.keyboard.press('Space');
    assert.strictEqual(await rows(), 2, 'Space removes a row');

    // Disclosure: a real button, actuated by Enter/Space, never submits the form.
    await page.evaluate(() => { window.__clicks = 0; document.querySelector('.dropdown-title-bar').addEventListener('click', () => window.__clicks++); });
    await page.focus('.dropdown-title-bar');
    await page.keyboard.press('Enter');
    await page.keyboard.press('Space');
    assert.strictEqual(await page.evaluate(() => window.__clicks), 2, 'Enter and Space actuate the disclosure button');

    await page.waitForTimeout(200);
    assert.strictEqual(submitted, 0, 'no keyboard action submitted the form');
    assert.strictEqual(new URL(page.url()).pathname, '/', 'still on the form page');
    assert.deepStrictEqual(errors, [], 'no page errors');
    console.log('PASS accessible controls keyboard; rows 2, submits 0, focus restored to add button');
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e.message || e); process.exit(1); });
