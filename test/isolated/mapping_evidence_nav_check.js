/**
 * test/isolated/mapping_evidence_nav_check.js
 *
 * ONTO-AT-OP04: Validates the read-only mapping evidence Stimulus controller
 * in headless Chrome via Playwright:
 * 1. Previous/next navigation strictly stays within already loaded page rows
 *    (disables and halts at bounds index 0 and index N-1).
 * 2. Failed lookups terminate the loading state and display retry/return.
 * 3. Clicking retry successfully re-fetches and renders evidence.
 * 4. Closing the panel restores focus to the originating row element.
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const ROOT_DIR = path.resolve(__dirname, '../..');

const HTML_FIXTURE = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Mapping Evidence Test Fixture</title>
  <style>
    .d-none { display: none !important; }
  </style>
</head>
<body>
  <div id="wrapper" data-controller="mapping-evidence">
    <table id="mappings-table">
      <thead>
        <tr>
          <th>Source Class</th>
          <th>Target Class</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        <tr id="row-101" data-mapping-evidence-target="row" data-mapping-id="101" data-evidence-url="/mappings/101/evidence">
          <td>http://example.com/C1</td>
          <td>http://example.com/C2</td>
          <td>
            <button type="button" id="btn-101" class="mapping-evidence-btn"
                    data-action="click->mapping-evidence#open"
                    data-mapping-id="101"
                    data-evidence-url="/mappings/101/evidence">Evidence 101</button>
          </td>
        </tr>
        <tr id="row-102" data-mapping-evidence-target="row" data-mapping-id="102" data-evidence-url="/mappings/102/evidence">
          <td>http://example.com/C3</td>
          <td>http://example.com/C4</td>
          <td>
            <button type="button" id="btn-102" class="mapping-evidence-btn"
                    data-action="click->mapping-evidence#open"
                    data-mapping-id="102"
                    data-evidence-url="/mappings/102/evidence">Evidence 102</button>
          </td>
        </tr>
        <tr id="row-103" data-mapping-evidence-target="row" data-mapping-id="103" data-evidence-url="/mappings/103/evidence">
          <td>http://example.com/C5</td>
          <td>http://example.com/C6</td>
          <td>
            <button type="button" id="btn-103" class="mapping-evidence-btn"
                    data-action="click->mapping-evidence#open"
                    data-mapping-id="103"
                    data-evidence-url="/mappings/103/evidence">Evidence 103</button>
          </td>
        </tr>
      </tbody>
    </table>

    <div id="evidence-panel" class="mapping-evidence-panel d-none" data-mapping-evidence-target="panel" role="dialog" aria-modal="true" aria-label="Mapping Evidence">
      <div class="panel-header">
        <h5>Mapping Evidence</h5>
        <button type="button" id="close-btn" class="close-btn" data-mapping-evidence-target="closeBtn" data-action="click->mapping-evidence#close" aria-label="Close">&times;</button>
      </div>
      <div class="panel-nav">
        <button type="button" id="prev-btn" class="prev-evidence-btn" data-mapping-evidence-target="prevBtn" data-action="click->mapping-evidence#prev">Previous</button>
        <button type="button" id="next-btn" class="next-evidence-btn" data-mapping-evidence-target="nextBtn" data-action="click->mapping-evidence#next">Next</button>
      </div>
      <div id="panel-loading" class="panel-loading d-none" data-mapping-evidence-target="loading">
        <span class="loading-indicator">Loading evidence...</span>
      </div>
      <div id="panel-error" class="panel-error d-none" data-mapping-evidence-target="error">
        <p id="error-message" class="error-msg" data-mapping-evidence-target="errorMessage">Failed to load</p>
        <button type="button" id="retry-btn" class="retry-evidence-btn" data-mapping-evidence-target="retryBtn" data-action="click->mapping-evidence#retry">Retry</button>
        <button type="button" id="return-btn" class="return-evidence-btn" data-action="click->mapping-evidence#close">Return</button>
      </div>
      <div id="panel-content" class="panel-content" data-mapping-evidence-target="content"></div>
    </div>
  </div>
</body>
</html>`;

(async () => {
  console.log('[mapping_evidence_nav_check] Bundling Stimulus controller with esbuild...');
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const { Application } = require('@hotwired/stimulus');
        const MappingEvidence = require('${path.join(ROOT_DIR, 'app/javascript/controllers/mapping_evidence_controller.js')}').default;
        window.__stimulusErrors = [];
        const app = window.__app = Application.start();
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('mapping-evidence', MappingEvidence);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true,
    format: 'iife',
    write: false,
    nodePaths: [
      path.join(ROOT_DIR, 'node_modules'),
      '/home/ranma/ontoportal/bioportal_web_ui/node_modules',
      '/home/ranma/.pi/agent/npm/node_modules'
    ]
  })).outputFiles[0].text;

  console.log('[mapping_evidence_nav_check] Launching Chrome...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true
  });

  const pageErrors = [];
  let map103Fail = true;

  try {
    const page = await browser.newPage({ viewport: { width: 1024, height: 768 } });
    page.on('pageerror', err => pageErrors.push(String(err)));

    // Route mocks (serve local fixture and mock API endpoints)
    await page.route('**/*', async (route) => {
      const url = route.request().url();
      if (url === 'http://localhost.test/fixture') {
        return route.fulfill({
          status: 200,
          contentType: 'text/html',
          body: HTML_FIXTURE
        });
      }

      if (url.includes('/mappings/101/evidence')) {
        return route.fulfill({
          status: 200,
          contentType: 'text/html',
          body: '<div class="evidence-body" id="ev-101"><h3>Evidence 101</h3><p>Class C1 to C2</p></div>'
        });
      }

      if (url.includes('/mappings/102/evidence')) {
        return route.fulfill({
          status: 200,
          contentType: 'text/html',
          body: '<div class="evidence-body" id="ev-102"><h3>Evidence 102</h3><p>Class C3 to C4</p></div>'
        });
      }

      if (url.includes('/mappings/103/evidence')) {
        if (map103Fail) {
          return route.fulfill({
            status: 500,
            contentType: 'text/plain',
            body: 'Internal Server Error'
          });
        } else {
          return route.fulfill({
            status: 200,
            contentType: 'text/html',
            body: '<div class="evidence-body" id="ev-103"><h3>Evidence 103 (Recovered)</h3><p>Class C5 to C6</p></div>'
          });
        }
      }

      return route.abort();
    });

    console.log('[mapping_evidence_nav_check] Loading test fixture...');
    await page.goto('http://localhost.test/fixture', { timeout: 15000 });
    await page.addScriptTag({ content: bundle });

    // Wait for Stimulus controller connection
    await page.waitForFunction(() => {
      const el = document.querySelector('[data-controller="mapping-evidence"]');
      return window.__app && window.__app.getControllerForElementAndIdentifier(el, 'mapping-evidence') !== null;
    }, { timeout: 10000 });

    console.log('[mapping_evidence_nav_check] Controller connected.');

    // -------------------------------------------------------------------------
    // Step 1: Open evidence on Row 1 (btn-102)
    // -------------------------------------------------------------------------
    console.log('[mapping_evidence_nav_check] Clicking Evidence 102 (middle row)...');
    await page.focus('#btn-102');
    await page.click('#btn-102', { timeout: 5000 });

    // Panel is opened
    await page.waitForSelector('#evidence-panel:not(.d-none)', { timeout: 5000 });
    await page.waitForSelector('#ev-102', { timeout: 5000 });

    let isPrevDisabled = await page.$eval('#prev-btn', el => el.disabled);
    let isNextDisabled = await page.$eval('#next-btn', el => el.disabled);
    assert.strictEqual(isPrevDisabled, false, 'Previous button should be enabled at index 1');
    assert.strictEqual(isNextDisabled, false, 'Next button should be enabled at index 1');
    console.log('[mapping_evidence_nav_check] Row 102 evidence displayed with both prev/next enabled.');

    // -------------------------------------------------------------------------
    // Step 2: Navigate Previous -> reaches Row 0 (index 0 boundary)
    // -------------------------------------------------------------------------
    console.log('[mapping_evidence_nav_check] Clicking Previous to reach row 101...');
    await page.click('#prev-btn', { timeout: 5000 });
    await page.waitForSelector('#ev-101', { timeout: 5000 });

    isPrevDisabled = await page.$eval('#prev-btn', el => el.disabled);
    isNextDisabled = await page.$eval('#next-btn', el => el.disabled);
    assert.strictEqual(isPrevDisabled, true, 'Previous button must be disabled at index 0 boundary');
    assert.strictEqual(isNextDisabled, false, 'Next button must remain enabled at index 0');

    // Attempting to click disabled prev button should stay at index 0
    await page.click('#prev-btn', { force: true, timeout: 5000 });
    const contentCheck = await page.$eval('#panel-content', el => el.textContent);
    assert.match(contentCheck, /Evidence 101/, 'Navigation must not exceed boundary index 0');
    console.log('[mapping_evidence_nav_check] Boundary check passed at index 0.');

    // -------------------------------------------------------------------------
    // Step 3: Navigate Next -> returns to Row 1 (102) then Row 2 (103)
    // -------------------------------------------------------------------------
    console.log('[mapping_evidence_nav_check] Clicking Next to row 102...');
    await page.click('#next-btn', { timeout: 5000 });
    await page.waitForSelector('#ev-102', { timeout: 5000 });

    console.log('[mapping_evidence_nav_check] Clicking Next to row 103 (failing route)...');
    await page.click('#next-btn', { timeout: 5000 });

    // Step 4: Failure handling: loading ends and error with retry is shown
    await page.waitForSelector('#panel-error:not(.d-none)', { timeout: 5000 });
    const isLoadingHidden = await page.$eval('#panel-loading', el => el.classList.contains('d-none') || el.hidden);
    assert.strictEqual(isLoadingHidden, true, 'Loading state must end when lookup fails');

    const errorMsg = await page.$eval('#error-message', el => el.textContent);
    assert.match(errorMsg, /500|Unable to load/, 'Error message must be presented on failure');
    console.log('[mapping_evidence_nav_check] Failed lookup terminated loading state and presented retry.');

    // Step 5: Retry re-fetches and recovers
    map103Fail = false;
    console.log('[mapping_evidence_nav_check] Clicking Retry...');
    await page.click('#retry-btn', { timeout: 5000 });

    await page.waitForSelector('#ev-103', { timeout: 5000 });
    const isErrorHidden = await page.$eval('#panel-error', el => el.classList.contains('d-none') || el.hidden);
    assert.strictEqual(isErrorHidden, true, 'Error state must be hidden after successful retry');

    // Boundary check at Row 2 (index 2 boundary: last row)
    isPrevDisabled = await page.$eval('#prev-btn', el => el.disabled);
    isNextDisabled = await page.$eval('#next-btn', el => el.disabled);
    assert.strictEqual(isPrevDisabled, false, 'Previous button must be enabled at index 2');
    assert.strictEqual(isNextDisabled, true, 'Next button must be disabled at last row boundary');

    // Attempting next on disabled button stays at index 2
    await page.click('#next-btn', { force: true, timeout: 5000 });
    const lastContent = await page.$eval('#panel-content', el => el.textContent);
    assert.match(lastContent, /Evidence 103/, 'Navigation must not exceed boundary index 2');
    console.log('[mapping_evidence_nav_check] Boundary check passed at last row.');

    // -------------------------------------------------------------------------
    // Step 6: Close panel restores focus to originating row button (#btn-102)
    // -------------------------------------------------------------------------
    console.log('[mapping_evidence_nav_check] Closing panel to verify focus restoration...');
    await page.click('#close-btn', { timeout: 5000 });
    await page.waitForSelector('#evidence-panel', { state: 'hidden', timeout: 5000 });

    const activeId = await page.evaluate(() => document.activeElement ? document.activeElement.id : null);
    assert.strictEqual(activeId, 'btn-102', 'Closing panel must restore focus to originating element (#btn-102)');
    console.log('[mapping_evidence_nav_check] Focus restoration verified successfully.');

    assert.strictEqual(pageErrors.length, 0, `Page errors encountered: ${pageErrors.join(', ')}`);
    console.log('\n[PASS] All mapping evidence navigation criteria verified successfully.');
  } finally {
    await browser.close();
  }
})().catch(err => {
  console.error('[FAIL]', err);
  process.exit(1);
});
