// Standalone Isolated Browser DOM Wire Protocol Check (ONTO-T-J02)
//
// Validates end-to-end integration between loaded Rails SearchController#json_search
// action responses, useBioportalAutoComplete first-party wrapper, and the vendor
// crossdomain_autocomplete jQuery plugin in headless Chromium.
//
// Key Contracts Verified:
// 1. Genuinely exported native Rails ActionDispatch response bodies consumed directly.
// 2. First-party wrapper automatically opts into response=rows on same-origin endpoints (NO JSONP).
// 3. Single ontology path (/search/json_search/TEST) returns exactly 8 columns (7 extra) with CGI-encoded definition.
// 4. Default text fallback uses textContent at both dataToDom and findValueCallback (no XSS).
// 5. findValue in rows mode updates cache and serves repeat identical queries without network requests.
// 6. Bare plugin without explicit response option retains legacy JSONP defaults.
// 7. First-party wrapper on cross-origin URLs retains legacy JSONP defaults.
// 8. Query builder percent-encodes special chars and strips hash fragments.
// 9. Empty search results ([]) route through controlled no-results path without appendChild/autofill exceptions.
// 10. Strict network auditing: exact origin & path matching before fulfillment, independent request tracking.

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');
const esbuild = require('esbuild');
const { chromium } = require('playwright');

const REPO_ROOT = path.resolve(__dirname, '../..');
const FIXTURE_JSON_PATH = path.join(REPO_ROOT, '.remediation/native_producer_fixtures.json');
const AUDIT_OUTPUT_PATH = path.join(REPO_ROOT, '.remediation/autocomplete_wire_request_audit.json');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

const EXPECTED_COMPLEX_LABEL = 'Complex | "Cat" \\ \n 🌍 ~!~';
const EXPECTED_COMPLEX_ID = 'http://example.org/test#Complex\\Cat"1"';
const EXPECTED_LEGACY_LABEL = 'Cat "Concept" \\ \nLegacy';

// Regenerate native producer responses every browser run via frozen Ruby 3.1.7 container
function loadNativeProducerOutputs() {
  fs.mkdirSync(path.dirname(FIXTURE_JSON_PATH), { recursive: true });
  const cmd = `docker run --rm --network none -v "${REPO_ROOT}":/app:ro -w /app -e GEM_PATH=/usr/local/bundle/ruby/3.1.0 onto-q02-proof:af254f34 ruby test/standalone/export_native_producer_fixtures.rb`;
  const stdout = execSync(cmd, { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 });
  fs.writeFileSync(FIXTURE_JSON_PATH, stdout, 'utf8');
  return JSON.parse(stdout);
}

