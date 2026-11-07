/**
 * test/isolated/search_input_dom_check.js
 * 
 * Isolated real-browser DOM test for SearchInputComponentController (ONTO-T-J02).
 * Verifies safe text/DOM/URL binding using installed Chromium/Google Chrome via Playwright.
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
        import { Application } from "@hotwired/stimulus";
        import SearchInputComponentController from "./app/components/search_input_component/search_input_component_controller.js";
        
        window.StimulusApp = Application.start();
        window.StimulusApp.register("search-input", SearchInputComponentController);
        window.__searchControllerReady = true;
      `,
      resolveDir: ROOT_DIR
    },
    bundle: true,
    format: 'iife',
    write: false,
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules'],
    external: ['jQuery']
  });
  return result.outputFiles[0].text;
}

const HTML_FIXTURE = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>SearchInput Isolated DOM Check</title>
  <style>
    .d-none { display: none !important; }
    .search-content { display: flex; }
  </style>
  <script>
    window.__xssTriggered = [];
    window.__mockAjaxResponse = null;
    window.jQuery = {
      ajax: function(options) {
        if (window.__mockAjaxResponse) {
          options.success(window.__mockAjaxResponse);
        } else {
          options.error();
        }
      }
    };
  </script>
</head>
<body>
  <!-- Container 1: Cached items with Anchor template -->
  <div id="search-container-cached" class="search-inputs"
       data-controller="search-input"
       data-search-input-search-endpoint-value="/search?scope=all#top"
       data-search-input-cache-value="true"
       data-search-input-display-all-value="false">
    
    <div class="home-search-button">
      <a href="/search" data-search-input-target="button">Search Button</a>
      <div class="search-component-loader d-none" data-search-input-target="loader">Loading...</div>
    </div>

    <input type="text" id="cached-input"
           data-search-input-target="input"
           data-action="input->search-input#search blur->search-input#blur keydown.down->search-input#arrow_down keydown.up->search-input#arrow_up keydown.enter->search-input#enter_key" />

    <div class="search-container" data-search-input-target="dropDown">
      <a class="search-content" id="action-1" href="/search?query=o#results" data-turbo-frame="_top" data-search-input-target="actionLink">
        <p class="mb-0"></p>
        <div><span>Search for</span></div>
      </a>
      <a class="search-content" id="action-2" href="/ontologies?search=o#browse" data-turbo-frame="_top" data-search-input-target="actionLink">
        <p class="mb-0"></p>
        <div><span>Browse all</span></div>
      </a>
    </div>

    <template data-search-input-target="template">
      <a href="LINK" class="search-content trusted-anchor-item" data-turbo-frame="_top">
        <svg class="trusted-icon" width="10" height="10"><circle cx="5" cy="5" r="5"/></svg>
        <p class="search-element home-searched-ontology">
          NAME(ACRONYM)
        </p>
        <p class="home-result-type">
          TYPE
        </p>
      </a>
    </template>
  </div>

  <!-- Container 2: Fetched items with Class-Picker Div template -->
  <div id="search-container-fetched" class="search-inputs"
       data-controller="search-input"
       data-search-input-ajax-url-value="/ajax/search?q="
       data-search-input-cache-value="false"
       data-search-input-display-all-value="true">
    
    <div class="home-search-button">
      <a href="/search" data-search-input-target="button">Search Button</a>
      <div class="search-component-loader d-none" data-search-input-target="loader">Loading...</div>
    </div>

    <input type="text" id="fetched-input"
           data-search-input-target="input"
           data-action="input->search-input#search" />

    <div class="search-container" data-search-input-target="dropDown">
      <a class="search-content" id="action-fetched" href="/search?query=o" data-search-input-target="actionLink">
        <p class="mb-0"></p>
      </a>
    </div>

    <template data-search-input-target="template">
      <div class="search-content clickable-result" data-action="click->class-picker#addResult" data-turbo-frame="_top">
        <div class="search-element home-searched-ontology flex-column">
          <p class="class-label_name">LABEL</p>
          <small class="class-uri">NAME</small>
          <small class="text-primary">ACRONYM</small>
        </div>
        <p class="home-result-type">TYPE</p>
      </div>
    </template>
  </div>

  <!-- Container 3: Agent template with NAME ACRONYM IDENTIFIERS -->
  <div id="search-container-agent" class="search-inputs"
       data-controller="search-input"
       data-search-input-cache-value="true"
       data-search-input-display-all-value="true">

    <div class="home-search-button">
      <a href="/search" data-search-input-target="button">Search Button</a>
      <div class="search-component-loader d-none" data-search-input-target="loader">Loading...</div>
    </div>

    <input type="text" id="agent-input"
           data-search-input-target="input"
           data-action="input->search-input#search" />

    <div class="search-container" data-search-input-target="dropDown">
      <a class="search-content" id="action-agent" href="/agents/new?name=&id=0" data-search-input-target="actionLink">
        <p class="mb-0"></p>
      </a>
    </div>

    <template data-search-input-target="template">
      <a href="LINK" class="search-content" data-turbo-frame="_self">
        <p class="search-element home-searched-ontology">
          NAME ACRONYM IDENTIFIERS
        </p>
        <p class="home-result-type">
          TYPE
        </p>
      </a>
    </template>
  </div>
</body>
</html>`;

async function runTests() {
  const testResults = {
    total: 0,
    passed: 0,
    failed: 0,
    cases: []
  };

  function record(title, passed, details = '') {
    testResults.total++;
    if (passed) {
      testResults.passed++;
      testResults.cases.push({ title, status: 'PASS', details });
      console.log(`  ✓ ${title}`);
    } else {
      testResults.failed++;
      testResults.cases.push({ title, status: 'FAIL', details });
      console.error(`  ✗ ${title}: ${details}`);
    }
  }

  console.log('[1/4] Building production Stimulus bundle with esbuild...');
  const bundleJs = await buildControllerBundle();
  console.log(`      Bundle size: ${bundleJs.length} bytes`);

  console.log('[2/4] Launching isolated headless Chromium browser...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true
  });

  try {
    const context = await browser.newContext({
      javaScriptEnabled: true
    });

    // Independently track browser request events and deny all routable requests
    const recordedRequests = [];
    let blockedRequests = 0;
    context.on('request', (request) => {
      recordedRequests.push(request.url());
    });
    await context.route('**', (route) => {
      blockedRequests++;
      route.abort();
    });

    const page = await context.newPage();

    // Track any unexpected script injection / alert execution
  await page.addInitScript(() => {
    window.__xssTriggered = [];
    window.__mockAjaxResponse = null;
    window.jQuery = {
      ajax: function(options) {
        if (window.__mockAjaxResponse) {
          options.success(window.__mockAjaxResponse);
        } else {
          options.error();
        }
      }
    };
  });

  await page.setContent(HTML_FIXTURE);
  await page.addScriptTag({ content: bundleJs });

  const ready = await page.evaluate(() => window.__searchControllerReady);
  assert.strictEqual(ready, true, 'Stimulus controller failed to initialize');

  console.log('[3/4] Running isolated DOM security and binding test cases...');

  // -------------------------------------------------------------
  // Test 1: Inert markup-shaped local search term in cached rendering
  // -------------------------------------------------------------
  {
    const searchTerm = '<img src=x onerror="window.__xssTriggered.push(1)"> "quotes" & \'amp\' <b>bold</b> #frag+100%';
    
    // Set cached items with search term in name to test item rendering as well
    await page.evaluate((term) => {
      const container = document.getElementById('search-container-cached');
      const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(container, 'search-input');
      ctrl.items = [
        {
          name: 'Ontology ' + term,
          acronym: 'ONTO1',
          type: 'http://www.w3.org/2002/07/owl#Ontology',
          link: '/ontologies/ONTO1'
        }
      ];
    }, searchTerm);

    // Type into input
    await page.fill('#cached-input', searchTerm);
    // Trigger input event to invoke search
    await page.evaluate(() => {
      const input = document.getElementById('cached-input');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    // Wait debounce (100ms)
    await page.waitForTimeout(150);

    const actionText = await page.textContent('#action-1 p');
    const actionHtml = await page.innerHTML('#action-1 p');
    const actionElementsCount = await page.evaluate(() => document.querySelectorAll('#action-1 p *').length);
    const actionHref = await page.getAttribute('#action-1', 'href');
    const buttonHref = await page.getAttribute('#search-container-cached [data-search-input-target="button"]', 'href');

    record('Local search term sets textContent without parsing markup elements',
      actionText === searchTerm && actionElementsCount === 0 && !actionHtml.includes('<img') && actionHtml.includes('&lt;img'),
      `Elements inside p: ${actionElementsCount}, text: ${actionText}`
    );

    record('Action link preserves original query key, fragment, and safely encodes special chars',
      actionHref.startsWith('/search?query=') && actionHref.includes('%3Cimg') && actionHref.endsWith('#results'),
      `actionHref: ${actionHref}`
    );

    record('Button href safely encodes search query and preserves existing query and fragment',
      buttonHref.startsWith('/search?') && buttonHref.includes('scope=all') && buttonHref.includes('q=') && buttonHref.includes('%3Cimg') && buttonHref.includes('#top'),
      `buttonHref: ${buttonHref}`
    );

    // Query roundtrip identity: decoded query parameter must strictly equal the raw search term
    const parsedActionQuery = new URL(actionHref, 'http://localhost').searchParams.get('query');
    const parsedButtonQuery = new URL(buttonHref, 'http://localhost').searchParams.get('q');
    record('Search and action query identity strictly preserved across URL encoding/decoding',
      parsedActionQuery === searchTerm && parsedButtonQuery === searchTerm,
      `action query: ${parsedActionQuery}`
    );

    const xssTriggered = await page.evaluate(() => window.__xssTriggered);
    record('No script/payload executed from search term', xssTriggered.length === 0, `XSS count: ${xssTriggered.length}`);
  }

  // -------------------------------------------------------------
  // Test 2: Special scalar data in API response (quotes, ampersands, angle brackets, Unicode, pipes, line breaks, dollar tokens, token-like text)
  // -------------------------------------------------------------
  {
    const scalarData = {
      label: '$100 & <script>window.__xssTriggered.push(2)</script> | "quoted" \n newline \u00e9\u00f1 TYPE NAME ACRONYM',
      name: 'http://example.org/classes/$99 & <img src=y onerror="window.__xssTriggered.push(3)">',
      acronym: 'SPEC',
      type: 'http://www.w3.org/2002/07/owl#Class',
      id: 'http://example.org/classes/SPEC'
    };

    await page.evaluate((data) => {
      window.__mockAjaxResponse = [data];
      const container = document.getElementById('search-container-fetched');
      const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(container, 'search-input');
      ctrl.items = [];
    }, scalarData);

    await page.fill('#fetched-input', 'spec');
    await page.evaluate(() => {
      const input = document.getElementById('fetched-input');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.waitForTimeout(150);

    const resultDiv = await page.$('#search-container-fetched .clickable-result');
    assert(resultDiv, 'Fetched result div should exist');

    const actionFetchedText = await page.textContent('#action-fetched p');
    const actionFetchedHref = await page.getAttribute('#action-fetched', 'href');
    record('Action link updated with search term after successful fetch',
      actionFetchedText === 'spec' && actionFetchedHref === '/search?query=spec',
      `actionFetchedText: ${actionFetchedText}, href: ${actionFetchedHref}`
    );

    const labelText = await page.textContent('#search-container-fetched .class-label_name');
    const labelElementsCount = await page.evaluate(() => document.querySelectorAll('#search-container-fetched .class-label_name *').length);
    const uriText = await page.textContent('#search-container-fetched .class-uri');
    const acronymText = await page.textContent('#search-container-fetched .text-primary');
    const typeText = await page.textContent('#search-container-fetched .home-result-type');

    record('Scalar label with markup, quotes, ampersands, newlines, and dollar content is exact text',
      labelText === scalarData.label && labelElementsCount === 0,
      `labelText: ${labelText}`
    );

    record('Dollar sign $100 preserved without regex substitution corruption',
      labelText.includes('$100') && uriText.includes('$99'),
      `labelText: ${labelText}`
    );

    record('No recursive replacement of placeholder names inside inserted API text',
      labelText.includes('TYPE NAME ACRONYM'),
      `labelText: ${labelText}`
    );

    record('Field formatting: TYPE final segment, parenthesized ACRONYM',
      typeText.trim() === 'owl#Class' && acronymText.trim() === '(SPEC)',
      `type: ${typeText}, acronym: ${acronymText}`
    );

    const xssCount = await page.evaluate(() => window.__xssTriggered.length);
    record('No script execution from API payload markup/event handlers', xssCount === 0, `XSS count: ${xssCount}`);
  }

  // -------------------------------------------------------------
  // Test 3: Cloned app template preservation and Class-Picker non-anchor div
  // -------------------------------------------------------------
  {
    const isDiv = await page.evaluate(() => {
      const el = document.querySelector('#search-container-fetched .clickable-result');
      return el.tagName === 'DIV' && el.getAttribute('data-action') === 'click->class-picker#addResult';
    });
    record('Class-picker template preserves non-anchor DIV and data-action attribute', isDiv);

    const cachedAnchorIcon = await page.evaluate(() => {
      const anchor = document.querySelector('#search-container-cached .trusted-anchor-item');
      const svg = anchor ? anchor.querySelector('svg.trusted-icon circle') : null;
      return svg !== null;
    });
    record('Trusted template SVG icons and child elements preserved in cloned anchor', cachedAnchorIcon);
  }

  // -------------------------------------------------------------
  // Test 4: URL scheme rejection and legitimate navigation retention
  // -------------------------------------------------------------
  {
    const itemsWithVariousUrls = [
      {
        name: 'Evil Javascript Scheme',
        acronym: 'EVIL1',
        type: 'Ontology',
        link: 'javascript:window.__xssTriggered.push(4)'
      },
      {
        name: 'Evil Data Scheme',
        acronym: 'EVIL2',
        type: 'Ontology',
        link: 'data:text/html,<script>window.__xssTriggered.push(5)</script>'
      },
      {
        name: 'Evil VBScript Scheme',
        acronym: 'EVIL3',
        type: 'Ontology',
        link: 'vbscript:msgbox("xss")'
      },
      {
        name: 'Safe Relative Path Scheme',
        acronym: 'SAFE1',
        type: 'Ontology',
        link: '/ontologies/SAFE1?tab=classes&page=2#class-details'
      },
      {
        name: 'Safe Absolute HTTPS Scheme',
        acronym: 'SAFE2',
        type: 'Ontology',
        link: 'https://example.org/ontologies/SAFE2?foo=bar#section'
      }
    ];

    await page.evaluate((items) => {
      const container = document.getElementById('search-container-cached');
      const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(container, 'search-input');
      ctrl.items = items;
      ctrl.displayAllValue = true;
    }, itemsWithVariousUrls);

    await page.fill('#cached-input', 'scheme');
    await page.evaluate(() => {
      const input = document.getElementById('cached-input');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.waitForTimeout(150);

    const renderedHrefs = await page.evaluate(() => {
      const links = Array.from(document.querySelectorAll('#search-container-cached .trusted-anchor-item'));
      return links.map(l => ({
        text: l.textContent.trim(),
        hasHref: l.hasAttribute('href'),
        href: l.getAttribute('href')
      }));
    });

    const evilJs = renderedHrefs.find(h => h.text.includes('EVIL1'));
    const evilData = renderedHrefs.find(h => h.text.includes('EVIL2'));
    const evilVb = renderedHrefs.find(h => h.text.includes('EVIL3'));
    const safeRel = renderedHrefs.find(h => h.text.includes('SAFE1'));
    const safeAbs = renderedHrefs.find(h => h.text.includes('SAFE2'));

    record('Rejects javascript: scheme by removing href', evilJs && !evilJs.hasHref);
    record('Rejects data: scheme by removing href', evilData && !evilData.hasHref);
    record('Rejects vbscript: scheme by removing href', evilVb && !evilVb.hasHref);
    record('Retains safe relative URL with query and fragment',
      safeRel && safeRel.href === '/ontologies/SAFE1?tab=classes&page=2#class-details',
      `safeRel href: ${safeRel ? safeRel.href : null}`
    );
    record('Retains safe absolute HTTPS URL with query and fragment',
      safeAbs && safeAbs.href === 'https://example.org/ontologies/SAFE2?foo=bar#section',
      `safeAbs href: ${safeAbs ? safeAbs.href : null}`
    );
  }

  // -------------------------------------------------------------
  // Test 5: 4 items vs displayAll behavior
  // -------------------------------------------------------------
  {
    const sixItems = Array.from({ length: 6 }, (_, i) => ({
      name: `Test Item ${i + 1}`,
      acronym: `T${i + 1}`,
      type: 'Ontology',
      link: `/ontologies/T${i + 1}`
    }));

    // Test with displayAll = false (limit 4)
    await page.evaluate((items) => {
      const container = document.getElementById('search-container-cached');
      const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(container, 'search-input');
      ctrl.items = items;
      ctrl.displayAllValue = false;
    }, sixItems);

    await page.fill('#cached-input', 'Test Item');
    await page.evaluate(() => {
      const input = document.getElementById('cached-input');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.waitForTimeout(150);

    const countLimited = await page.evaluate(() => {
      return document.querySelectorAll('#search-container-cached .trusted-anchor-item').length;
    });
    record('Limits results to 4 when displayAll is false', countLimited === 4, `Count: ${countLimited}`);

    // Test with displayAll = true (all 6)
    await page.evaluate((items) => {
      const container = document.getElementById('search-container-cached');
      const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(container, 'search-input');
      ctrl.items = items;
      ctrl.displayAllValue = true;
    }, sixItems);

    await page.fill('#cached-input', 'Test Item');
    await page.evaluate(() => {
      const input = document.getElementById('cached-input');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.waitForTimeout(150);

    const countAll = await page.evaluate(() => {
      return document.querySelectorAll('#search-container-cached .trusted-anchor-item').length;
    });
    record('Displays all 6 results when displayAll is true', countAll === 6, `Count: ${countAll}`);
  }

  // -------------------------------------------------------------
  // Test 6: Agent template with optional parenthesized ACRONYM and prefixed IDENTIFIERS
  // -------------------------------------------------------------
  {
    const agentItems = [
      {
        name: 'Fraunhofer IWM',
        acronym: 'IWM',
        identifiers: 'ROR:003vg9w96',
        type: 'organization',
        link: '/agents/1/show'
      },
      {
        name: 'Person Name',
        acronym: '',
        identifiers: 'ORCID:0000-1524-5487-5487',
        type: 'person',
        link: '/agents/2/show'
      },
      {
        name: 'Simple Person',
        acronym: null,
        identifiers: null,
        type: 'person',
        link: '/agents/3/show'
      }
    ];

    await page.evaluate((items) => {
      const container = document.getElementById('search-container-agent');
      const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(container, 'search-input');
      ctrl.items = items;
    }, agentItems);

    await page.fill('#agent-input', 'person');
    await page.evaluate(() => {
      const input = document.getElementById('agent-input');
      input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.waitForTimeout(150);

    const renderedAgents = await page.evaluate(() => {
      const items = Array.from(document.querySelectorAll('#search-container-agent .search-content.home-dropdown-active, #search-container-agent .search-container > a:not([data-search-input-target="actionLink"])'));
      return items.map(el => ({
        text: el.querySelector('.search-element').textContent.trim(),
        type: el.querySelector('.home-result-type').textContent.trim()
      }));
    });

    const personWithOrcid = renderedAgents.find(a => a.text.includes('Person Name'));
    const simplePerson = renderedAgents.find(a => a.text.includes('Simple Person'));

    record('Agent with identifiers has prefixed format without empty parentheses',
      personWithOrcid && personWithOrcid.text.includes('- ORCID:0000-1524-5487-5487') && !personWithOrcid.text.includes('()'),
      `text: ${personWithOrcid ? personWithOrcid.text : null}`
    );

    record('Agent without acronym and identifiers has clean name without dangling dash or parens',
      simplePerson && simplePerson.text === 'Simple Person' && !simplePerson.text.includes('-') && !simplePerson.text.includes('()'),
      `text: ${simplePerson ? simplePerson.text : null}`
    );
  }

  // -------------------------------------------------------------
  // Test 7: Zero network requests made during tested rendering
  // -------------------------------------------------------------
  record('Zero external / non-fixture requests initiated during browser execution',
    recordedRequests.length === 0 && blockedRequests === 0,
    `Recorded requests: ${recordedRequests.length}, blocked: ${blockedRequests}`
  );
  } finally {
    await browser.close();
  }

  console.log('[4/4] Test summary:');
  console.log(`      Total:  ${testResults.total}`);
  console.log(`      Passed: ${testResults.passed}`);
  console.log(`      Failed: ${testResults.failed}`);

  if (testResults.failed > 0) {
    process.exit(1);
  }

  return testResults;
}

if (require.main === module) {
  runTests().catch(err => {
    console.error('Test run failed with error:', err);
    process.exit(1);
  });
}

module.exports = { runTests };
