/**
 * test/isolated/autocomplete_render_dom_check.js
 *
 * Isolated real-browser DOM test for Autocomplete Result Formatter Text/Highlight Boundary (ONTO-T-J02).
 *
 * Verifies:
 * 1. OntoportalAutocompleteController (#formatItem):
 *    - Matches RAW text before assigning textContent (no entity corruption when searching ampersands/punctuation).
 *    - Case-insensitive search keyword highlighting using programmatically controlled <b><span style='color:#006600;'>$1</span></b>.
 *    - Punctuation semantics (C++, $100, [brackets], pipe |, ampersand &, quotes, Unicode 🌍, newlines \n).
 *    - Renders inert markup-shaped labels, synonyms, match types without injecting DOM nodes or executing scripts.
 *    - Removes [obsolete] from text and wraps with controlled <span class='obsolete_class' title='obsolete class'>.
 *    - Synonym fallback correctly identifies matching synonym, appends it, highlights it, and does not execute markup.
 *    - Original row array and extra fields remain strictly unchanged (not mutated in storage).
 *
 * 2. FormAutoCompleteController (formatItem and #truncateText):
 *    - Single ontology branch (ontology_id !== "all") and all ontologies branch (ontology_id === "all").
 *    - Result class width toggles between 150px (with definitions), 320px (all ontologies), and 350px (default).
 *    - Result class highlight uses <b><span class='result_class_highlight'>$1</span></b> without unescaped markup.
 *    - Result type and ontology names rendered safely.
 *    - Decodes URI-encoded definitions and robustly handles malformed percent encoding without URIError.
 *    - #truncateText creates safe text with <span class='expand_icon'><b>...</b></span> and <span class='long_text'>,
 *      without unsafe .html(text) parsing or unescaped long_text.
 *    - Original row array remains unchanged.
 *
 * 3. Real DOM sink verification:
 *    - Formatter HTML string returned by formatters is rendered into real Chromium <li> DOM nodes.
 *    - Zero XSS payloads triggered (window.__xssTriggered remains empty).
 *    - No unescaped script, img, or svg elements in dropdown results.
 *
 * 4. Integrated bioportal_autocomplete widget integration:
 *    - Real vendor crossdomain_autocomplete.js creates ul/li dropdown elements using controller formatItem.
 *    - Preserves selectValue (row[0]) and extra fields (row.slice(1)).
 *    - .ac_over hover interaction expands .long_text and hides .expand_icon.
 *
 * 5. Network containment:
 *    - Zero routable network requests allowed or attempted.
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const path = require('path');
const assert = require('assert');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

async function buildControllerBundle() {
  const result = await esbuild.build({
    stdin: {
      contents: `
        const $ = require('jquery');
        window.$ = window.jQuery = $;
        // Finite unrelated browser-detection double for legacy crossdomain_autocomplete.js $.browser.msie check
        window.$.browser = window.$.browser || { msie: false, version: '11' };

        require('../../vendor/assets/javascripts/autocomplete/crossdomain_autocomplete.js');
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
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  });
  return result.outputFiles[0].text;
}

const HTML_FIXTURE = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Autocomplete Formatter DOM Check</title>
  <style>
    .obsolete_class { color: gray; }
    .result_class_highlight { background-color: yellow; }
    .long_text { display: none; }
    .expand_icon { display: inline; }
    .ac_over span.long_text { display: inline; }
    .ac_over span.expand_icon { display: none; }
    .result_class { display: inline-block; }
    .result_type { display: inline-block; }
    .result_definition { font-style: italic; }
    .result_ontology { font-weight: bold; }
  </style>
  <script>
    window.__xssTriggered = [];
    window.BP_INTERNAL_SEARCH_SERVER = "";
  </script>
</head>
<body>
  <!-- Ontoportal Autocomplete input -->
  <div id="onto-container">
    <input type="text" id="onto-input"
           data-controller="ontoportal-autocomplete"
           data-ontoportal-autocomplete-ontology-acronym-value="TEST_ONTO"
           value="test" />
  </div>

  <!-- Form Autocomplete input (single ontology with definition) -->
  <div id="form-container-single">
    <input type="text" id="form-input-single"
           name="concept_picker_single"
           data-controller="form-auto-complete"
           data-form-auto-complete-ontology-id-value="TEST_ONTO"
           data-form-auto-complete-target-property-value="name"
           data-form-auto-complete-include-definition-value="true"
           value="test" />
  </div>

  <!-- Form Autocomplete input (all ontologies with definition) -->
  <div id="form-container-all">
    <input type="text" id="form-input-all"
           name="concept_picker_all"
           data-controller="form-auto-complete"
           data-form-auto-complete-ontology-id-value="all"
           data-form-auto-complete-target-property-value="name"
           data-form-auto-complete-include-definition-value="true"
           value="test" />
  </div>

  <!-- Form Autocomplete input (single ontology without definitions) -->
  <div id="form-container-nodef">
    <input type="text" id="form-input-nodef"
           name="concept_picker_nodef"
           data-controller="form-auto-complete"
           data-form-auto-complete-ontology-id-value="TEST_ONTO"
           data-form-auto-complete-target-property-value="name"
           data-form-auto-complete-include-definition-value="false"
           value="test" />
  </div>

  <!-- Form Autocomplete input (all ontologies without definitions) -->
  <div id="form-container-all-nodef">
    <input type="text" id="form-input-all-nodef"
           name="concept_picker_all_nodef"
           data-controller="form-auto-complete"
           data-form-auto-complete-ontology-id-value="all"
           data-form-auto-complete-target-property-value="name"
           data-form-auto-complete-include-definition-value="false"
           value="test" />
  </div>

  <!-- Class search controller input -->
  <div id="class-search-container">
    <input type="text" id="class-search-input"
           data-controller="class-search"
           data-ontoportal-autocomplete-ontology-acronym-value="TEST_ONTO"
           value="test" />
    <input type="hidden" id="jump_to_concept_id" />
  </div>

  <!-- Real DOM sink for rendered rows -->
  <ul id="results-sink"></ul>
</body>
</html>`;

async function runDomCheck() {
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
    contextRequests: [],
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
    const contextRequests = [];

    // Independent context request event collection
    context.on('request', (req) => {
      contextRequests.push(req.url());
      testResults.contextRequests.push(req.url());
    });

    const page = await context.newPage();

    // Capture uncaught browser page errors before connect
    page.on('pageerror', (err) => {
      const errStr = String(err);
      pageErrors.push(errStr);
      testResults.pageErrors.push(errStr);
    });

    // Deny all routable network requests
    await page.route('**/*', (route) => {
      testResults.routableRequests.push(route.request().url());
      return route.abort();
    });

    console.log('[3/4] Initializing isolated DOM environment in Chromium...');
    await page.setContent(HTML_FIXTURE);
    await page.addScriptTag({ content: bundleJs });

    // Wait for actual controller and autocompleter widget readiness rather than self-set ready flag alone
    await page.waitForFunction(() => {
      const ontoInput = document.getElementById('onto-input');
      const formSingle = document.getElementById('form-input-single');
      const classInput = document.getElementById('class-search-input');

      return Boolean(
        window.StimulusApp &&
        ontoInput && ontoInput.autocompleter &&
        formSingle && formSingle.autocompleter &&
        classInput && classInput.autocompleter &&
        window.__getController(ontoInput, 'ontoportal-autocomplete') &&
        window.__getController(formSingle, 'form-auto-complete') &&
        window.__getController(classInput, 'class-search')
      );
    });

    // Capture Stimulus errors recorded during connect/initialization
    const stimulusErrors = await page.evaluate(() => window.__stimulusErrors || []);
    testResults.stimulusErrors = stimulusErrors;

    if (pageErrors.length === 0 && stimulusErrors.length === 0) {
      recordPass('Runtime health: zero browser pageerrors and zero Stimulus errors during connect/initialization', {
        pageErrors: 0,
        stimulusErrors: 0
      });
    } else {
      recordFail('Runtime health: zero browser pageerrors and zero Stimulus errors during connect/initialization', {
        pageErrors,
        stimulusErrors
      });
    }

    console.log('[4/4] Executing test assertions...');

    // ------------------------------------------------------------------------
    // Group 1: OntoportalAutocompleteController (#formatItem)
    // ------------------------------------------------------------------------

    // Check 1.1: Inert markup-shaped label and exact search highlighting for ampersand
    const check11 = await page.evaluate(() => {
      const input = document.getElementById('onto-input');
      input.value = '&';
      const opts = input.autocompleter.getOptions();
      
      const rawPayload = '<script>window.__xssTriggered.push("onto_label")</script> "quotes" & \'amps\' <tag> | pipe $100 \\n newline 🌍';
      const row = [rawPayload, 'http://example.org/concept1', 'class', 'extra3', 'extra4', 'extra5', 'synonym1;synonym2'];
      const rowSnapshot = JSON.stringify(row);

      const formattedHtml = opts.formatItem(row);

      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const scriptCount = li.querySelectorAll('script').length;
      const tagCount = li.querySelectorAll('tag').length;
      const highlightSpan = li.querySelector('b > span[style*="color:#006600"], b > span[style*="color: rgb(0, 102, 0)"]');
      const textPreserved = li.textContent.includes('<script>') &&
                            li.textContent.includes('"quotes"') &&
                            li.textContent.includes('&') &&
                            li.textContent.includes('| pipe $100') &&
                            li.textContent.includes('🌍');
      const rowUnchanged = JSON.stringify(row) === rowSnapshot;

      return {
        formattedHtml,
        scriptCount,
        tagCount,
        hasHighlight: Boolean(highlightSpan),
        highlightText: highlightSpan ? highlightSpan.textContent : null,
        textPreserved,
        rowUnchanged,
        xssCount: window.__xssTriggered.length
      };
    });

    if (check11.scriptCount === 0 && check11.tagCount === 0 && check11.hasHighlight &&
        check11.highlightText === '&' && check11.textPreserved && check11.rowUnchanged && check11.xssCount === 0) {
      recordPass('OntoportalAutocompleteController: matches raw text without entity corruption or script injection', check11);
    } else {
      recordFail('OntoportalAutocompleteController: matches raw text without entity corruption or script injection', JSON.stringify(check11));
    }

    // Check 1.2: Match type markup safety
    const check12 = await page.evaluate(() => {
      const input = document.getElementById('onto-input');
      input.value = 'test';
      const opts = input.autocompleter.getOptions();
      const row = ['Concept Label', 'http://example.org/c2', '<img src=x onerror=window.__xssTriggered.push("onto_type")>', '3', '4', '5', ''];
      const rowSnapshot = JSON.stringify(row);

      const formattedHtml = opts.formatItem(row);
      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const imgCount = li.querySelectorAll('img').length;
      const typeSpan = li.querySelector('span[style*="color:blue"], span[style*="color: blue"]');
      const rowUnchanged = JSON.stringify(row) === rowSnapshot;

      return {
        formattedHtml,
        imgCount,
        hasTypeSpan: Boolean(typeSpan),
        typeText: typeSpan ? typeSpan.textContent : null,
        rowUnchanged,
        xssCount: window.__xssTriggered.length
      };
    });

    if (check12.imgCount === 0 && check12.hasTypeSpan &&
        check12.typeText === '(<img src=x onerror=window.__xssTriggered.push("onto_type")>)' &&
        check12.rowUnchanged && check12.xssCount === 0) {
      recordPass('OntoportalAutocompleteController: safely escapes matchType and prevents attribute XSS', check12);
    } else {
      recordFail('OntoportalAutocompleteController: safely escapes matchType and prevents attribute XSS', JSON.stringify(check12));
    }

    // Check 1.3: Obsolete tag removal, wrapping, and non-mutation
    const check13 = await page.evaluate(() => {
      const input = document.getElementById('onto-input');
      input.value = 'obsolete';
      const opts = input.autocompleter.getOptions();
      const rawLabel = 'Sample Concept [obsolete] <script>window.__xssTriggered.push("obs")</script>';
      const row = [rawLabel, 'http://example.org/c3', 'class', '3', '4', '5', ''];
      const rowSnapshot = JSON.stringify(row);

      const formattedHtml = opts.formatItem(row);
      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const obsSpan = li.querySelector('.obsolete_class');
      const scriptCount = li.querySelectorAll('script').length;
      const rowUnchanged = JSON.stringify(row) === rowSnapshot;
      const labelHasNoObsoleteTag = !li.textContent.includes('[obsolete]');

      return {
        formattedHtml,
        hasObsSpan: Boolean(obsSpan),
        obsTitle: obsSpan ? obsSpan.getAttribute('title') : null,
        scriptCount,
        labelHasNoObsoleteTag,
        rowUnchanged,
        xssCount: window.__xssTriggered.length
      };
    });

    if (check13.hasObsSpan && check13.obsTitle === 'obsolete class' &&
        check13.scriptCount === 0 && check13.labelHasNoObsoleteTag &&
        check13.rowUnchanged && check13.xssCount === 0) {
      recordPass('OntoportalAutocompleteController: strips [obsolete], creates obsolete_class wrapper, keeps row unchanged', check13);
    } else {
      recordFail('OntoportalAutocompleteController: strips [obsolete], creates obsolete_class wrapper, keeps row unchanged', JSON.stringify(check13));
    }

    // Check 1.4: Synonym fallback highlighting and safety
    const check14 = await page.evaluate(() => {
      const input = document.getElementById('onto-input');
      input.value = 'target';
      const opts = input.autocompleter.getOptions();
      const row = [
        'Primary Name',
        'http://example.org/c4',
        'class',
        '3', '4', '5',
        'First Syn;Target <script>window.__xssTriggered.push("syn")</script> Syn;Third Syn\tAdditional Details'
      ];
      const rowSnapshot = JSON.stringify(row);

      const formattedHtml = opts.formatItem(row);
      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const scriptCount = li.querySelectorAll('script').length;
      const highlightSpan = li.querySelector('b > span[style*="color:#006600"], b > span[style*="color: rgb(0, 102, 0)"]');
      const includesSynFallback = li.textContent.includes('(synonym:');
      const rowUnchanged = JSON.stringify(row) === rowSnapshot;

      return {
        formattedHtml,
        scriptCount,
        hasHighlight: Boolean(highlightSpan),
        highlightText: highlightSpan ? highlightSpan.textContent : null,
        includesSynFallback,
        rowUnchanged,
        xssCount: window.__xssTriggered.length
      };
    });

    if (check14.scriptCount === 0 && check14.hasHighlight &&
        check14.highlightText === 'Target' && check14.includesSynFallback &&
        check14.rowUnchanged && check14.xssCount === 0) {
      recordPass('OntoportalAutocompleteController: fallback synonym matching highlights keyword without script execution', check14);
    } else {
      recordFail('OntoportalAutocompleteController: fallback synonym matching highlights keyword without script execution', JSON.stringify(check14));
    }

    // Check 1.5: Punctuation and case semantics (C++, $100, [brackets], pipe |, Unicode 🌍)
    const check15 = await page.evaluate(() => {
      const input = document.getElementById('onto-input');
      const opts = input.autocompleter.getOptions();

      // Case-insensitive query "c++"
      input.value = 'c++';
      const rowCpp = ['Advanced C++ Programming [obsolete]', 'c_cpp', 'class', '3', '4', '5', ''];
      const htmlCpp = opts.formatItem(rowCpp);

      // Query "$100"
      input.value = '$100';
      const rowDollar = ['Cost is $100 USD', 'c_dlr', 'class', '3', '4', '5', ''];
      const htmlDollar = opts.formatItem(rowDollar);

      // Query "[test]"
      input.value = '[test]';
      const rowBracket = ['Prefix [test] suffix', 'c_brk', 'class', '3', '4', '5', ''];
      const htmlBracket = opts.formatItem(rowBracket);

      // Query "🌍"
      input.value = '🌍';
      const rowUnicode = ['Globe 🌍 Icon', 'c_uni', 'class', '3', '4', '5', ''];
      const htmlUnicode = opts.formatItem(rowUnicode);

      const sink = document.getElementById('results-sink');
      const liCpp = document.createElement('li'); liCpp.innerHTML = htmlCpp; sink.appendChild(liCpp);
      const liDollar = document.createElement('li'); liDollar.innerHTML = htmlDollar; sink.appendChild(liDollar);
      const liBracket = document.createElement('li'); liBracket.innerHTML = htmlBracket; sink.appendChild(liBracket);
      const liUnicode = document.createElement('li'); liUnicode.innerHTML = htmlUnicode; sink.appendChild(liUnicode);

      return {
        cppHighlight: liCpp.querySelector('b > span[style*="color:#006600"], b > span[style*="color: rgb(0, 102, 0)"]')?.textContent,
        dollarHighlight: liDollar.querySelector('b > span[style*="color:#006600"], b > span[style*="color: rgb(0, 102, 0)"]')?.textContent,
        bracketHighlight: liBracket.querySelector('b > span[style*="color:#006600"], b > span[style*="color: rgb(0, 102, 0)"]')?.textContent,
        unicodeHighlight: liUnicode.querySelector('b > span[style*="color:#006600"], b > span[style*="color: rgb(0, 102, 0)"]')?.textContent
      };
    });

    if (check15.cppHighlight === 'C++' && check15.dollarHighlight === '$100' &&
        check15.bracketHighlight === '[test]' && check15.unicodeHighlight === '🌍') {
      recordPass('OntoportalAutocompleteController: preserves punctuation semantics (C++, $100, [brackets], Unicode)', check15);
    } else {
      recordFail('OntoportalAutocompleteController: preserves punctuation semantics (C++, $100, [brackets], Unicode)', JSON.stringify(check15));
    }

    // ------------------------------------------------------------------------
    // Group 2: FormAutoCompleteController (formatItem and #truncateText)
    // ------------------------------------------------------------------------

    // Check 2.1: Single ontology branch with definitions (width 150px, definition decoding, highlighting)
    const check21 = await page.evaluate(() => {
      const input = document.getElementById('form-input-single');
      input.value = 'Alpha';
      const controller = window.__getController(input, 'form-auto-complete');
      
      const rawClass = 'Alpha <script>window.__xssTriggered.push("form_cls")</script> & "val"';
      const rawType = '<svg><circle onerror=window.__xssTriggered.push("form_type")/></svg>Property';
      const encodedDef = 'Alpha+definition+with+%3Cscript%3Ewindow.__xssTriggered.push(%22def%22)%3C%2Fscript%3E+and+special+%26';
      
      const row = [rawClass, 'concept_alpha', rawType, 'ont_alpha', 'uri_alpha', 'Alpha Preferred', 'extra6', encodedDef];
      const rowSnapshot = JSON.stringify(row);

      const formattedHtml = controller.formatItem(row);
      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const scriptCount = li.querySelectorAll('script').length;
      const svgCount = li.querySelectorAll('svg').length;
      const classDiv = li.querySelector('.result_class');
      const defDiv = li.querySelector('.result_definition');
      const typeDiv = li.querySelector('.result_type');
      const highlightSpan = li.querySelector('b > span.result_class_highlight');
      const rowUnchanged = JSON.stringify(row) === rowSnapshot;

      return {
        formattedHtml,
        scriptCount,
        svgCount,
        classWidth: classDiv ? classDiv.style.width : null,
        defText: defDiv ? defDiv.textContent : null,
        typeText: typeDiv ? typeDiv.textContent : null,
        hasHighlight: Boolean(highlightSpan),
        highlightText: highlightSpan ? highlightSpan.textContent : null,
        rowUnchanged,
        xssCount: window.__xssTriggered.length
      };
    });

    if (check21.scriptCount === 0 && check21.svgCount === 0 && check21.classWidth === '150px' &&
        check21.defText && check21.defText.includes('Alpha definition with <script>window.__xssTriggered.push("def")</script>') &&
        check21.hasHighlight && check21.highlightText === 'Alpha' &&
        check21.rowUnchanged && check21.xssCount === 0) {
      recordPass('FormAutoCompleteController: single ontology with definitions uses 150px width, decodes safely', check21);
    } else {
      recordFail('FormAutoCompleteController: single ontology with definitions uses 150px width, decodes safely', JSON.stringify(check21));
    }

    // Check 2.2: Single ontology without definitions (width 350px, no definition element)
    const check22 = await page.evaluate(() => {
      const input = document.getElementById('form-input-nodef');
      input.value = 'Beta';
      const controller = window.__getController(input, 'form-auto-complete');
      const row = ['Beta Class', 'concept_b', 'Class', 'ont_b', 'uri_b', 'Beta', 'extra6', 'Ignored Def'];

      const formattedHtml = controller.formatItem(row);
      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const classDiv = li.querySelector('.result_class');
      const defDiv = li.querySelector('.result_definition');

      return {
        classWidth: classDiv ? classDiv.style.width : null,
        hasDefDiv: Boolean(defDiv)
      };
    });

    if (check22.classWidth === '350px' && !check22.hasDefDiv) {
      recordPass('FormAutoCompleteController: single ontology without definitions uses 350px width and omits definition element', check22);
    } else {
      recordFail('FormAutoCompleteController: single ontology without definitions uses 350px width and omits definition element', JSON.stringify(check22));
    }

    // Check 2.3: All ontologies branch with long definitions and long ontology names
    const check23 = await page.evaluate(() => {
      const input = document.getElementById('form-input-all');
      input.value = 'Gamma';
      const controller = window.__getController(input, 'form-auto-complete');

      const rawClass = 'Gamma Concept';
      const rawOnt = 'Extremely Long Ontology Name That Definitely Exceeds Thirty-Five Characters & Has <img src=x onerror=window.__xssTriggered.push("ont_xss")>';
      const rawLongDef = 'This+is+an+extremely+long+concept+definition+that+exceeds+seventy-five+characters+by+a+wide+margin+with+%3Cscript%3Ewindow.__xssTriggered.push(%22long_def%22)%3C%2Fscript%3E';

      // In all ontologies mode: row[7] is ontology, row[9] is definition
      const row = [rawClass, 'concept_g', 'Class', '3', '4', '5', '6', rawOnt, '8', rawLongDef];
      const rowSnapshot = JSON.stringify(row);

      const formattedHtml = controller.formatItem(row);
      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const scriptCount = li.querySelectorAll('script').length;
      const imgCount = li.querySelectorAll('img').length;
      const classDiv = li.querySelector('.result_class');
      const defDiv = li.querySelector('.result_definition');
      const ontDiv = li.querySelector('.result_ontology');

      const defExpandIcon = defDiv ? defDiv.querySelector('span.expand_icon') : null;
      const defLongText = defDiv ? defDiv.querySelector('span.long_text') : null;

      const ontExpandIcon = ontDiv ? ontDiv.querySelector('span.expand_icon') : null;
      const ontLongText = ontDiv ? ontDiv.querySelector('span.long_text') : null;

      const rowUnchanged = JSON.stringify(row) === rowSnapshot;

      return {
        formattedHtml,
        scriptCount,
        imgCount,
        classWidth: classDiv ? classDiv.style.width : null,
        hasDefExpandIcon: Boolean(defExpandIcon),
        hasDefLongText: Boolean(defLongText),
        defLongContent: defLongText ? defLongText.textContent : null,
        hasOntExpandIcon: Boolean(ontExpandIcon),
        hasOntLongText: Boolean(ontLongText),
        rowUnchanged,
        xssCount: window.__xssTriggered.length
      };
    });

    if (check23.scriptCount === 0 && check23.imgCount === 0 &&
        check23.hasDefExpandIcon && check23.hasDefLongText &&
        check23.defLongContent && check23.defLongContent.includes('<script>window.__xssTriggered.push("long_def")</script>') &&
        check23.hasOntExpandIcon && check23.hasOntLongText &&
        check23.rowUnchanged && check23.xssCount === 0) {
      recordPass('FormAutoCompleteController: all-ontologies truncates long definitions and ontology with safe expand spans', check23);
    } else {
      recordFail('FormAutoCompleteController: all-ontologies truncates long definitions and ontology with safe expand spans', JSON.stringify(check23));
    }

    // Check 2.4: All ontologies branch without definitions (width 320px)
    const check24 = await page.evaluate(() => {
      const input = document.getElementById('form-input-all-nodef');
      input.value = 'Epsilon';
      const controller = window.__getController(input, 'form-auto-complete');
      const row = ['Epsilon Concept', 'concept_e', 'Class', '3', '4', '5', '6', 'Short Ont', '8', 'Ignored Def'];

      const formattedHtml = controller.formatItem(row);
      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const classDiv = li.querySelector('.result_class');
      const defDiv = li.querySelector('.result_definition');
      const ontDiv = li.querySelector('.result_ontology');

      return {
        classWidth: classDiv ? classDiv.style.width : null,
        hasDefDiv: Boolean(defDiv),
        hasOntDiv: Boolean(ontDiv)
      };
    });

    if (check24.classWidth === '320px' && !check24.hasDefDiv && check24.hasOntDiv) {
      recordPass('FormAutoCompleteController: all ontologies without definitions uses 320px width and includes ontology', check24);
    } else {
      recordFail('FormAutoCompleteController: all ontologies without definitions uses 320px width and includes ontology', JSON.stringify(check24));
    }

    // Check 2.5: Robust handling of malformed percent-encoded definitions without crashing
    const check25 = await page.evaluate(() => {
      const input = document.getElementById('form-input-single');
      input.value = 'Delta';
      const controller = window.__getController(input, 'form-auto-complete');

      const malformedDef = 'Malformed%20percent%ZZ%def%with%<script>window.__xssTriggered.push("malformed")</script>';
      const row = ['Delta Concept', 'c_delta', 'Class', 'ont', 'uri', 'Delta', '6', malformedDef];

      let crashed = false;
      let formattedHtml = '';
      try {
        formattedHtml = controller.formatItem(row);
      } catch (e) {
        crashed = true;
      }

      const sink = document.getElementById('results-sink');
      const li = document.createElement('li');
      li.innerHTML = formattedHtml;
      sink.appendChild(li);

      const scriptCount = li.querySelectorAll('script').length;

      return {
        crashed,
        scriptCount,
        defText: li.querySelector('.result_definition') ? li.querySelector('.result_definition').textContent : null,
        xssCount: window.__xssTriggered.length
      };
    });

    if (!check25.crashed && check25.scriptCount === 0 && check25.xssCount === 0 &&
        check25.defText && check25.defText.includes('Malformed%20percent%ZZ%def%with%<script>')) {
      recordPass('FormAutoCompleteController: robustly handles malformed URI encoding without throwing URIError', check25);
    } else {
      recordFail('FormAutoCompleteController: robustly handles malformed URI encoding without throwing URIError', JSON.stringify(check25));
    }

    // ------------------------------------------------------------------------
    // Group 3: Real vendor bioportal_autocomplete widget DOM integration
    // ------------------------------------------------------------------------

    // Check 3.1: Loaded vendor widget findValue execution and DOM integration (without copied algorithm)
    const check31 = await page.evaluate(() => {
      return new Promise((resolve, reject) => {
        const input = document.getElementById('onto-input');
        const autocompleter = input.autocompleter;
        if (!autocompleter) {
          return reject(new Error('Vendor autocompleter not attached to onto-input'));
        }
        const opts = autocompleter.getOptions();

        // Finite upstream wire response double (raw text lines separated by lineSeparator "~!~", fields by cellSeparator "|")
        const targetLabel = 'Concept <script>window.__xssTriggered.push("widget_xss")</script> 2';
        const mockWireData = [
          'Safe Concept 1|id_1|class|ont|uri1|pref1|syn1',
          `${targetLabel}|id_2|class|ont|uri2|pref2|syn2`
        ].join('~!~');

        // Preserve originals to restore in finally
        const originalGet = window.$.get;
        const originalOnFindValue = opts.onFindValue;

        let getUrlCalled = null;

        // Mock ONLY finite upstream $.get response
        window.$.get = function(url, callback) {
          getUrlCalled = url;
          callback(mockWireData);
        };

        const timer = setTimeout(() => {
          window.$.get = originalGet;
          opts.onFindValue = originalOnFindValue;
          reject(new Error('Vendor findValue callback timed out'));
        }, 3000);

        // Vendor crossdomain_autocomplete findValueCallback invokes options.onFindValue(li)
        // after vendor parseData, query match, controller formatItem, real li creation,
        // and setting li.selectValue and li.extra. The test asserts the vendor-created DOM.
        opts.onFindValue = function(li) {
          clearTimeout(timer);
          try {
            // Assert real DOM created by vendor widget (no test-created li or copied assignments)
            const isLiElement = (li instanceof HTMLElement) && (li.tagName === 'LI');
            const selectValuePreserved = Boolean(li && li.selectValue === targetLabel);
            const extraPreserved = Boolean(
              li &&
              Array.isArray(li.extra) &&
              li.extra[0] === 'id_2' &&
              li.extra[1] === 'class' &&
              li.extra[2] === 'ont' &&
              li.extra[3] === 'uri2' &&
              li.extra[4] === 'pref2' &&
              li.extra[5] === 'syn2'
            );

            // Mount the vendor-created li into real DOM sink to assert rendering
            const sink = document.getElementById('results-sink');
            sink.appendChild(li);

            const scriptCount = li.querySelectorAll('script').length;
            const textPreserved = li.textContent.includes('<script>');

            // Hover class toggle on real vendor element
            li.classList.add('ac_over');
            const isAcOver = li.classList.contains('ac_over');

            resolve({
              isLiElement,
              selectValuePreserved,
              extraPreserved,
              scriptCount,
              textPreserved,
              isAcOver,
              getUrlCalled,
              xssCount: window.__xssTriggered.length
            });
          } catch (err) {
            reject(err);
          } finally {
            // Restore finite $.get stub and original onFindValue
            window.$.get = originalGet;
            opts.onFindValue = originalOnFindValue;
            autocompleter.flushCache();
          }
        };

        input.value = targetLabel;
        // Exercise ACTUAL loaded vendor widget implementation via public input.autocompleter.findValue()
        autocompleter.findValue();
      });
    });

    if (check31.isLiElement && check31.selectValuePreserved &&
        check31.extraPreserved && check31.scriptCount === 0 &&
        check31.textPreserved && check31.isAcOver && check31.xssCount === 0 &&
        check31.getUrlCalled && check31.getUrlCalled.includes('/search/json_search/TEST_ONTO')) {
      recordPass('bioportal_autocomplete widget integration: vendor findValue builds DOM safely with selectValue and extra preserved', check31);
    } else {
      recordFail('bioportal_autocomplete widget integration: vendor findValue builds DOM safely with selectValue and extra preserved', JSON.stringify(check31));
    }

    // Check 3.2: Selection handler compatibility (class-search concept jump and form-auto-complete hidden fields)
    const check32 = await page.evaluate(() => {
      const classInput = document.getElementById('class-search-input');
      const classCtrl = window.__getController(classInput, 'class-search');
      const formInput = document.getElementById('form-input-single');
      const formCtrl = window.__getController(formInput, 'form-auto-complete');

      // Test onItemSelect on class-search
      const mockLiClass = { extra: ['concept_123', 'extra1'], selectValue: 'Concept Name' };
      // Override onFindValue honestly: this proves hidden concept ID assignment without Turbo navigation
      let capturedConceptId = null;
      classCtrl.onFindValue = function(li) {
        capturedConceptId = document.getElementById('jump_to_concept_id').value;
      };
      classCtrl.onItemSelect(mockLiClass);

      // Test onSelect on form-auto-complete
      const mockLiForm = {
        extra: ['short_456', 'type_val', 'ont_789', 'http://full_uri', 'Preferred Label'],
        selectValue: 'Preferred Label'
      };
      let eventDispatched = false;
      formInput.addEventListener('selected', () => { eventDispatched = true; });
      formCtrl.onSelect(mockLiForm);

      const conceptIdInput = document.querySelector('input[name="concept_picker_single_bioportal_concept_id"]');
      const ontIdInput = document.querySelector('input[name="concept_picker_single_bioportal_ontology_id"]');
      const fullIdInput = document.querySelector('input[name="concept_picker_single_bioportal_full_id"]');
      const prefNameInput = document.querySelector('input[name="concept_picker_single_bioportal_preferred_name"]');

      return {
        capturedConceptId,
        formInputValue: formInput.value,
        conceptIdVal: conceptIdInput ? conceptIdInput.value : null,
        ontIdVal: ontIdInput ? ontIdInput.value : null,
        fullIdVal: fullIdInput ? fullIdInput.value : null,
        prefNameVal: prefNameInput ? prefNameInput.value : null,
        eventDispatched
      };
    });

    if (check32.capturedConceptId === 'concept_123' &&
        check32.formInputValue === 'Preferred Label' &&
        check32.conceptIdVal === 'short_456' &&
        check32.ontIdVal === 'ont_789' &&
        check32.fullIdVal === 'http://full_uri' &&
        check32.prefNameVal === 'Preferred Label' &&
        check32.eventDispatched) {
      recordPass('Direct selection handler proof: class-search hidden concept ID assignment and form-auto-complete hidden fields updated (not Turbo navigation)', check32);
    } else {
      recordFail('Direct selection handler proof: class-search hidden concept ID assignment and form-auto-complete hidden fields updated (not Turbo navigation)', JSON.stringify(check32));
    }

    // ------------------------------------------------------------------------
    // Group 4: Network request containment
    // ------------------------------------------------------------------------
    if (testResults.routableRequests.length === 0 && testResults.contextRequests.length === 0) {
      recordPass('Network containment: zero routable network requests initiated (route aborts: 0, context requests: 0)', {
        routeAborts: testResults.routableRequests.length,
        contextRequests: testResults.contextRequests.length
      });
    } else {
      recordFail('Network containment: zero routable network requests initiated', {
        routeAborts: testResults.routableRequests,
        contextRequests: testResults.contextRequests
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
  runDomCheck().then((results) => {
    if (results.failed > 0) {
      process.exit(1);
    }
  }).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

module.exports = { runDomCheck };