// Rebind dynamic jQuery JSONP callback prefix in genuinely native-produced body without reserializing data
function rebindNativeJsonp(fixture, callbackName) {
  if (!/^[a-zA-Z_$][a-zA-Z0-9_$]*(\.[a-zA-Z_$][a-zA-Z0-9_$]*)*$/.test(callbackName)) {
    throw new Error('Invalid callback name: ' + callbackName);
  }
  const reboundBody = fixture.body.replace(/^PORTAL_JSONP_CALLBACK\(/, `${callbackName}(`);
  return {
    status: fixture.status,
    contentType: fixture.contentType,
    body: reboundBody
  };
}

async function buildControllerBundle() {
  const result = await esbuild.build({
    stdin: {
      contents: `
        const $ = require('jquery');
        window.$ = window.jQuery = $;
        window.$.browser = window.$.browser || { msie: false, version: '11' };

        require('../../vendor/assets/javascripts/autocomplete/crossdomain_autocomplete.js');
        const { useBioportalAutoComplete } = require('../../app/javascript/mixins/useBioportalAutoComplete.js');
        window.useBioportalAutoComplete = useBioportalAutoComplete;

        const { Application } = require('@hotwired/stimulus');
        const OntoportalAutocompleteController = require('../../app/javascript/controllers/ontoportal_autocomplete_controller.js').default;
        const FormAutoCompleteController = require('../../app/javascript/controllers/form_auto_complete_controller.js').default;

        const application = Application.start();
        window.__stimulusErrors = [];
        const origHandleError = application.handleError.bind(application);
        application.handleError = function(error, message, detail) {
          window.__stimulusErrors.push({
            message: message || (error && error.message) || String(error),
            error: error ? (error.stack || error.message || String(error)) : null,
            detail: detail || null
          });
          origHandleError(error, message, detail);
        };

        application.register('ontoportal-autocomplete', OntoportalAutocompleteController);
        application.register('form-auto-complete', FormAutoCompleteController);
        window.StimulusApp = application;
      `,
      resolveDir: __dirname,
      sourcefile: 'wire_entrypoint.js'
    },
    bundle: true,
    write: false,
    format: 'iife',
    target: 'es2020',
    platform: 'browser',
    nodePaths: [
      path.resolve(REPO_ROOT, 'node_modules'),
      '/home/ranma/.pi/agent/npm/node_modules',
      '/home/ranma/ontoportal/bioportal_web_ui/node_modules'
    ]
  });

  return result.outputFiles[0].text;
}

const HTML_FIXTURE = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>MatPortal Autocomplete Wire Check</title>
  <style>
    .obsolete_class { color: gray; }
    .result_class_highlight { background-color: yellow; }
    .ac_results { position: absolute; background: white; border: 1px solid #ccc; z-index: 10000; }
    .ac_results ul { list-style: none; margin: 0; padding: 0; }
    .ac_results li { padding: 4px; cursor: pointer; }
    .ac_over { background: #eee; }
  </style>
  <script>
    window.__xssTriggered = [];
    window.BP_INTERNAL_SEARCH_SERVER = "";
  </script>
</head>
<body>
  <!-- Same-origin Stimulus Ontoportal Autocomplete input -->
  <div id="onto-container">
    <input type="text" id="onto-input"
           data-controller="ontoportal-autocomplete"
           data-ontoportal-autocomplete-ontology-acronym-value="TEST"
           value="" />
  </div>

  <!-- Same-origin Single Ontology Form Autocomplete input -->
  <div id="form-single-container">
    <input type="text" id="form-single-input"
           data-controller="form-auto-complete"
           data-form-auto-complete-ontology-id-value="TEST"
           data-form-auto-complete-target-property-value="name"
           data-form-auto-complete-include-definition-value="true"
           value="" />
  </div>

  <!-- Bare plugin input for textContent fallback check -->
  <div id="fallback-container">
    <input type="text" id="fallback-input" value="" />
  </div>

  <!-- Bare plugin legacy input -->
  <div id="legacy-bare-container">
    <input type="text" id="legacy-bare-input" value="" />
  </div>

  <!-- Cross-origin wrapper input -->
  <div id="crossorigin-container">
    <input type="text" id="crossorigin-input" value="" />
  </div>

  <!-- Query encoding inspection input -->
  <div id="query-encoding-container">
    <input type="text" id="query-encoding-input" value="" />
  </div>

  <!-- Empty results regression input -->
  <div id="empty-results-container">
    <input type="text" id="empty-results-input" value="" />
  </div>
</body>
</html>`;

const ALLOWED_ORIGINS = new Set([
  'http://portal.local',
  'http://crossorigin.external'
]);

const ALLOWED_PATHS = new Set([
  '/',
  '/search/json_search',
  '/search/json_search/TEST',
  '/search/legacy_search'
]);

async function runWireCheck() {
  console.log('[0/4] Exporting fresh native producer responses via frozen Ruby 3.1.7 container...');
  const NATIVE_PRODUCER_OUTPUTS = loadNativeProducerOutputs();

  const testResults = {
    total: 0,
    passed: 0,
    failed: 0,
    checks: [],
    navigationRequests: 0,
    widgetFixtureRequests: 0,
    contextRequests: [],
    routedRequests: [],
    outsideRequests: [],
    unexpectedRequests: [],
    pageErrors: [],
    stimulusErrors: []
  };

  function recordPass(description, details = {}) {
    testResults.total++;
    testResults.passed++;
    testResults.checks.push({ status: 'PASS', description, details });
    console.log(`  ✓ ${description}`);
  }

  function recordFail(description, details = {}) {
    testResults.total++;
    testResults.failed++;
    testResults.checks.push({ status: 'FAIL', description, details });
    console.error(`  ✗ ${description}:`, details);
  }

  console.log('[1/4] Building production Stimulus & vendor bundle with esbuild...');
  const bundleCode = await buildControllerBundle();
  console.log(`      Bundle size: ${bundleCode.length} bytes`);

  console.log('[2/4] Launching isolated headless Chromium browser...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check'
    ]
  });

  try {
    const context = await browser.newContext();
    const page = await context.newPage();

    page.on('pageerror', (err) => {
      testResults.pageErrors.push(err.message);
    });

    // Independent request event accounting (context.on / page.on)
    page.on('request', (req) => {
      testResults.contextRequests.push({
        url: req.url(),
        method: req.method(),
        resourceType: req.resourceType(),
        time: Date.now()
      });
    });

    // Request interception with strict exact origin and path validation BEFORE fulfillment
    await page.route('**/*', (route) => {
      const req = route.request();
      const urlStr = req.url();
      const method = req.method();
      const resourceType = req.resourceType();

      let parsedUrl;
      try {
        parsedUrl = new URL(urlStr);
      } catch (e) {
        testResults.outsideRequests.push(urlStr);
        testResults.unexpectedRequests.push(urlStr);
        return route.abort('blockedbyclient');
      }

      const normalizedPath = parsedUrl.pathname.length > 1 && parsedUrl.pathname.endsWith('/')
        ? parsedUrl.pathname.slice(0, -1)
        : parsedUrl.pathname;

      testResults.routedRequests.push({
        url: urlStr,
        origin: parsedUrl.origin,
        pathname: normalizedPath,
        method,
        resourceType,
        time: Date.now()
      });

      // 1. Strict exact origin comparison
      if (!ALLOWED_ORIGINS.has(parsedUrl.origin)) {
        testResults.outsideRequests.push(urlStr);
        testResults.unexpectedRequests.push(urlStr);
        return route.abort('blockedbyclient');
      }

      // 2. Strict exact pathname comparison
      if (!ALLOWED_PATHS.has(normalizedPath)) {
        testResults.outsideRequests.push(urlStr);
        testResults.unexpectedRequests.push(urlStr);
        return route.abort('blockedbyclient');
      }

      // 3. Navigation root
      if (parsedUrl.origin === 'http://portal.local' && normalizedPath === '/') {
        testResults.navigationRequests++;
        return route.fulfill({
          status: 200,
          contentType: 'text/html; charset=utf-8',
          body: HTML_FIXTURE
        });
      }

      // 4. Widget fixture endpoints
      testResults.widgetFixtureRequests++;
      const searchParams = parsedUrl.searchParams;
      const q = searchParams.get('q') || '';
      const responseMode = searchParams.get('response');
      const callbackName = searchParams.get('callback');
      const queryId = searchParams.get('id');

      // Same-origin single ontology path: /search/json_search/TEST (8 columns)
      if (parsedUrl.origin === 'http://portal.local' && normalizedPath === '/search/json_search/TEST') {
        if (q === 'nomatch' || q === 'empty') {
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_empty);
        }
        if (responseMode === 'rows') {
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_single);
        }
        if (responseMode === 'json' && callbackName) {
          return route.fulfill(rebindNativeJsonp(NATIVE_PRODUCER_OUTPUTS.legacy_jsonp, callbackName));
        }
        return route.fulfill(NATIVE_PRODUCER_OUTPUTS.legacy_text);
      }

      // Same-origin generic search endpoint: /search/json_search
      if (parsedUrl.origin === 'http://portal.local' && normalizedPath === '/search/json_search') {
        if (q.includes('probe')) {
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_xss_probe);
        }
        if (q === 'nomatch' || q === 'empty') {
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_empty);
        }
        if (responseMode === 'rows') {
          if (queryId === 'TEST') {
            return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_single);
          }
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_all);
        }
        if (responseMode === 'json' && callbackName) {
          return route.fulfill(rebindNativeJsonp(NATIVE_PRODUCER_OUTPUTS.legacy_jsonp, callbackName));
        }
        return route.fulfill(NATIVE_PRODUCER_OUTPUTS.legacy_text);
      }

      // Legacy search endpoint (/search/legacy_search)
      if (parsedUrl.origin === 'http://portal.local' && normalizedPath === '/search/legacy_search') {
        if (responseMode === 'json' && callbackName) {
          return route.fulfill(rebindNativeJsonp(NATIVE_PRODUCER_OUTPUTS.legacy_jsonp, callbackName));
        }
        return route.fulfill(NATIVE_PRODUCER_OUTPUTS.legacy_text);
      }

      // Cross-origin search endpoint (http://crossorigin.external/search/json_search)
      if (parsedUrl.origin === 'http://crossorigin.external' && normalizedPath === '/search/json_search') {
        if (responseMode === 'json' && callbackName) {
          return route.fulfill(rebindNativeJsonp(NATIVE_PRODUCER_OUTPUTS.legacy_jsonp, callbackName));
        }
        if (responseMode === 'rows') {
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_all);
        }
        return route.fulfill(NATIVE_PRODUCER_OUTPUTS.legacy_text);
      }

      testResults.unexpectedRequests.push(urlStr);
      return route.abort('blockedbyclient');
    });

    console.log('[3/4] Navigating to synthetic same-origin environment (http://portal.local/)...');
    await page.goto('http://portal.local/');
    await page.addScriptTag({ content: bundleCode });

    // Wait for Stimulus application readiness
    await page.waitForFunction(() => typeof window.StimulusApp !== 'undefined');

    const initStimErrors = await page.evaluate(() => window.__stimulusErrors || []);
    if (initStimErrors.length === 0 && testResults.pageErrors.length === 0) {
      recordPass('Runtime health: zero browser pageerrors and zero Stimulus errors during startup', {
        pageErrors: testResults.pageErrors.length,
        stimulusErrors: initStimErrors.length
      });
    } else {
      recordFail('Runtime health: startup errors encountered', {
        pageErrors: testResults.pageErrors,
        stimulusErrors: initStimErrors
      });
    }

    console.log('[4/4] Executing wire protocol assertions...');

    // ------------------------------------------------------------------------
    // Test 1: First-party wrapper same-origin rows opt-in (NO JSONP)
    // ------------------------------------------------------------------------
    const t1Start = testResults.routedRequests.length;
    const test1 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('onto-input');
        const autocompleter = input.autocompleter;
        const opts = autocompleter.getOptions();

        let settled = false;
        let poll = null;
        let timer = null;

        function cleanup() {
          if (poll) clearInterval(poll);
          if (timer) clearTimeout(timer);
          $(document).off('autocomplete_selected');
        }

        // Deadline remains active UNTIL autocomplete_selected resolves or times out
        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 1 timed out waiting for autocomplete_selected'));
        }, 4000);

        opts.onItemSelect = function(li) {};

        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 2) {
            clearInterval(poll);
            poll = null;

            const firstLi = lis.get(0);
            const secondLi = lis.get(1);

            const secondHasObsolete = secondLi.querySelector('.obsolete_class') !== null;
            const secondText = secondLi.textContent;
            const firstExtra = firstLi.extra;
            const firstSelectValue = firstLi.selectValue;

            $(document).one('autocomplete_selected', () => {
              if (settled) return;
              settled = true;
              cleanup();
              resolve({
                optsResponse: opts.response,
                liCount: lis.length,
                firstSelectValue,
                firstExtraCount: firstExtra ? firstExtra.length : 0,
                firstExtraConceptId: firstExtra ? firstExtra[0] : null,
                firstExtraAcronym: firstExtra ? firstExtra[2] : null,
                firstExtraTargetValue: firstExtra ? firstExtra[4] : null,
                secondHasObsolete,
                secondText,
                inputValueAfterSelect: input.value,
                eventFired: true
              });
            });

            $(firstLi).trigger('click');
          }
        }, 50);
      });
    });

    const t1Request = testResults.routedRequests.slice(t1Start).find(r => r.url.includes('/search/json_search'));
    const t1Url = t1Request ? new URL(t1Request.url) : null;
    const t1ResponseParam = t1Url ? t1Url.searchParams.get('response') : null;
    const t1CallbackParam = t1Url ? t1Url.searchParams.get('callback') : null;

    if (test1.optsResponse === 'rows' &&
        t1ResponseParam === 'rows' &&
        t1CallbackParam === null &&
        test1.liCount === 2 &&
        test1.firstSelectValue === EXPECTED_COMPLEX_LABEL &&
        test1.firstExtraCount === 7 && // Exactly 8 columns total (1 selectValue + 7 extra fields)
        test1.firstExtraConceptId === EXPECTED_COMPLEX_ID &&
        test1.firstExtraTargetValue === EXPECTED_COMPLEX_LABEL &&
        test1.firstExtraAcronym === 'TEST' &&
        test1.secondHasObsolete &&
        test1.eventFired) {
      recordPass('First-party wrapper on same-origin URL opts into rows (NO JSONP) with full popup rendering and selection mapping', {
        responseParam: t1ResponseParam,
        callbackParam: t1CallbackParam,
        firstSelectValue: test1.firstSelectValue,
        firstExtraConceptId: test1.firstExtraConceptId,
        secondHasObsolete: test1.secondHasObsolete
      });
    } else {
      recordFail('First-party wrapper on same-origin URL opts into rows (NO JSONP)', { test1, t1Request });
    }

    // ------------------------------------------------------------------------
    // Test 2: Single Ontology Form Autocomplete (8 columns)
    // ------------------------------------------------------------------------
    const t2Start = testResults.routedRequests.length;
    const test2 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('form-single-input');
        const autocompleter = input.autocompleter;
        const opts = autocompleter.getOptions();

        let settled = false;
        let poll = null;
        let timer = null;

        function cleanup() {
          if (poll) clearInterval(poll);
          if (timer) clearTimeout(timer);
        }

        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 2 timed out waiting for single ontology ac_results'));
        }, 4000);

        autocompleter.flushCache();
        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 1) {
            settled = true;
            cleanup();
            const li = lis.get(0);
            resolve({
              optsResponse: opts.response,
              liCount: lis.length,
              selectValue: li.selectValue,
              extraLength: li.extra ? li.extra.length : 0,
              conceptId: li.extra ? li.extra[0] : null,
              targetValue: li.extra ? li.extra[4] : null,
              encodedDefinition: li.extra ? li.extra[6] : null
            });
          }
        }, 50);
      });
    });

    const t2Request = testResults.routedRequests.slice(t2Start).find(r => r.url.includes('/search/json_search'));
    const t2Url = t2Request ? new URL(t2Request.url) : null;

    if (t2Url && t2Url.searchParams.get('response') === 'rows' &&
        test2.selectValue === EXPECTED_COMPLEX_LABEL &&
        test2.extraLength === 7 && // 8 columns total: selectValue (col 0) + 7 extra fields
        test2.conceptId === EXPECTED_COMPLEX_ID &&
        test2.targetValue === EXPECTED_COMPLEX_LABEL &&
        test2.encodedDefinition === 'Def+%7C+1.+Def+~%21~+2') {
      recordPass('Single ontology rows wire protocol returns exactly 8 columns (7 extra) with CGI-encoded definition', test2);
    } else {
      recordFail('Single ontology rows wire protocol', { test2, t2Request });
    }

    // ------------------------------------------------------------------------
    // Test 3: Default Text Fallback (No Formatter) neutralizes markup in textContent
    // ------------------------------------------------------------------------
    const test3 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        $('div.ac_results').hide();
        const input = document.getElementById('fallback-input');
        $(input).bioportal_autocomplete('/search/json_search', {
          response: 'rows',
          minChars: 1,
          delay: 10
        });

        const autocompleter = input.autocompleter;
        let settled = false;
        let poll = null;
        let timer = null;

        function cleanup() {
          if (poll) clearInterval(poll);
          if (timer) clearTimeout(timer);
          if (autocompleter) autocompleter.getOptions().onFindValue = null;
        }

        // Deadline remains active through onFindValue
        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 3 timed out waiting for probe ac_results and onFindValue'));
        }, 4000);

        $(input).focus();
        $(input).val('probe');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 1) {
            clearInterval(poll);
            poll = null;

            const li = lis.get(0);
            const injectedNode = document.getElementById('injected_dom');
            const xssCount = window.__xssTriggered.length;
            const textContent = li.textContent;
            const innerHTML = li.innerHTML;

            $(input).val('<script>window.__xssTriggered.push("probe_fail")</script><b id="injected_dom">Injected</b>');
            autocompleter.getOptions().onFindValue = function(findLi) {
              if (settled) return;
              settled = true;
              cleanup();
              resolve({
                hasInjectedNodeInDom: injectedNode !== null,
                findValueInjectedInDom: document.getElementById('injected_dom') !== null,
                xssCount,
                textContent,
                innerHTML,
                findValueLiText: findLi ? findLi.textContent : null
              });
            };
            autocompleter.findValue();
          }
        }, 50);
      });
    });

    if (!test3.hasInjectedNodeInDom &&
        !test3.findValueInjectedInDom &&
        test3.xssCount === 0 &&
        test3.textContent.includes('<script>') &&
        test3.innerHTML.includes('&lt;script&gt;') &&
        test3.findValueLiText &&
        test3.findValueLiText.includes('<script>')) {
      recordPass('Default text fallback uses textContent at BOTH dataToDom and findValueCallback (no raw HTML injection)', test3);
    } else {
      recordFail('Default text fallback uses textContent at BOTH dataToDom and findValueCallback', test3);
    }

    // ------------------------------------------------------------------------
    // Test 4: Public findValue in rows mode with cache hit
    // ------------------------------------------------------------------------
    const t4Start = testResults.routedRequests.length;
    const test4 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('onto-input');
        const autocompleter = input.autocompleter;

        let settled = false;
        let timer = null;

        function cleanup() {
          if (timer) clearTimeout(timer);
          if (autocompleter) autocompleter.getOptions().onFindValue = null;
        }

        // Deadline remains active through both findValue calls
        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 4 timed out waiting for onFindValue'));
        }, 4000);

        autocompleter.flushCache();
        $(input).val('OldCat [obsolete]');

        const opts = autocompleter.getOptions();
        opts.onFindValue = function(li) {
          const firstCallSelectValue = li ? li.selectValue : null;
          const firstCallExtra = li ? li.extra : null;

          // Call findValue a second time for exact same query: must be served from cache!
          opts.onFindValue = function(li2) {
            if (settled) return;
            settled = true;
            cleanup();
            resolve({
              firstCallSelectValue,
              firstCallExtraConceptId: firstCallExtra ? firstCallExtra[0] : null,
              secondCallSelectValue: li2 ? li2.selectValue : null
            });
          };
          autocompleter.findValue();
        };

        autocompleter.findValue();
      });
    });

    const t4Requests = testResults.routedRequests.slice(t4Start).filter(r => r.url.includes('/search/json_search'));
    if (test4.firstCallSelectValue === 'OldCat [obsolete]' &&
        test4.secondCallSelectValue === 'OldCat [obsolete]' &&
        t4Requests.length === 1) { // Exactly 1 network request; 2nd call was cache hit!
      recordPass('Public findValue in rows mode updates cache and serves subsequent identical query without duplicate network request', {
        networkRequests: t4Requests.length,
        firstCallSelectValue: test4.firstCallSelectValue
      });
    } else {
      recordFail('Public findValue in rows mode cache retention', { test4, requestCount: t4Requests.length });
    }

    // ------------------------------------------------------------------------
    // Test 5: Bare/public plugin defaults to legacy (requestData JSONP & findValue text)
    // ------------------------------------------------------------------------
    const t5Start = testResults.routedRequests.length;
    const test5 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        $('div.ac_results').hide();
        const input = document.getElementById('legacy-bare-input');
        $(input).bioportal_autocomplete('http://portal.local/search/legacy_search', {
          lineSeparator: '~!~',
          minChars: 1,
          delay: 10
        });

        const autocompleter = input.autocompleter;
        let settled = false;
        let poll = null;
        let timer = null;

        function cleanup() {
          if (poll) clearInterval(poll);
          if (timer) clearTimeout(timer);
          if (autocompleter) autocompleter.getOptions().onFindValue = null;
        }

        // Deadline remains active through findValue
        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 5 timed out waiting for legacy ac_results and onFindValue'));
        }, 4000);

        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 2) {
            clearInterval(poll);
            poll = null;
            const firstLi = lis.get(0);

            $(input).val('OldCat [obsolete]');
            autocompleter.getOptions().onFindValue = function(findLi) {
              if (settled) return;
              settled = true;
              cleanup();
              resolve({
                optsResponse: autocompleter.getOptions().response,
                requestDataLiCount: lis.length,
                firstSelectValue: firstLi.selectValue,
                firstExtraTargetValue: firstLi.extra ? firstLi.extra[4] : null,
                findValueSelectValue: findLi ? findLi.selectValue : null
              });
            };
            autocompleter.findValue();
          }
        }, 50);
      });
    });

    const t5Requests = testResults.routedRequests.slice(t5Start).filter(r => r.url.includes('/search/legacy_search'));
    const t5JsonpReq = t5Requests.find(r => r.url.includes('response=json') && r.url.includes('callback='));
    const t5FindReq = t5Requests.find(r => !r.url.includes('response=json') && !r.url.includes('callback='));

    if (typeof test5.optsResponse === 'undefined' &&
        t5JsonpReq !== undefined &&
        t5FindReq !== undefined &&
        test5.requestDataLiCount === 2 &&
        test5.firstSelectValue === EXPECTED_LEGACY_LABEL &&
        test5.firstExtraTargetValue === EXPECTED_LEGACY_LABEL &&
        test5.findValueSelectValue === 'OldCat [obsolete]') {
      recordPass('Bare/public plugin defaults to legacy: requestData uses JSONP and findValue uses raw text', {
        optsResponse: test5.optsResponse,
        jsonpReqUrl: t5JsonpReq.url,
        findReqUrl: t5FindReq.url
      });
    } else {
      recordFail('Bare/public plugin legacy defaults', { test5, t5Requests });
    }

    // ------------------------------------------------------------------------
    // Test 6: Cross-origin URL with first-party wrapper retains legacy behavior
    // ------------------------------------------------------------------------
    const t6Start = testResults.routedRequests.length;
    const test6 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        $('div.ac_results').hide();
        const input = document.getElementById('crossorigin-input');
        window.useBioportalAutoComplete(input, 'http://crossorigin.external/search/json_search', {
          lineSeparator: '~!~',
          minChars: 1,
          delay: 10
        });

        const autocompleter = input.autocompleter;
        let settled = false;
        let poll = null;
        let timer = null;

        function cleanup() {
          if (poll) clearInterval(poll);
          if (timer) clearTimeout(timer);
        }

        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 6 timed out waiting for cross-origin ac_results'));
        }, 4000);

        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 2) {
            settled = true;
            cleanup();
            const firstLi = lis.get(0);
            resolve({
              optsResponse: autocompleter.getOptions().response,
              liCount: lis.length,
              firstSelectValue: firstLi.selectValue,
              firstExtraTargetValue: firstLi.extra ? firstLi.extra[4] : null
            });
          }
        }, 50);
      });
    });

    const t6Requests = testResults.routedRequests.slice(t6Start).filter(r => r.url.includes('crossorigin.external'));
    const t6JsonpReq = t6Requests.find(r => r.url.includes('response=json') && r.url.includes('callback='));

    if (typeof test6.optsResponse === 'undefined' &&
        t6JsonpReq !== undefined &&
        test6.liCount === 2 &&
        test6.firstSelectValue === EXPECTED_LEGACY_LABEL &&
        test6.firstExtraTargetValue === EXPECTED_LEGACY_LABEL) {
      recordPass('First-party wrapper retains cross-origin legacy behavior (no rows opt-in, sends JSONP) for external URLs', {
        optsResponse: test6.optsResponse,
        requestUrl: t6JsonpReq.url
      });
    } else {
      recordFail('Cross-origin legacy retention', { test6, t6Requests });
    }

    // ------------------------------------------------------------------------
    // Test 7: Query encoding and parameter identity roundtrip
    // ------------------------------------------------------------------------
    const t7Start = testResults.routedRequests.length;
    const test7 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('query-encoding-input');
        const queryWithSpecialChars = 'C++ & 100% #tag 🌍';
        $(input).val(queryWithSpecialChars);
        $(input).bioportal_autocomplete('http://portal.local/search/json_search#mySection', {
          response: 'rows',
          matchCase: 1,
          extraParams: {
            param_amp: 'A&B',
            param_pct: '50%',
            param_plus: 'X+Y'
          }
        });

        let settled = false;
        let timer = null;

        function cleanup() {
          if (timer) clearTimeout(timer);
          if (input.autocompleter) input.autocompleter.getOptions().onFindValue = null;
        }

        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 7 timed out waiting for onFindValue'));
        }, 4000);

        input.autocompleter.getOptions().onFindValue = function(li) {
          if (settled) return;
          settled = true;
          cleanup();
          resolve({ queryWithSpecialChars });
        };

        input.autocompleter.findValue();
      });
    });

    const t7Requests = testResults.routedRequests.slice(t7Start).filter(r => r.url.includes('/search/json_search'));
    const t7Req = t7Requests[0];
    const t7Parsed = t7Req ? new URL(t7Req.url) : null;

    if (t7Parsed &&
        !t7Req.url.includes('#mySection') && // Hash fragment stripped before query params
        t7Parsed.searchParams.get('q') === 'C++ & 100% #tag 🌍' &&
        t7Parsed.searchParams.get('param_amp') === 'A&B' &&
        t7Parsed.searchParams.get('param_pct') === '50%' &&
        t7Parsed.searchParams.get('param_plus') === 'X+Y') {
      recordPass('Query construction encodes &, +, %, #, spaces, and Unicode correctly, strips hash fragments, and preserves parameter identity', {
        url: t7Req.url,
        decodedQ: t7Parsed.searchParams.get('q'),
        decodedAmp: t7Parsed.searchParams.get('param_amp'),
        decodedPct: t7Parsed.searchParams.get('param_pct'),
        decodedPlus: t7Parsed.searchParams.get('param_plus')
      });
    } else {
      recordFail('Query encoding and parameter identity', { t7Req });
    }

    // ------------------------------------------------------------------------
    // Test 8: Empty Search Results Handling (R2)
    // ------------------------------------------------------------------------
    const test8 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        $('div.ac_results').hide();
        const input = document.getElementById('empty-results-input');
        $(input).bioportal_autocomplete('http://portal.local/search/json_search', {
          response: 'rows',
          minChars: 1,
          delay: 10
        });

        let settled = false;
        let poll = null;
        let timer = null;

        function cleanup() {
          if (poll) clearInterval(poll);
          if (timer) clearTimeout(timer);
        }

        timer = setTimeout(() => {
          if (settled) return;
          settled = true;
          cleanup();
          reject(new Error('Test 8 timed out waiting for empty search no-results display'));
        }, 4000);

        $(input).focus();
        $(input).val('nomatch');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          if (resultsDiv.length > 0 && resultsDiv.text().includes('No results found')) {
            settled = true;
            cleanup();
            resolve({
              dropdownVisible: resultsDiv.is(':visible'),
              dropdownText: resultsDiv.text().trim(),
              hasFocus: document.activeElement === input,
              inputValue: input.value
            });
          }
        }, 50);
      });
    });

    if (test8.dropdownVisible &&
        test8.dropdownText.includes('No results found') &&
        test8.hasFocus &&
        testResults.pageErrors.length === 0) {
      recordPass('Empty search results handle ordinary [] via controlled no-results path with preserved focus and zero errors', test8);
    } else {
      recordFail('Empty search results handling', test8);
    }

    // ------------------------------------------------------------------------
    // Test 9: Request auditing and network containment (R5)
    // ------------------------------------------------------------------------
    const outsideCount = testResults.outsideRequests.length;
    const unexpectedCount = testResults.unexpectedRequests.length;
    const stimErrors = await page.evaluate(() => window.__stimulusErrors || []);
    testResults.stimulusErrors = stimErrors;

    if (testResults.navigationRequests >= 1 &&
        testResults.widgetFixtureRequests > 0 &&
        outsideCount === 0 &&
        unexpectedCount === 0 &&
        testResults.pageErrors.length === 0 &&
        stimErrors.length === 0 &&
        testResults.contextRequests.length === testResults.routedRequests.length) {
      recordPass('Request auditing & network containment: honest fixture request totals recorded, zero unallowed outside requests, zero errors', {
        navigationRequests: testResults.navigationRequests,
        widgetFixtureRequests: testResults.widgetFixtureRequests,
        totalContextRequests: testResults.contextRequests.length,
        outsideRequests: outsideCount,
        unexpectedRequests: unexpectedCount,
        pageErrors: testResults.pageErrors.length,
        stimulusErrors: stimErrors.length
      });
    } else {
      recordFail('Request auditing & network containment', {
        navigationRequests: testResults.navigationRequests,
        widgetFixtureRequests: testResults.widgetFixtureRequests,
        totalContextRequests: testResults.contextRequests.length,
        outsideRequests: testResults.outsideRequests,
        unexpectedRequests: testResults.unexpectedRequests,
        pageErrors: testResults.pageErrors,
        stimErrors
      });
    }

    // Persist request audit artifact
    fs.mkdirSync(path.dirname(AUDIT_OUTPUT_PATH), { recursive: true });
    fs.writeFileSync(AUDIT_OUTPUT_PATH, JSON.stringify({
      navigationRequests: testResults.navigationRequests,
      widgetFixtureRequests: testResults.widgetFixtureRequests,
      totalContextRequests: testResults.contextRequests.length,
      outsideRequests: testResults.outsideRequests,
      unexpectedRequests: testResults.unexpectedRequests,
      pageErrors: testResults.pageErrors,
      stimulusErrors: stimErrors,
      allRequests: testResults.routedRequests
    }, null, 2), 'utf8');

  } catch (err) {
    console.error('Fatal error during wire check:', err);
    recordFail('Wire check fatal error', String(err));
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
  runWireCheck().then((results) => {
    if (results.failed > 0) {
      process.exit(1);
    }
  }).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { runWireCheck };
