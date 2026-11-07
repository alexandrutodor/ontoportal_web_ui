/**
 * test/isolated/autocomplete_wire_dom_check.js
 *
 * Isolated real-browser DOM test for Autocomplete Producer/Adapter Wire Protocol (ONTO-T-J02).
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const path = require('path');
const assert = require('assert');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

// Actual native producer outputs produced by SearchController#json_search ActionDispatch
const NATIVE_PRODUCER_OUTPUTS = {
  rows_single: {
    status: 200,
    contentType: 'application/json; charset=utf-8',
    body: JSON.stringify([
      [
        'Complex | "Cat" \\ \n 🌍 ~!~',
        'http://example.org/test#Complex\\Cat"1"',
        '',
        'TEST',
        'http://example.org/test#Complex\\Cat"1"',
        'Complex | "Cat" \\ \n 🌍 ~!~',
        'Syn | 1;Syn "2"',
        'Def+%7C+1.+Def+~%21~+2'
      ],
      [
        'OldCat [obsolete]',
        'http://example.org/test#OldCat',
        '',
        'TEST',
        'http://example.org/test#OldCat',
        'OldCat',
        'OldSyn',
        'OldDef'
      ]
    ])
  },
  rows_all: {
    status: 200,
    contentType: 'application/json; charset=utf-8',
    body: JSON.stringify([
      [
        'Complex | "Cat" \\ \n 🌍 ~!~',
        'http://example.org/test#Complex\\Cat"1"',
        '',
        'TEST',
        'http://example.org/test#Complex\\Cat"1"',
        'Complex | "Cat" \\ \n 🌍 ~!~',
        'Syn | 1;Syn "2"',
        'TEST',
        'TEST',
        'Def+%7C+1.+Def+~%21~+2'
      ],
      [
        'OldCat [obsolete]',
        'http://example.org/test#OldCat',
        '',
        'TEST',
        'http://example.org/test#OldCat',
        'OldCat',
        'OldSyn',
        'TEST',
        'TEST',
        'OldDef'
      ]
    ])
  },
  rows_xss_probe: {
    status: 200,
    contentType: 'application/json; charset=utf-8',
    body: JSON.stringify([
      [
        '<script>window.__xssTriggered.push("probe_fail")</script><b id="injected_dom">Injected</b>',
        'http://example.org/test#XSS',
        '',
        'TEST',
        'http://example.org/test#XSS',
        'Injected Target',
        'SynXSS',
        'TEST',
        'TEST',
        'DefXSS'
      ]
    ])
  },
  legacy_text: {
    status: 200,
    contentType: 'text/html; charset=utf-8',
    body: 'Cat Concept|http://example.org/test#Cat||TEST|http://example.org/test#Cat|Cat Concept|Syn1;Syn2|TEST|TEST|Def~!~OldCat [obsolete]|http://example.org/test#OldCat||TEST|http://example.org/test#OldCat|OldCat|OldSyn|TEST|TEST|OldDef~!~'
  },
  legacy_jsonp_template: 'Cat Concept|http://example.org/test#Cat||TEST|http://example.org/test#Cat|Cat Concept|Syn1;Syn2|TEST|TEST|Def~!~OldCat [obsolete]|http://example.org/test#OldCat||TEST|http://example.org/test#OldCat|OldCat|OldSyn|TEST|TEST|OldDef~!~'
};

async function buildControllerBundle() {
  const result = await esbuild.build({
    stdin: {
      contents: `
        const $ = require('jquery');
        window.$ = window.jQuery = $;
        // Finite unrelated browser-detection double for legacy crossdomain_autocomplete.js $.browser.msie check
        window.$.browser = window.$.browser || { msie: false, version: '11' };

        require('../../vendor/assets/javascripts/autocomplete/crossdomain_autocomplete.js');
        const { useBioportalAutoComplete } = require('../../app/javascript/mixins/useBioportalAutoComplete.js');
        window.useBioportalAutoComplete = useBioportalAutoComplete;

        const { Application } = require('@hotwired/stimulus');
        const OntoportalAutocompleteController = require('../../app/javascript/controllers/ontoportal_autocomplete_controller.js').default;
        const FormAutoCompleteController = require('../../app/javascript/controllers/form_auto_complete_controller.js').default;
        const ClassSearchAutoCompleteController = require('../../app/javascript/controllers/class_search_auto_complete_controller.js').default;

        window.__stimulusErrors = [];
        window.StimulusApp = Application.start();
        window.StimulusApp.handleError = function(error, message, detail) {
          window.__stimulusErrors.push({ error: String(error), message, detail });
        };

        window.StimulusApp.register('ontoportal-autocomplete', OntoportalAutocompleteController);
        window.StimulusApp.register('form-auto-complete', FormAutoCompleteController);
        window.StimulusApp.register('class-search', ClassSearchAutoCompleteController);

        window.__getController = function(element, identifier) {
          return window.StimulusApp.getControllerForElementAndIdentifier(element, identifier);
        };
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true,
    format: 'iife',
    write: false,
    nodePaths: [
      path.resolve(ROOT_DIR, 'node_modules'),
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
  <title>Autocomplete Wire Protocol DOM Check</title>
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
</body>
</html>`;

async function runWireCheck() {
  const testResults = {
    total: 0,
    passed: 0,
    failed: 0,
    checks: [],
    requests: [],
    outsideRequests: [],
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
      console.error('[Browser PageError]', err);
      testResults.pageErrors.push(String(err));
    });

    const ALLOWED_SYNTHETIC_ORIGINS = [
      'http://portal.local',
      'http://crossorigin.external'
    ];

    // Request interception and strict network auditing
    await page.route('**/*', (route) => {
      const req = route.request();
      const urlStr = req.url();
      const method = req.method();
      const resourceType = req.resourceType();

      testResults.requests.push({
        url: urlStr,
        method,
        resourceType,
        time: Date.now()
      });

      // Allow HTML fixture root
      if (urlStr === 'http://portal.local/') {
        return route.fulfill({
          status: 200,
          contentType: 'text/html; charset=utf-8',
          body: HTML_FIXTURE
        });
      }

      // Check allowed synthetic fixture endpoints
      let allowed = false;
      for (const origin of ALLOWED_SYNTHETIC_ORIGINS) {
        if (urlStr.startsWith(origin)) {
          allowed = true;
          break;
        }
      }

      if (!allowed) {
        testResults.outsideRequests.push(urlStr);
        return route.abort('blockedbyclient');
      }

      const parsedUrl = new URL(urlStr);
      const pathname = parsedUrl.pathname;
      const searchParams = parsedUrl.searchParams;
      const responseMode = searchParams.get('response');
      const callbackName = searchParams.get('callback');

      // JSONP requests for either endpoint
      if (responseMode === 'json' && callbackName) {
        const body = `${callbackName}({data:${JSON.stringify(NATIVE_PRODUCER_OUTPUTS.legacy_jsonp_template)}});`;
        return route.fulfill({
          status: 200,
          contentType: 'application/javascript; charset=utf-8',
          body
        });
      }

      // Same-origin search endpoint (/search/json_search)
      if (pathname.startsWith('/search/json_search')) {
        const query = searchParams.get('q') || '';
        const ontologyId = searchParams.get('id');

        if (query.includes('probe')) {
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_xss_probe);
        }

        if (responseMode === 'rows') {
          if (ontologyId === 'TEST' && !pathname.endsWith('/all')) {
            return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_single);
          }
          return route.fulfill(NATIVE_PRODUCER_OUTPUTS.rows_all);
        }

        return route.fulfill(NATIVE_PRODUCER_OUTPUTS.legacy_text);
      }

      // Legacy search endpoint (/search/legacy_search)
      if (pathname === '/search/legacy_search') {
        return route.fulfill(NATIVE_PRODUCER_OUTPUTS.legacy_text);
      }

      return route.fulfill({ status: 404, body: 'Not found' });
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
    const initialReqCount = testResults.requests.length;
    const test1 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('onto-input');
        const autocompleter = input.autocompleter;
        const opts = autocompleter.getOptions();

        const timer = setTimeout(() => {
          reject(new Error('Test 1 timed out waiting for ac_results dropdown'));
        }, 4000);

        opts.onItemSelect = function(li) {};

        // Focus input to set hasFocus = true for results dropdown display
        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65; // 'A'
        $(input).trigger(keyEvt);

        // Wait for results dropdown to be populated
        const poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 2) {
            clearInterval(poll);
            clearTimeout(timer);

            const firstLi = lis.get(0);
            const secondLi = lis.get(1);

            // Obsolete class detection
            const secondHasObsolete = secondLi.querySelector('.obsolete_class') !== null;
            const secondText = secondLi.textContent;

            // Extra mapping verification
            const firstExtra = firstLi.extra;
            const firstSelectValue = firstLi.selectValue;

            // Listen for autocomplete_selected event
            let eventFired = false;
            $(document).one('autocomplete_selected', () => {
              eventFired = true;
              resolve({
                optsResponse: opts.response,
                liCount: lis.length,
                firstSelectValue,
                firstExtraCount: firstExtra ? firstExtra.length : 0,
                firstExtraConceptId: firstExtra ? firstExtra[0] : null,
                firstExtraAcronym: firstExtra ? firstExtra[2] : null,
                secondHasObsolete,
                secondText,
                inputValueAfterSelect: input.value,
                eventFired: true
              });
            });

            // Simulate selection click
            $(firstLi).trigger('click');
          }
        }, 50);
      });
    });

    // Check captured request for Test 1
    const t1Request = testResults.requests.slice(initialReqCount).find(r => r.url.includes('/search/json_search'));
    const t1Url = t1Request ? new URL(t1Request.url) : null;
    const t1ResponseParam = t1Url ? t1Url.searchParams.get('response') : null;
    const t1CallbackParam = t1Url ? t1Url.searchParams.get('callback') : null;

    if (test1.optsResponse === 'rows' &&
        t1ResponseParam === 'rows' &&
        t1CallbackParam === null &&
        test1.liCount === 2 &&
        test1.firstSelectValue === 'Complex | "Cat" \\ \n 🌍 ~!~' &&
        test1.firstExtraConceptId === 'http://example.org/test#Complex\\Cat"1"' &&
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
    const t2Start = testResults.requests.length;
    const test2 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('form-single-input');
        const autocompleter = input.autocompleter;
        const opts = autocompleter.getOptions();

        autocompleter.flushCache();
        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        const timer = setTimeout(() => {
          reject(new Error('Test 2 timed out waiting for single ontology ac_results'));
        }, 4000);

        const poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 1) {
            clearInterval(poll);
            clearTimeout(timer);
            const li = lis.get(0);
            resolve({
              optsResponse: opts.response,
              liCount: lis.length,
              selectValue: li.selectValue,
              extraLength: li.extra ? li.extra.length : 0,
              conceptId: li.extra ? li.extra[0] : null,
              encodedDefinition: li.extra ? li.extra[6] : null
            });
          }
        }, 50);
      });
    });

    const t2Request = testResults.requests.slice(t2Start).find(r => r.url.includes('/search/json_search'));
    const t2Url = t2Request ? new URL(t2Request.url) : null;

    if (t2Url && t2Url.searchParams.get('response') === 'rows' &&
        test2.extraLength === 7 && // 8 columns total: selectValue (col 0) + 7 extra fields
        test2.conceptId === 'http://example.org/test#Complex\\Cat"1"' &&
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
        // Initialize bare plugin without formatItem option, requesting probe rows
        $(input).bioportal_autocomplete('/search/json_search', {
          response: 'rows',
          minChars: 1,
          delay: 10
        });

        const autocompleter = input.autocompleter;
        $(input).focus();
        $(input).val('probe');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        const timer = setTimeout(() => {
          reject(new Error('Test 3 timed out waiting for probe ac_results'));
        }, 4000);

        const poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 1) {
            clearInterval(poll);
            clearTimeout(timer);
            const li = lis.get(0);

            // Verify no injected elements created inside li
            const injectedNode = document.getElementById('injected_dom');
            const xssCount = window.__xssTriggered.length;
            const textContent = li.textContent;
            const innerHTML = li.innerHTML;

            // Also verify findValue with no formatter uses textContent
            let findValueLiText = null;
            let findValueInjected = null;
            $(input).val('<script>window.__xssTriggered.push("probe_fail")</script><b id="injected_dom">Injected</b>');
            autocompleter.getOptions().onFindValue = function(findLi) {
              findValueLiText = findLi ? findLi.textContent : null;
              findValueInjected = document.getElementById('injected_dom');

              resolve({
                hasInjectedNodeInDom: injectedNode !== null,
                findValueInjectedInDom: findValueInjected !== null,
                xssCount,
                textContent,
                innerHTML,
                findValueLiText
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
    const t4Start = testResults.requests.length;
    const test4 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('onto-input');
        const autocompleter = input.autocompleter;

        autocompleter.flushCache();
        $(input).val('OldCat [obsolete]');

        const timer = setTimeout(() => {
          reject(new Error('Test 4 timed out waiting for onFindValue'));
        }, 4000);

        const opts = autocompleter.getOptions();
        opts.onFindValue = function(li) {
          const firstCallSelectValue = li ? li.selectValue : null;
          const firstCallExtra = li ? li.extra : null;

          // Call findValue a second time for exact same query: must be served from cache!
          opts.onFindValue = function(li2) {
            clearTimeout(timer);
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

    const t4Requests = testResults.requests.slice(t4Start).filter(r => r.url.includes('/search/json_search'));
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
    const t5Start = testResults.requests.length;
    const test5 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        $('div.ac_results').hide();
        const input = document.getElementById('legacy-bare-input');
        // Initialize bare plugin without response option
        $(input).bioportal_autocomplete('http://portal.local/search/legacy_search', {
          lineSeparator: '~!~',
          minChars: 1,
          delay: 10
        });

        const autocompleter = input.autocompleter;
        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        const timer = setTimeout(() => {
          reject(new Error('Test 5 timed out waiting for legacy ac_results'));
        }, 4000);

        const poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 2) {
            clearInterval(poll);
            clearTimeout(timer);
            const firstLi = lis.get(0);

            // Test findValue in legacy mode
            $(input).val('OldCat [obsolete]');
            const findTimer = setTimeout(() => {
              reject(new Error('Test 5 timed out waiting for legacy findValue onFindValue'));
            }, 4000);

            autocompleter.getOptions().onFindValue = function(findLi) {
              clearTimeout(findTimer);
              resolve({
                optsResponse: autocompleter.getOptions().response,
                requestDataLiCount: lis.length,
                firstSelectValue: firstLi.selectValue,
                findValueSelectValue: findLi ? findLi.selectValue : null
              });
            };
            autocompleter.findValue();
          }
        }, 50);
      });
    });

    const t5Requests = testResults.requests.slice(t5Start).filter(r => r.url.includes('/search/legacy_search'));
    const t5JsonpReq = t5Requests.find(r => r.url.includes('response=json') && r.url.includes('callback='));
    const t5FindReq = t5Requests.find(r => !r.url.includes('response=json') && !r.url.includes('callback='));

    if (typeof test5.optsResponse === 'undefined' &&
        t5JsonpReq !== undefined &&
        t5FindReq !== undefined &&
        test5.requestDataLiCount === 2 &&
        test5.firstSelectValue === 'Cat Concept' &&
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
    const t6Start = testResults.requests.length;
    const test6 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        $('div.ac_results').hide();
        const input = document.getElementById('crossorigin-input');
        // useBioportalAutoComplete with external origin
        window.useBioportalAutoComplete(input, 'http://crossorigin.external/search/json_search', {
          lineSeparator: '~!~',
          minChars: 1,
          delay: 10
        });

        const autocompleter = input.autocompleter;
        $(input).focus();
        $(input).val('cat');
        const keyEvt = $.Event('keydown');
        keyEvt.keyCode = 65;
        $(input).trigger(keyEvt);

        const timer = setTimeout(() => {
          reject(new Error('Test 6 timed out waiting for cross-origin ac_results'));
        }, 4000);

        const poll = setInterval(() => {
          const resultsDiv = $('div.ac_results:visible');
          const lis = resultsDiv.find('li');
          if (lis.length >= 2) {
            clearInterval(poll);
            clearTimeout(timer);
            resolve({
              optsResponse: autocompleter.getOptions().response,
              liCount: lis.length,
              firstSelectValue: lis.get(0).selectValue
            });
          }
        }, 50);
      });
    });

    const t6Requests = testResults.requests.slice(t6Start).filter(r => r.url.includes('crossorigin.external'));
    const t6JsonpReq = t6Requests.find(r => r.url.includes('response=json') && r.url.includes('callback='));

    if (typeof test6.optsResponse === 'undefined' &&
        t6JsonpReq !== undefined &&
        test6.liCount === 2 &&
        test6.firstSelectValue === 'Cat Concept') {
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
    const t7Start = testResults.requests.length;
    const test7 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('query-encoding-input');
        const queryWithSpecialChars = 'C++ & 100% #tag 🌍';
        $(input).val(queryWithSpecialChars);
        // URL containing hash fragment and extra params
        $(input).bioportal_autocomplete('http://portal.local/search/json_search#mySection', {
          response: 'rows',
          matchCase: 1,
          extraParams: {
            param_amp: 'A&B',
            param_pct: '50%',
            param_plus: 'X+Y'
          }
        });

        const timer = setTimeout(() => {
          reject(new Error('Test 7 timed out waiting for onFindValue'));
        }, 4000);

        input.autocompleter.getOptions().onFindValue = function(li) {
          clearTimeout(timer);
          resolve({ queryWithSpecialChars });
        };

        input.autocompleter.findValue();
      });
    });

    const t7Requests = testResults.requests.slice(t7Start).filter(r => r.url.includes('/search/json_search'));
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
    // Test 8: Request auditing and network containment
    // ------------------------------------------------------------------------
    const totalRequests = testResults.requests.length;
    const outsideCount = testResults.outsideRequests.length;
    const stimErrors = await page.evaluate(() => window.__stimulusErrors || []);

    if (totalRequests > 0 && outsideCount === 0 && testResults.pageErrors.length === 0 && stimErrors.length === 0) {
      recordPass('Request auditing & network containment: honest fixture request totals recorded, zero unallowed outside requests, zero errors', {
        totalFixtureRequests: totalRequests,
        outsideRequests: outsideCount,
        pageErrors: testResults.pageErrors.length,
        stimulusErrors: stimErrors.length
      });
    } else {
      recordFail('Request auditing & network containment', {
        totalRequests,
        outsideCount,
        outsideRequests: testResults.outsideRequests,
        pageErrors: testResults.pageErrors,
        stimErrors
      });
    }

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
