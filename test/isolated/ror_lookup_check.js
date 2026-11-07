/**
 * test/isolated/ror_lookup_check.js
 *
 * ONTO-T-J05: ROR lookup sequencing, auto-fill field tracking, and failure handling.
 * - Out-of-order responses do not replace newer query results.
 * - Switching agent mode discards in-flight results.
 * - Selecting another organization clears auto-filled fields the new organization lacks,
 *   while preserving manually edited values.
 * - Lookup failures display a non-blocking unavailable state while inputs remain editable.
 *
 * Real ror_search_controller on a real Stimulus application in headless Chrome.
 */
const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

// Fixture HTML mirroring app/views/agents/_form.html.haml
const HTML = `<!doctype html>
<html>
<head><meta charset="utf-8"></head>
<body>
<form id="agent-form">
  <div data-controller="ror-search"
       data-ror-search-debounce-ms-value="20"
       data-ror-search-api-url-value="http://ror.fixture/v2/organizations"
       data-ror-search-min-length-value="2">
    <div>
      <input type="radio" name="agentType" id="agentType_person" value="person"
             data-action="change->ror-search#hide change->ror-search#updatePlaceholder">
      <label for="agentType_person">Person</label>
      <input type="radio" name="agentType" id="agentType_organization" value="organization" checked
             data-ror-search-target="organizationRadio"
             data-action="change->ror-search#updatePlaceholder">
      <label for="agentType_organization">Organization</label>
    </div>
    <div class="search-inputs">
      <input type="text" id="name_input" class="form-control" autocomplete="off"
             data-ror-search-target="nameInput"
             data-action="input->ror-search#search blur->ror-search#blur">
      <div class="search-container" id="results_container"
           data-ror-search-target="results"
           data-action="mousedown->ror-search#prevent"
           style="display: none;"></div>
    </div>
    <div>
      <input type="text" id="acronym_input" class="form-control" data-ror-search-target="acronymInput">
      <input type="url" id="homepage_input" class="form-control" data-ror-search-target="homepageInput">
      <input type="text" id="identifier_input" class="form-control" data-ror-search-target="identifierInput">
    </div>
  </div>
</form>
</body>
</html>`;

const alphaOrg = {
  id: 'https://ror.org/01alpha12',
  names: [
    { value: 'Alpha University', lang: 'en', types: ['label', 'ror_display'] },
    { value: 'AU', types: ['acronym'] }
  ],
  domains: ['https://alpha.edu'],
  locations: [{ geonames_details: { country_name: 'United States' } }]
};

const betaOrg = {
  id: 'https://ror.org/02beta34',
  names: [
    { value: 'Beta Institute', lang: 'en', types: ['label', 'ror_display'] }
  ],
  domains: [],
  links: [],
  locations: []
};

const gammaOrg = {
  id: 'https://ror.org/03gamma56',
  names: [
    { value: 'Gamma Lab', lang: 'en', types: ['label', 'ror_display'] },
    { value: 'GL', types: ['acronym'] }
  ],
  domains: ['gamma.org'],
  locations: []
};

const waitFor = async (predicate, timeout = 3000) => {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeout) throw new Error('Condition timed out in Node context');
    await new Promise(r => setTimeout(r, 10));
  }
};

