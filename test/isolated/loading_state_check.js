/**
 * test/isolated/loading_state_check.js
 *
 * Isolated real-browser DOM test for Loading State Resilience & Request Sequencing (ONTO-T-J03).
 *
 * Verifies:
 * 1. SearchInputComponentController:
 *    - Loading state entered on search() (loaderTarget visible, buttonTarget hidden).
 *    - Loading cleared after successful 200 OK response (loaderTarget hidden, buttonTarget visible, items rendered).
 *    - Loading cleared after 500 server error (loaderTarget hidden, buttonTarget visible).
 *    - Error message and retry action displayed in dropdown on error.
 *    - Retry action triggers search() again and recovers on success.
 *    - Request sequence numbers prevent slow out-of-order first responses from overwriting newer results.
 *
 * 2. MappingsVisualizationController:
 *    - Explicit set-loading/clear-loading manages visibility rather than fragile toggling.
 *    - Loading cleared after successful 200 OK mappings response (loader hidden, bubbles visible).
 *    - Loading cleared in .finally path after 500 server error.
 *    - Out-of-order slow first response does not replace the second.
 *    - Overlapping completions leave a consistent non-loading state.
 *    - Disconnect stops pending work and ignores late completions safely.
 *
 * 3. Network containment & runtime health:
 *    - All network requests served strictly from mock route fixtures; zero outside requests.
 *    - Zero uncaught browser page errors and zero Stimulus application errors.
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const path = require('path');
const assert = require('assert');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function waitFor(promise, timeoutMs = 5000, description = 'operation') {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`Timed out waiting for ${description} after ${timeoutMs}ms`)), timeoutMs))
  ]);
}

async function buildControllerBundle() {
  const result = await esbuild.build({
    stdin: {
      contents: `
        const $ = require('jquery');
        window.$ = window.jQuery = $;

        const { Application } = require('@hotwired/stimulus');
        const SearchInputController = require('${path.join(ROOT_DIR, 'app/components/search_input_component/search_input_component_controller.js')}').default;
        const MappingsVisualizationController = require('${path.join(ROOT_DIR, 'app/javascript/controllers/mappings_visualization_controller.js')}').default;

        window.__stimulusErrors = [];
        window.StimulusApp = Application.start();
        window.StimulusApp.handleError = function(error, message, detail) {
          window.__stimulusErrors.push({ error: String(error), message, detail });
        };

        window.StimulusApp.register('search-input', SearchInputController);
        window.StimulusApp.register('mappings', MappingsVisualizationController);

        window.__getController = function(element, identifier) {
          return window.StimulusApp.getControllerForElementAndIdentifier(element, identifier);
        };
      `,
      resolveDir: ROOT_DIR
    },
    bundle: true,
    format: 'iife',
    write: false,
    nodePaths: [
      '/home/ranma/.pi/agent/npm/node_modules',
      '/home/ranma/ontoportal/bioportal_web_ui/node_modules'
    ]
  });
  return result.outputFiles[0].text;
}

const HTML_FIXTURE = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Loading State Check</title>
  <style>
    .d-none { display: none !important; }
    .search-container { position: absolute; }
  </style>
</head>
<body>
  <!-- Search Input Controller fixture -->
  <div id="search-container"
       class="search-inputs"
       data-controller="search-input"
       data-search-input-ajax-url-value="/search/ontologies?q="
       data-search-input-item-link-base-value="/ontologies/"
       data-search-input-id-key-value="acronym"
       data-search-input-cache-value="false"
       data-search-input-scroll-down-value="false"
       data-search-input-selected-item-value="0"
       data-search-input-display-all-value="false">

    <div class="home-search-button">
      <a href="/search" data-search-input-target="button">SearchButton</a>
      <div class="search-component-loader d-none" data-search-input-target="loader">
        <span>Loading...</span>
      </div>
    </div>

    <input type="text"
           id="search-input-field"
           name="search"
           placeholder="Search ontologies..."
           data-action="input->search-input#search blur->search-input#blur keydown.down->search-input#arrow_down keydown.up->search-input#arrow_up keydown.enter->search-input#enter_key"
           data-search-input-target="input" />

    <div id="search-dropdown"
         class="search-container"
         data-search-input-target="dropDown"
         data-action="mousedown->search-input#prevent"
         style="display: none;">
      <a class="search-content" href="/search" data-search-input-target="actionLink">
        <p class="mb-0"></p>
        <div><p>Search all</p></div>
      </a>
    </div>

    <template data-search-input-target="template">
      <a class="search-content" href="LINK">
        <p class="name">NAME</p>
        <span class="acronym">ACRONYM</span>
      </a>
    </template>
  </div>

  <!-- Mappings Visualization Controller fixture -->
  <div id="mappings-container"
       data-controller="mappings"
       data-mappings-container-id-value="mappings-bubbles-view"
       data-mappings-mappings-list-value='{"ONTO_A": 10, "ONTO_B": 20, "ONTO_C": 30}'
       data-mappings-zoom-ratio-value="1">

    <div data-mappings-target="frame" style="width: 600px; height: 600px; overflow: auto;">
      <div id="mappings-bubbles-view" data-mappings-target="bubbles"></div>
    </div>

    <div id="mappings-loader" data-mappings-target="loader" class="d-none">Loading mappings...</div>

    <div data-mappings-target="modal">
      <a href="#" id="mappings-modal-link">Modal Link</a>
    </div>

    <div data-mappings-target="selector">
      <input type="text" id="mappings-selector-input" />
      <div class="option" data-value="ONTO_A">ONTO_A</div>
      <div class="option" data-value="ONTO_B">ONTO_B</div>
      <div class="option" data-value="ONTO_C">ONTO_C</div>
    </div>

    <div data-mappings-target="submit">
      <button type="submit" id="mappings-submit-btn">Submit</button>
    </div>

    <div data-mappings-target="ontologies">
      <select multiple>
        <option value="ONTO_A" selected>ONTO_A</option>
        <option value="ONTO_B" selected>ONTO_B</option>
        <option value="ONTO_C" selected>ONTO_C</option>
      </select>
    </div>
  </div>
</body>
</html>`;

async function runLoadingStateCheck() {
  console.log('[1/4] Building production Stimulus controller bundle with esbuild...');
  const bundleJs = await buildControllerBundle();
  console.log(`      Bundle size: ${bundleJs.length} bytes`);

  console.log('[2/4] Launching isolated headless Chromium browser...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true
  });

  const pageErrors = [];
  const testResults = {
    total: 0,
    passed: 0,
    failed: 0,
    checks: [],
    routableRequests: [],
    pageErrors: [],
    stimulusErrors: []
  };

  function recordPass(name, details = {}) {
    testResults.total++;
    testResults.passed++;
    testResults.checks.push({ name, passed: true, ...details });
    console.log(`  ✓ ${name}`);
  }

  function recordFail(name, error) {
    testResults.total++;
    testResults.failed++;
    testResults.checks.push({ name, passed: false, error: String(error) });
    console.error(`  ✗ ${name}: ${error}`);
  }

  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    page.on('pageerror', (err) => {
      const errStr = String(err);
      pageErrors.push(errStr);
      testResults.pageErrors.push(errStr);
    });

    let currentSearchHandler = null;
    let currentMappingsHandler = null;

    // Strict network routing: serve only controlled mock handlers, record and abort any outside requests
    await page.route('**/*', async (route) => {
      const url = route.request().url();
      if (url.startsWith('data:') || url.startsWith('about:')) {
        return route.continue();
      }

      if (url === 'http://portal.local/' || url === 'http://portal.local') {
        return route.fulfill({
          status: 200,
          contentType: 'text/html; charset=utf-8',
          body: HTML_FIXTURE
        });
      }

      if (url.includes('/search/ontologies')) {
        if (currentSearchHandler) {
          return currentSearchHandler(route);
        }
        return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
      }

      if (url.includes('/mappings/count/')) {
        if (currentMappingsHandler) {
          return currentMappingsHandler(route);
        }
        return route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
      }

      // Any outside or unexpected request is trapped
      testResults.routableRequests.push(url);
      await route.abort();
    });

    console.log('[3/4] Initializing isolated DOM environment in Chromium (http://portal.local/)...');
    await page.goto('http://portal.local/');
    await page.addScriptTag({ content: bundleJs });

    // Wait for controllers to connect
    await page.waitForFunction(() => {
      const searchEl = document.getElementById('search-container');
      const mappingsEl = document.getElementById('mappings-container');
      return Boolean(
        window.StimulusApp &&
        window.__getController(searchEl, 'search-input') &&
        window.__getController(mappingsEl, 'mappings')
      );
    });

    const stimulusErrors = await page.evaluate(() => window.__stimulusErrors || []);
    testResults.stimulusErrors = stimulusErrors;

    if (pageErrors.length === 0 && stimulusErrors.length === 0) {
      recordPass('Runtime health: zero browser pageerrors and zero Stimulus errors during initialization');
    } else {
      recordFail('Runtime health: zero browser pageerrors and zero Stimulus errors during initialization', {
        pageErrors,
        stimulusErrors
      });
    }

    console.log('[4/4] Executing test assertions...');

    // ------------------------------------------------------------------------
    // Group 1: SearchInputComponentController loading state & error handling
    // ------------------------------------------------------------------------

    // Check 1.1: Loading cleared after success
    {
      const d1 = deferred();
      const req1Deferred = deferred();

      currentSearchHandler = async (route) => {
        req1Deferred.resolve();
        await d1.promise;
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify([
            { acronym: 'HEART', name: 'Heart Ontology' }
          ])
        });
      };

      await page.evaluate(() => {
        const input = document.getElementById('search-input-field');
        input.value = 'heart';
        input.dispatchEvent(new Event('input', { bubbles: true }));
      });

      await waitFor(req1Deferred.promise, 5000, 'search success request to start');

      // Assert loading state is active while in flight
      const inFlight = await page.evaluate(() => {
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        return {
          loaderVisible: !loader.classList.contains('d-none'),
          buttonHidden: button.classList.contains('d-none')
        };
      });

      d1.resolve();

      await page.waitForFunction(() => {
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        const dropdown = document.querySelector('[data-search-input-target="dropDown"]');
        return loader.classList.contains('d-none') && !button.classList.contains('d-none') && dropdown.style.display === 'block';
      });

      const settled = await page.evaluate(() => {
        const dropdown = document.querySelector('[data-search-input-target="dropDown"]');
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        return {
          loaderHidden: loader.classList.contains('d-none'),
          buttonVisible: !button.classList.contains('d-none'),
          hasResult: dropdown.textContent.includes('HEART')
        };
      });

      if (inFlight.loaderVisible && inFlight.buttonHidden && settled.loaderHidden && settled.buttonVisible && settled.hasResult) {
        recordPass('search-input: loading entered on request and cleared after success');
      } else {
        recordFail('search-input: loading entered on request and cleared after success', JSON.stringify({ inFlight, settled }));
      }
    }

    // Check 1.2: Loading cleared after 500 error & error text displayed with retry
    {
      const d2 = deferred();
      const req2Deferred = deferred();

      currentSearchHandler = async (route) => {
        req2Deferred.resolve();
        await d2.promise;
        await route.fulfill({
          status: 500,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Server Error' })
        });
      };

      await page.evaluate(() => {
        const input = document.getElementById('search-input-field');
        input.value = 'fail-term';
        input.dispatchEvent(new Event('input', { bubbles: true }));
      });

      await waitFor(req2Deferred.promise, 5000, 'search error request to start');

      const inFlightError = await page.evaluate(() => {
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        return {
          loaderVisible: !loader.classList.contains('d-none'),
          buttonHidden: button.classList.contains('d-none')
        };
      });

      d2.resolve();

      await page.waitForFunction(() => {
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        const errorContainer = document.querySelector('.search-error');
        return loader.classList.contains('d-none') && !button.classList.contains('d-none') && Boolean(errorContainer);
      });

      const errorState = await page.evaluate(() => {
        const dropdown = document.querySelector('[data-search-input-target="dropDown"]');
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        const errorMsg = dropdown.querySelector('.search-error-message');
        const retryBtn = dropdown.querySelector('.search-retry-action');
        return {
          loaderHidden: loader.classList.contains('d-none'),
          buttonVisible: !button.classList.contains('d-none'),
          dropdownOpen: dropdown.style.display === 'block',
          messageText: errorMsg ? errorMsg.textContent : '',
          hasRetryBtn: Boolean(retryBtn),
          retryBtnText: retryBtn ? retryBtn.textContent.trim() : ''
        };
      });

      if (inFlightError.loaderVisible && inFlightError.buttonHidden &&
          errorState.loaderHidden && errorState.buttonVisible &&
          errorState.dropdownOpen && errorState.messageText.includes('Failed to load results') &&
          errorState.hasRetryBtn && errorState.retryBtnText === 'Retry') {
        recordPass('search-input: loading cleared after 500 error; short error message and retry action displayed');
      } else {
        recordFail('search-input: loading cleared after 500 error; short error message and retry action displayed', JSON.stringify({ inFlightError, errorState }));
      }
    }

    // Check 1.3: Retry recovers
    {
      const d3 = deferred();
      const req3Deferred = deferred();

      currentSearchHandler = async (route) => {
        req3Deferred.resolve();
        await d3.promise;
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify([
            { acronym: 'RECOVERED_ONTO', name: 'Recovered Ontology' }
          ])
        });
      };

      await page.click('.search-retry-action');

      await waitFor(req3Deferred.promise, 5000, 'retry request to start');

      const inFlightRetry = await page.evaluate(() => {
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        return {
          loaderVisible: !loader.classList.contains('d-none'),
          buttonHidden: button.classList.contains('d-none')
        };
      });

      d3.resolve();

      await page.waitForFunction(() => {
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        const dropdown = document.querySelector('[data-search-input-target="dropDown"]');
        return loader.classList.contains('d-none') && !button.classList.contains('d-none') && dropdown.textContent.includes('RECOVERED_ONTO');
      });

      const recoveredState = await page.evaluate(() => {
        const dropdown = document.querySelector('[data-search-input-target="dropDown"]');
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        return {
          loaderHidden: loader.classList.contains('d-none'),
          buttonVisible: !button.classList.contains('d-none'),
          hasRecoveredItem: dropdown.textContent.includes('RECOVERED_ONTO'),
          errorRemoved: !dropdown.querySelector('.search-error')
        };
      });

      if (inFlightRetry.loaderVisible && inFlightRetry.buttonHidden &&
          recoveredState.loaderHidden && recoveredState.buttonVisible &&
          recoveredState.hasRecoveredItem && recoveredState.errorRemoved) {
        recordPass('search-input: retry recovers; loading entered, cleared, and results rendered');
      } else {
        recordFail('search-input: retry recovers; loading entered, cleared, and results rendered', JSON.stringify({ inFlightRetry, recoveredState }));
      }
    }

    // Check 1.4: Out-of-order slow first response does not replace second
    {
      const dSlow = deferred();
      const reqSlowDeferred = deferred();
      const dFast = deferred();
      const reqFastDeferred = deferred();

      currentSearchHandler = async (route) => {
        const url = route.request().url();
        if (url.includes('query-slow')) {
          reqSlowDeferred.resolve();
          await dSlow.promise;
          await route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify([{ acronym: 'SLOW_ONTO', name: 'Slow Ontology' }])
          });
        } else if (url.includes('query-fast')) {
          reqFastDeferred.resolve();
          await dFast.promise;
          await route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify([{ acronym: 'FAST_ONTO', name: 'Fast Ontology' }])
          });
        }
      };

      // 1. Fire slow query
      await page.evaluate(() => {
        const input = document.getElementById('search-input-field');
        input.value = 'query-slow';
        input.dispatchEvent(new Event('input', { bubbles: true }));
      });
      await waitFor(reqSlowDeferred.promise, 5000, 'slow search request to start');

      // 2. Fire fast query while slow is in flight
      await page.evaluate(() => {
        const input = document.getElementById('search-input-field');
        input.value = 'query-fast';
        input.dispatchEvent(new Event('input', { bubbles: true }));
      });
      await waitFor(reqFastDeferred.promise, 5000, 'fast search request to start');

      // 3. Complete fast query first
      dFast.resolve();

      await page.waitForFunction(() => {
        const dropdown = document.querySelector('[data-search-input-target="dropDown"]');
        return dropdown.textContent.includes('FAST_ONTO');
      });

      // 4. Complete slow query late
      dSlow.resolve();
      await page.waitForTimeout(100);

      const sequencingState = await page.evaluate(() => {
        const dropdown = document.querySelector('[data-search-input-target="dropDown"]');
        const loader = document.querySelector('[data-search-input-target="loader"]');
        const button = document.querySelector('[data-search-input-target="button"]');
        return {
          hasFast: dropdown.textContent.includes('FAST_ONTO'),
          hasSlow: dropdown.textContent.includes('SLOW_ONTO'),
          loaderHidden: loader.classList.contains('d-none'),
          buttonVisible: !button.classList.contains('d-none')
        };
      });

      if (sequencingState.hasFast && !sequencingState.hasSlow && sequencingState.loaderHidden && sequencingState.buttonVisible) {
        recordPass('search-input: out-of-order slow first response does not replace second response');
      } else {
        recordFail('search-input: out-of-order slow first response does not replace second response', JSON.stringify(sequencingState));
      }
    }

    // ------------------------------------------------------------------------
    // Group 2: MappingsVisualizationController loading state & sequence safety
    // ------------------------------------------------------------------------

    // Check 2.1: Loading cleared after success
    {
      const dm1 = deferred();
      const reqM1Deferred = deferred();

      currentMappingsHandler = async (route) => {
        reqM1Deferred.resolve();
        await dm1.promise;
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify([
            { target_ontology: { acronym: 'ONTO_B' }, count: 15 }
          ])
        });
      };

      await page.evaluate(() => {
        const el = document.getElementById('mappings-container');
        const ctrl = window.__getController(el, 'mappings');
        ctrl.drawBubbles(ctrl.mappingsListValue);
      });

      await page.evaluate(() => {
        const bubble = document.querySelector('g.leaf[data-acronym="ONTO_A"]');
        bubble.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      });

      await waitFor(reqM1Deferred.promise, 5000, 'mappings success request to start');

      const inFlightM1 = await page.evaluate(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return {
          loaderVisible: !loader.classList.contains('d-none'),
          bubblesHidden: bubbles.classList.contains('d-none')
        };
      });

      dm1.resolve();

      await page.waitForFunction(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return loader.classList.contains('d-none') && !bubbles.classList.contains('d-none');
      });

      const mappingsSuccess = await page.evaluate(() => {
        const leafB = document.querySelector('g.leaf[data-acronym="ONTO_B"]');
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return {
          loaderHidden: loader.classList.contains('d-none'),
          bubblesVisible: !bubbles.classList.contains('d-none'),
          leafBHighlighted: leafB ? leafB.getAttribute('data-highlighted') : null
        };
      });

      if (inFlightM1.loaderVisible && inFlightM1.bubblesHidden &&
          mappingsSuccess.loaderHidden && mappingsSuccess.bubblesVisible &&
          mappingsSuccess.leafBHighlighted === 'true') {
        recordPass('mappings: loading entered on selection and cleared after success');
      } else {
        recordFail('mappings: loading entered on selection and cleared after success', JSON.stringify({ inFlightM1, mappingsSuccess }));
      }
    }

    // Check 2.2: Loading cleared after 500 error
    {
      const dm2 = deferred();
      const reqM2Deferred = deferred();

      currentMappingsHandler = async (route) => {
        reqM2Deferred.resolve();
        await dm2.promise;
        await route.fulfill({
          status: 500,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'Mappings failure' })
        });
      };

      await page.evaluate(() => {
        const el = document.getElementById('mappings-container');
        const ctrl = window.__getController(el, 'mappings');
        ctrl.drawBubbles(ctrl.mappingsListValue);
      });

      await page.evaluate(() => {
        const bubble = document.querySelector('g.leaf[data-acronym="ONTO_B"]');
        bubble.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      });

      await waitFor(reqM2Deferred.promise, 5000, 'mappings error request to start');

      const inFlightM2 = await page.evaluate(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return {
          loaderVisible: !loader.classList.contains('d-none'),
          bubblesHidden: bubbles.classList.contains('d-none')
        };
      });

      dm2.resolve();

      await page.waitForFunction(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return loader.classList.contains('d-none') && !bubbles.classList.contains('d-none');
      });

      const mappingsErrorCleared = await page.evaluate(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return {
          loaderHidden: loader.classList.contains('d-none'),
          bubblesVisible: !bubbles.classList.contains('d-none')
        };
      });

      if (inFlightM2.loaderVisible && inFlightM2.bubblesHidden &&
          mappingsErrorCleared.loaderHidden && mappingsErrorCleared.bubblesVisible) {
        recordPass('mappings: loading cleared in complete/finally path after 500 error');
      } else {
        recordFail('mappings: loading cleared in complete/finally path after 500 error', JSON.stringify({ inFlightM2, mappingsErrorCleared }));
      }
    }

    // Check 2.3: Overlapping completions leave a consistent non-loading state
    {
      const dmA = deferred();
      const reqMADeferred = deferred();
      const dmB = deferred();
      const reqMBDeferred = deferred();

      currentMappingsHandler = async (route) => {
        const url = route.request().url();
        if (url.includes('/mappings/count/ONTO_A')) {
          reqMADeferred.resolve();
          await dmA.promise;
          await route.fulfill({
            status: 500,
            contentType: 'application/json',
            body: JSON.stringify({ error: 'Superseded failure' })
          });
        } else if (url.includes('/mappings/count/ONTO_B')) {
          reqMBDeferred.resolve();
          await dmB.promise;
          await route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify([
              { target_ontology: { acronym: 'ONTO_C' }, count: 77 }
            ])
          });
        }
      };

      await page.evaluate(() => {
        const el = document.getElementById('mappings-container');
        const ctrl = window.__getController(el, 'mappings');
        ctrl.drawBubbles(ctrl.mappingsListValue);
      });

      // Click ONTO_A
      await page.evaluate(() => {
        const b = document.querySelector('g.leaf[data-acronym="ONTO_A"]');
        b.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      });
      await waitFor(reqMADeferred.promise, 5000, 'mappings A request to start');

      // While ONTO_A is in flight, click ONTO_B
      await page.evaluate(() => {
        const b = document.querySelector('g.leaf[data-acronym="ONTO_B"]');
        b.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      });
      await waitFor(reqMBDeferred.promise, 5000, 'mappings B request to start');

      // Assert loader visible while overlapping
      const overlappingInFlight = await page.evaluate(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return {
          loaderVisible: !loader.classList.contains('d-none'),
          bubblesHidden: bubbles.classList.contains('d-none')
        };
      });

      // Complete request A (stale)
      dmA.resolve();
      await page.waitForTimeout(50);

      // Loader should remain active because request B is still active
      const midState = await page.evaluate(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return {
          loaderVisible: !loader.classList.contains('d-none'),
          bubblesHidden: bubbles.classList.contains('d-none')
        };
      });

      // Complete request B
      dmB.resolve();

      await page.waitForFunction(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        return loader.classList.contains('d-none') && !bubbles.classList.contains('d-none');
      });

      const overlappingFinal = await page.evaluate(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        const leafC = document.querySelector('g.leaf[data-acronym="ONTO_C"]');
        return {
          loaderHidden: loader.classList.contains('d-none'),
          bubblesVisible: !bubbles.classList.contains('d-none'),
          leafCHighlighted: leafC ? leafC.getAttribute('data-highlighted') : null
        };
      });

      if (overlappingInFlight.loaderVisible && midState.loaderVisible &&
          overlappingFinal.loaderHidden && overlappingFinal.bubblesVisible &&
          overlappingFinal.leafCHighlighted === 'true') {
        recordPass('mappings: overlapping completions leave a consistent non-loading state without inversion');
      } else {
        recordFail('mappings: overlapping completions leave a consistent non-loading state without inversion', JSON.stringify({ overlappingInFlight, midState, overlappingFinal }));
      }
    }

    // Check 2.4: Out-of-order slow first response does not replace second
    {
      const dmSlow = deferred();
      const reqMSlowDeferred = deferred();
      const dmFast = deferred();
      const reqMFastDeferred = deferred();

      currentMappingsHandler = async (route) => {
        const url = route.request().url();
        if (url.includes('/mappings/count/ONTO_A')) {
          reqMSlowDeferred.resolve();
          await dmSlow.promise;
          await route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify([
              { target_ontology: { acronym: 'ONTO_B' }, count: 111 }
            ])
          });
        } else if (url.includes('/mappings/count/ONTO_B')) {
          reqMFastDeferred.resolve();
          await dmFast.promise;
          await route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify([
              { target_ontology: { acronym: 'ONTO_A' }, count: 222 }
            ])
          });
        }
      };

      await page.evaluate(() => {
        const el = document.getElementById('mappings-container');
        const ctrl = window.__getController(el, 'mappings');
        ctrl.drawBubbles(ctrl.mappingsListValue);
      });

      // 1. Click ONTO_A (slow)
      await page.evaluate(() => {
        const b = document.querySelector('g.leaf[data-acronym="ONTO_A"]');
        b.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      });
      await waitFor(reqMSlowDeferred.promise, 5000, 'mappings slow request to start');

      // 2. Click ONTO_B (fast)
      await page.evaluate(() => {
        const b = document.querySelector('g.leaf[data-acronym="ONTO_B"]');
        b.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      });
      await waitFor(reqMFastDeferred.promise, 5000, 'mappings fast request to start');

      // 3. Fulfill fast request first
      dmFast.resolve();

      await page.waitForFunction(() => {
        const loader = document.getElementById('mappings-loader');
        const leafA = document.querySelector('g.leaf[data-acronym="ONTO_A"]');
        return loader.classList.contains('d-none') && leafA.getAttribute('data-highlighted') === 'true';
      });

      // 4. Fulfill slow request late
      dmSlow.resolve();
      await page.waitForTimeout(100);

      const outOfOrderMappingsState = await page.evaluate(() => {
        const loader = document.getElementById('mappings-loader');
        const bubbles = document.getElementById('mappings-bubbles-view');
        const leafA = document.querySelector('g.leaf[data-acronym="ONTO_A"]');
        const leafB = document.querySelector('g.leaf[data-acronym="ONTO_B"]');
        return {
          loaderHidden: loader.classList.contains('d-none'),
          bubblesVisible: !bubbles.classList.contains('d-none'),
          leafAHighlighted: leafA ? leafA.getAttribute('data-highlighted') : null,
          leafBSelected: leafB ? leafB.getAttribute('data-selected') : null
        };
      });

      if (outOfOrderMappingsState.loaderHidden && outOfOrderMappingsState.bubblesVisible &&
          outOfOrderMappingsState.leafAHighlighted === 'true' && outOfOrderMappingsState.leafBSelected === 'true') {
        recordPass('mappings: out-of-order slow first response does not replace second completion');
      } else {
        recordFail('mappings: out-of-order slow first response does not replace second completion', JSON.stringify(outOfOrderMappingsState));
      }
    }

    // Check 2.5: Disconnect stops / ignores pending work safely
    {
      const dmDisc = deferred();
      const reqMDiscDeferred = deferred();

      currentMappingsHandler = async (route) => {
        reqMDiscDeferred.resolve();
        await dmDisc.promise;
        await route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify([{ target_ontology: { acronym: 'ONTO_A' }, count: 1 }])
        });
      };

      await page.evaluate(() => {
        const el = document.getElementById('mappings-container');
        const ctrl = window.__getController(el, 'mappings');
        ctrl.drawBubbles(ctrl.mappingsListValue);
      });

      await page.evaluate(() => {
        const b = document.querySelector('g.leaf[data-acronym="ONTO_B"]');
        b.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      });
      await waitFor(reqMDiscDeferred.promise, 5000, 'mappings disconnect test request to start');

      // Disconnect by removing container
      await page.evaluate(() => {
        const container = document.getElementById('mappings-container');
        container.remove();
      });

      // Late resolution after disconnect
      dmDisc.resolve();
      await page.waitForTimeout(100);

      const postDiscErrors = await page.evaluate(() => window.__stimulusErrors || []);

      if (postDiscErrors.length === 0 && pageErrors.length === 0) {
        recordPass('mappings & search: late resolution after disconnect produces zero uncaught errors');
      } else {
        recordFail('mappings & search: late resolution after disconnect produces zero uncaught errors', JSON.stringify({ postDiscErrors, pageErrors }));
      }
    }

    // ------------------------------------------------------------------------
    // Group 3: Network containment
    // ------------------------------------------------------------------------
    if (testResults.routableRequests.length === 0) {
      recordPass('Network containment: zero routable network requests initiated', {
        routableRequests: 0
      });
    } else {
      recordFail('Network containment: zero routable network requests initiated', {
        routableRequests: testResults.routableRequests
      });
    }

  } catch (err) {
    console.error('Fatal error during test run:', err);
    recordFail('Execution fatal error', err);
  } finally {
    await browser.close();
  }

  console.log('\n--- Test Summary ---');
  console.log(`Total checks: ${testResults.total}`);
  console.log(`Passed:       ${testResults.passed}`);
  console.log(`Failed:       ${testResults.failed}`);

  return testResults;
}

if (require.main === module) {
  runLoadingStateCheck().then((results) => {
    if (results.failed > 0) {
      process.exit(1);
    }
  }).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { runLoadingStateCheck };