(async () => {
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const { Application } = require('@hotwired/stimulus');
        const RorSearch = require('../../app/javascript/controllers/ror_search_controller.js').default;
        window.__stimulusErrors = [];
        const app = window.__app = Application.start();
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('ror-search', RorSearch);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true,
    format: 'iife',
    write: false,
    nodePaths: [
      path.resolve(__dirname, '../../node_modules'),
      '/home/ranma/ontoportal/bioportal_web_ui/node_modules',
      '/home/ranma/.pi/agent/npm/node_modules'
    ]
  })).outputFiles[0].text;

  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  const rorQueries = [];
  let rorHandler = null;

  try {
    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));

    await page.route('**/*', async (route) => {
      const url = new URL(route.request().url());
      if (url.origin === 'http://ror.fixture' && url.pathname === '/') {
        return route.fulfill({ contentType: 'text/html', body: HTML });
      }
      if (url.origin === 'http://ror.fixture' && url.pathname === '/v2/organizations') {
        const query = url.searchParams.get('query');
        rorQueries.push(query);
        if (rorHandler) {
          return rorHandler(route, url, query);
        }
        return route.fulfill({
          contentType: 'application/json',
          body: JSON.stringify({ items: [] })
        });
      }
      outside.push(url.href);
      return route.abort();
    });

    await page.goto('http://ror.fixture/');
    await page.addScriptTag({ content: bundle });
    await page.waitForFunction(() => window.__app && window.__app.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="ror-search"]'), 'ror-search') !== null);

    // =========================================================================
    // Test 1: Out-of-order responses - a slow first response must not replace a faster second one
    // =========================================================================
    let heldRoute1 = null;
    rorHandler = (route, url, q) => {
      if (q === 'SlowQuery') {
        heldRoute1 = route;
        return; // Hold this request in-flight
      }
      if (q === 'FastQuery') {
        return route.fulfill({
          contentType: 'application/json',
          body: JSON.stringify({ items: [betaOrg] })
        });
      }
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ items: [] }) });
    };

    await page.fill('#name_input', 'SlowQuery');
    await waitFor(() => heldRoute1 !== null);

    await page.fill('#name_input', 'FastQuery');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && res.textContent.includes('Beta Institute');
    }, null, { timeout: 3000 });

    // Fulfill the held first response with Alpha University
    try {
      await heldRoute1.fulfill({
        contentType: 'application/json',
        body: JSON.stringify({ items: [alphaOrg] })
      });
    } catch (_) {
      // Aborted by client AbortController is expected
    }

    await page.waitForTimeout(100);

    const resultsText1 = await page.textContent('#results_container');
    assert.ok(resultsText1.includes('Beta Institute'), 'FastQuery results remain rendered');
    assert.ok(!resultsText1.includes('Alpha University'), 'Slow first response did not replace faster second response');

    // =========================================================================
    // Test 2: Mode switch discards in-flight results
    // =========================================================================
    let heldModeRoute = null;
    rorHandler = (route, url, q) => {
      if (q === 'ModeQuery') {
        heldModeRoute = route;
        return; // Hold in-flight
      }
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ items: [] }) });
    };

    await page.check('#agentType_organization');
    await page.fill('#name_input', 'ModeQuery');
    await waitFor(() => heldModeRoute !== null);

    // Switch mode to Person while request is in flight
    await page.check('#agentType_person');

    // Fulfill the held request with Alpha University
    try {
      await heldModeRoute.fulfill({
        contentType: 'application/json',
        body: JSON.stringify({ items: [alphaOrg] })
      });
    } catch (_) {}

    await page.waitForTimeout(100);

    const modeDisplay = await page.evaluate(() => {
      const res = document.getElementById('results_container');
      return {
        display: res ? res.style.display : null,
        text: res ? res.textContent : ''
      };
    });
    assert.strictEqual(modeDisplay.display, 'none', 'Results hidden after mode switch to person');
    assert.ok(!modeDisplay.text.includes('Alpha University'), 'In-flight results discarded on mode switch');

    // =========================================================================
    // Test 3: Auto-fill tracking, field clearing, and user edit preservation
    // =========================================================================
    await page.check('#agentType_organization');

    rorHandler = (route, url, q) => {
      if (q === 'Alpha') {
        return route.fulfill({
          contentType: 'application/json',
          body: JSON.stringify({ items: [alphaOrg] })
        });
      }
      if (q === 'Beta') {
        return route.fulfill({
          contentType: 'application/json',
          body: JSON.stringify({ items: [betaOrg] })
        });
      }
      if (q === 'Gamma') {
        return route.fulfill({
          contentType: 'application/json',
          body: JSON.stringify({ items: [gammaOrg] })
        });
      }
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ items: [] }) });
    };

    // 3a: Select Alpha University (has acronym "AU" and homepage "https://alpha.edu")
    await page.fill('#name_input', 'Alpha');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && res.textContent.includes('Alpha University');
    }, null, { timeout: 3000 });

    await page.click('#results_container a.search-content');

    const formState1 = await page.evaluate(() => ({
      name: document.getElementById('name_input').value,
      acronym: document.getElementById('acronym_input').value,
      homepage: document.getElementById('homepage_input').value,
      identifier: document.getElementById('identifier_input').value
    }));
    assert.strictEqual(formState1.name, 'Alpha University');
    assert.strictEqual(formState1.acronym, 'AU');
    assert.strictEqual(formState1.homepage, 'https://alpha.edu');
    assert.strictEqual(formState1.identifier, 'https://ror.org/01alpha12');

    // 3b: Select Beta Institute (which lacks acronym and homepage)
    // Acronym and homepage were auto-filled by Alpha, so selecting Beta must clear them together.
    await page.fill('#name_input', 'Beta');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && res.textContent.includes('Beta Institute');
    }, null, { timeout: 3000 });

    await page.click('#results_container a.search-content');

    const formState2 = await page.evaluate(() => ({
      name: document.getElementById('name_input').value,
      acronym: document.getElementById('acronym_input').value,
      homepage: document.getElementById('homepage_input').value,
      identifier: document.getElementById('identifier_input').value
    }));
    assert.strictEqual(formState2.name, 'Beta Institute');
    assert.strictEqual(formState2.acronym, '', 'Acronym cleared because Beta lacks it');
    assert.strictEqual(formState2.homepage, '', 'Homepage cleared because Beta lacks it');
    assert.strictEqual(formState2.identifier, 'https://ror.org/02beta34');

    // 3c: Select Alpha again, then manually edit homepage, then select Beta.
    // The manually edited homepage must be preserved, while unedited auto-filled acronym is cleared.
    await page.fill('#name_input', 'Alpha');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && res.textContent.includes('Alpha University');
    }, null, { timeout: 3000 });
    await page.click('#results_container a.search-content');

    // User manually modifies homepage
    await page.fill('#homepage_input', 'https://custom-hand-edited.org');

    // Now select Beta (which lacks acronym and homepage)
    await page.fill('#name_input', 'Beta');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && res.textContent.includes('Beta Institute');
    }, null, { timeout: 3000 });
    await page.click('#results_container a.search-content');

    const formState3 = await page.evaluate(() => ({
      name: document.getElementById('name_input').value,
      acronym: document.getElementById('acronym_input').value,
      homepage: document.getElementById('homepage_input').value,
      identifier: document.getElementById('identifier_input').value
    }));
    assert.strictEqual(formState3.name, 'Beta Institute');
    assert.strictEqual(formState3.acronym, '', 'Unedited auto-filled acronym cleared');
    assert.strictEqual(formState3.homepage, 'https://custom-hand-edited.org', 'Manually edited homepage preserved');
    assert.strictEqual(formState3.identifier, 'https://ror.org/02beta34', 'Identifier updated to Beta');

    // 3d: Select Gamma Lab (which has acronym "GL" and homepage "gamma.org").
    // The previously cleared/empty acronym is filled with "GL", while the manually edited homepage is still preserved.
    await page.fill('#name_input', 'Gamma');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && res.textContent.includes('Gamma Lab');
    }, null, { timeout: 3000 });
    await page.click('#results_container a.search-content');

    const formState4 = await page.evaluate(() => ({
      name: document.getElementById('name_input').value,
      acronym: document.getElementById('acronym_input').value,
      homepage: document.getElementById('homepage_input').value,
      identifier: document.getElementById('identifier_input').value
    }));
    assert.strictEqual(formState4.name, 'Gamma Lab');
    assert.strictEqual(formState4.acronym, 'GL', 'Empty acronym auto-filled with Gamma');
    assert.strictEqual(formState4.homepage, 'https://custom-hand-edited.org', 'Manually edited homepage remains preserved');
    assert.strictEqual(formState4.identifier, 'https://ror.org/03gamma56', 'Identifier updated to Gamma');

    // =========================================================================
    // Test 4: Lookup error shows the unavailable state while inputs stay editable
    // =========================================================================
    rorHandler = (route, url, q) => {
      if (q === 'ErrorOrg') {
        return route.fulfill({ status: 500, body: 'ROR Service Error' });
      }
      if (q === 'RecoverOrg') {
        return route.fulfill({
          contentType: 'application/json',
          body: JSON.stringify({ items: [alphaOrg] })
        });
      }
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ items: [] }) });
    };

    await page.fill('#name_input', 'ErrorOrg');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && /unavailable/i.test(res.textContent);
    }, null, { timeout: 3000 });

    const errorState = await page.evaluate(() => {
      const inp = document.getElementById('name_input');
      const res = document.getElementById('results_container');
      return {
        hasUnavailable: /unavailable/i.test(res.textContent),
        displayed: res.style.display !== 'none',
        nameDisabled: inp.disabled,
        nameReadOnly: inp.readOnly
      };
    });
    assert.ok(errorState.hasUnavailable && errorState.displayed, 'Unavailable state displayed on error');
    assert.strictEqual(errorState.nameDisabled, false, 'Name input not disabled');
    assert.strictEqual(errorState.nameReadOnly, false, 'Name input not read-only');

    // Typing a valid query recovers from error state
    await page.fill('#name_input', 'RecoverOrg');
    await page.waitForFunction(() => {
      const res = document.getElementById('results_container');
      return res && res.style.display !== 'none' && res.textContent.includes('Alpha University');
    }, null, { timeout: 3000 });

    const recovered = await page.textContent('#results_container');
    assert.ok(recovered.includes('Alpha University'), 'Recovered from error on subsequent valid query');

    // =========================================================================
    // Invariants: Stimulus errors, page errors, and outside requests
    // =========================================================================
    assert.deepStrictEqual(await page.evaluate(() => window.__stimulusErrors), [], 'no Stimulus errors');
    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');

    console.log(`PASS ror lookup; queries=${JSON.stringify(rorQueries)}; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
  }
})().catch(e => {
  console.error('FAIL', e);
  process.exit(1);
});
