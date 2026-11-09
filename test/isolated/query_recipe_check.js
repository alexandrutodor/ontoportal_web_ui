const http = require('http');
const path = require('path');
const fs = require('fs');
const assert = require('assert');
const esbuild = require('esbuild');
const { chromium } = require('playwright');

// Bundle the Stimulus application with QueryRecipeController
const controllerPath = path.resolve(__dirname, '../../app/javascript/controllers/query_recipe_controller.js');

const bundleResult = esbuild.buildSync({
  stdin: {
    contents: `
      import { Application } from "@hotwired/stimulus";
      import QueryRecipeController from "${controllerPath}";

      const application = Application.start();
      application.register("query-recipe", QueryRecipeController);
      window.StimulusApp = application;
    `,
    resolveDir: process.cwd()
  },
  bundle: true,
  write: false,
  format: 'iife',
  nodePaths: [
    '/home/ranma/.pi/agent/npm/node_modules',
    '/home/ranma/ontoportal/bioportal_web_ui/node_modules'
  ]
});

const bundledJs = bundleResult.outputFiles[0].text;

function renderBrowseHtml(initialQuery = '') {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Browse Fixture</title>
  <script>${bundledJs}</script>
</head>
<body>
  <div class="browse-container">
    <div class="browse-search-bar">
      <input type="text" name="search" id="search" value="" />
      <select name="format" id="format">
        <option value="">All</option>
        <option value="OWL">OWL</option>
        <option value="SKOS">SKOS</option>
      </select>
      <select name="Sort_by" id="Sort_by">
        <option value="name">Name</option>
        <option value="ontology_name">Ontology Name</option>
        <option value="popularity">Popularity</option>
      </select>
    </div>

    <div class="browse-filter">
      <input type="checkbox" name="views" id="views" value="true" />
      <input type="checkbox" name="retired" id="retired" value="true" />
      <input type="checkbox" name="user_ontologies_only" id="user_ontologies_only" value="true" />
      <input type="checkbox" name="private_only" id="private_only" value="true" />
    </div>

    <div id="categories-container">
      <input type="checkbox" name="categories[]" id="cat1" value="CAT1" />
      <input type="checkbox" name="categories[]" id="cat2" value="CAT2" />
    </div>

    <div id="groups-container">
      <input type="checkbox" name="groups[]" id="grp1" value="GRP1" />
      <input type="checkbox" name="groups[]" id="grp2" value="GRP2" />
    </div>

    <div id="language-container">
      <select name="naturalLanguage" id="naturalLanguage">
        <option value="">All</option>
        <option value="en">English</option>
        <option value="fr">French</option>
      </select>
    </div>

    <!-- QueryRecipeComponent -->
    <div class="query-recipe-component"
         data-controller="query-recipe"
         data-query-recipe-kind-value="browse"
         data-query-recipe-portal-value="MatPortal"
         data-query-recipe-locale-value="en"
         data-query-recipe-storage-key-value="ontoportal_query_recipes_v1">
      <button type="button"
              class="query-recipe-trigger-btn"
              data-action="click->query-recipe#togglePanel"
              data-query-recipe-target="triggerButton"
              aria-expanded="false"
              aria-controls="query-recipe-panel-browse">
        Saved Recipes
      </button>
      <div id="query-recipe-panel-browse"
           class="query-recipe-panel d-none"
           data-query-recipe-target="panel"
           role="dialog"
           aria-label="Saved Recipes">
        <button type="button" class="close" data-action="click->query-recipe#closePanel" data-query-recipe-target="closeButton">×</button>
        <div class="query-recipe-save-box">
          <input type="text"
                 id="recipe-name-browse"
                 class="query-recipe-name-input"
                 data-query-recipe-target="nameInput"
                 data-action="keydown->query-recipe#onNameKeydown" />
          <button type="button"
                  class="query-recipe-save-btn"
                  data-action="click->query-recipe#saveCurrent"
                  data-query-recipe-target="saveButton">Save</button>
        </div>
        <div class="query-recipe-message alert d-none" data-query-recipe-target="message" role="status"></div>
        <div class="query-recipe-list" data-query-recipe-target="list" role="region" aria-label="Saved Recipes"></div>
        <button type="button" class="query-recipe-import-btn" data-action="click->query-recipe#triggerImport" data-query-recipe-target="importButton">Import</button>
        <input type="file" class="query-recipe-file-input d-none" accept=".json,application/json" data-query-recipe-target="fileInput" data-action="change->query-recipe#handleFileImport" />
        <button type="button" class="query-recipe-clear-btn" data-action="click->query-recipe#clearAll" data-query-recipe-target="clearAllButton">Clear all</button>
      </div>
    </div>
  </div>
</body>
</html>`;
}

function renderSearchHtml() {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Search Fixture</title>
  <script>${bundledJs}</script>
</head>
<body>
  <form id="search-form" action="/search" method="get">
    <input type="text" name="q" id="search_q" value="" />
    <select name="lang" id="search_lang">
      <option value="all">All</option>
      <option value="en">English</option>
      <option value="fr">French</option>
    </select>
    <select multiple name="ontologies[]" id="search_ontologies">
      <option value="ONT_A">ONT_A</option>
      <option value="ONT_B">ONT_B</option>
    </select>
    <input type="checkbox" name="require_exact_match" id="exact_match" value="true" />
    <input type="checkbox" name="require_definition" id="definition" value="true" />
    <input type="checkbox" name="also_search_properties" id="properties" value="true" />

    <!-- QueryRecipeComponent -->
    <div class="query-recipe-component"
         data-controller="query-recipe"
         data-query-recipe-kind-value="search"
         data-query-recipe-portal-value="MatPortal"
         data-query-recipe-locale-value="en"
         data-query-recipe-storage-key-value="ontoportal_query_recipes_v1">
      <button type="button"
              class="query-recipe-trigger-btn"
              data-action="click->query-recipe#togglePanel"
              data-query-recipe-target="triggerButton"
              aria-expanded="false"
              aria-controls="query-recipe-panel-search">
        Saved Recipes
      </button>
      <div id="query-recipe-panel-search"
           class="query-recipe-panel d-none"
           data-query-recipe-target="panel"
           role="dialog"
           aria-label="Saved Recipes">
        <button type="button" class="close" data-action="click->query-recipe#closePanel" data-query-recipe-target="closeButton">×</button>
        <div class="query-recipe-save-box">
          <input type="text"
                 id="recipe-name-search"
                 class="query-recipe-name-input"
                 data-query-recipe-target="nameInput"
                 data-action="keydown->query-recipe#onNameKeydown" />
          <button type="button"
                  class="query-recipe-save-btn"
                  data-action="click->query-recipe#saveCurrent"
                  data-query-recipe-target="saveButton">Save</button>
        </div>
        <div class="query-recipe-message alert d-none" data-query-recipe-target="message" role="status"></div>
        <div class="query-recipe-list" data-query-recipe-target="list" role="region" aria-label="Saved Recipes"></div>
        <button type="button" class="query-recipe-import-btn" data-action="click->query-recipe#triggerImport" data-query-recipe-target="importButton">Import</button>
        <input type="file" class="query-recipe-file-input d-none" accept=".json,application/json" data-query-recipe-target="fileInput" data-action="change->query-recipe#handleFileImport" />
        <button type="button" class="query-recipe-clear-btn" data-action="click->query-recipe#clearAll" data-query-recipe-target="clearAllButton">Clear all</button>
      </div>
    </div>
  </form>
</body>
</html>`;
}

async function run() {
  let server;
  let browser;

  try {
    server = http.createServer((req, res) => {
      const url = new URL(req.url, 'http://127.0.0.1');
      if (url.pathname === '/browse') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(renderBrowseHtml());
      } else if (url.pathname === '/search') {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(renderSearchHtml());
      } else {
        res.writeHead(404);
        res.end('Not found');
      }
    });

    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const port = server.address().port;
    console.log(`Test server running at http://127.0.0.1:${port}`);

    browser = await chromium.launch({
      executablePath: '/usr/bin/google-chrome',
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
    });

    const context = await browser.newContext();
    const page = await context.newPage();

    // -------------------------------------------------------------
    // Test 1: Browse round-trip (categories/groups/language/format/sort/booleans, page reset)
    // -------------------------------------------------------------
    console.log('Testing 1: Browse round-trip...');
    await page.goto(`http://127.0.0.1:${port}/browse?page=3`, { timeout: 10000 });

    // Populate initial browse controls
    await page.check('#cat1', { timeout: 5000 });
    await page.check('#grp1', { timeout: 5000 });
    await page.selectOption('#naturalLanguage', 'en', { timeout: 5000 });
    await page.selectOption('#format', 'OWL', { timeout: 5000 });
    await page.selectOption('#Sort_by', 'ontology_name', { timeout: 5000 });
    await page.check('#views', { timeout: 5000 });

    // Open recipe panel and save
    await page.click('.query-recipe-trigger-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-panel:not(.d-none)', { timeout: 5000 });
    await page.fill('#recipe-name-browse', 'My Browse Recipe', { timeout: 5000 });
    await page.click('.query-recipe-save-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-item', { timeout: 5000 });

    // Mutate state away from saved recipe
    await page.uncheck('#cat1', { timeout: 5000 });
    await page.check('#cat2', { timeout: 5000 });
    await page.uncheck('#grp1', { timeout: 5000 });
    await page.selectOption('#naturalLanguage', 'fr', { timeout: 5000 });
    await page.selectOption('#format', 'SKOS', { timeout: 5000 });
    await page.selectOption('#Sort_by', 'popularity', { timeout: 5000 });
    await page.uncheck('#views', { timeout: 5000 });
    await page.evaluate(() => window.history.pushState({}, '', '/browse?page=5'));

    // Reopen saved recipe
    await page.click('.query-recipe-reopen-btn', { timeout: 5000 });

    // Assert round-trip state
    assert.strictEqual(await page.isChecked('#cat1'), true, 'CAT1 should be restored to checked');
    assert.strictEqual(await page.isChecked('#cat2'), false, 'CAT2 should be unchecked');
    assert.strictEqual(await page.isChecked('#grp1'), true, 'GRP1 should be restored to checked');
    assert.strictEqual(await page.inputValue('#naturalLanguage'), 'en', 'Language should be restored to en');
    assert.strictEqual(await page.inputValue('#format'), 'OWL', 'Format should be restored to OWL');
    assert.strictEqual(await page.inputValue('#Sort_by'), 'ontology_name', 'Sort should be restored to ontology_name');
    assert.strictEqual(await page.isChecked('#views'), true, 'views switch should be restored to checked');

    // Assert pagination reset
    const browseUrl = new URL(page.url());
    assert.strictEqual(browseUrl.searchParams.has('page'), false, 'Pagination parameter page must be reset/omitted');
    console.log('✓ Browse round-trip passed');

    // -------------------------------------------------------------
    // Test 2: Search text with Unicode/spaces/commas/&?#
    // -------------------------------------------------------------
    console.log('Testing 2: Search text with Unicode, spaces, commas, &?#...');
    await page.goto(`http://127.0.0.1:${port}/search`, { timeout: 10000 });

    const complexSearch = 'résumé, test & query ? #val 100%';
    await page.fill('#search_q', complexSearch, { timeout: 5000 });
    await page.check('#exact_match', { timeout: 5000 });

    // Save recipe
    await page.click('.query-recipe-trigger-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-panel:not(.d-none)', { timeout: 5000 });
    await page.fill('#recipe-name-search', 'Special Search', { timeout: 5000 });
    await page.click('.query-recipe-save-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-item', { timeout: 5000 });

    // Clear input
    await page.fill('#search_q', '', { timeout: 5000 });
    await page.uncheck('#exact_match', { timeout: 5000 });

    // Reopen recipe
    await page.click('.query-recipe-reopen-btn', { timeout: 5000 });

    // Assert restoration
    assert.strictEqual(await page.inputValue('#search_q'), complexSearch, 'Complex search text must be preserved exactly');
    assert.strictEqual(await page.isChecked('#exact_match'), true, 'exact_match flag must be preserved');
    console.log('✓ Search Unicode and special characters passed');

    // -------------------------------------------------------------
    // Test 3: Export contains ONLY schema keys even with apikey/session params in URL
    // -------------------------------------------------------------
    console.log('Testing 3: Export schema sanitization...');
    await page.goto(`http://127.0.0.1:${port}/search?q=biomaterial&apikey=SECRET_12345&session_id=SESS_ABC&unwanted=true`, { timeout: 10000 });

    await page.click('.query-recipe-trigger-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-panel:not(.d-none)', { timeout: 5000 });
    await page.fill('#recipe-name-search', 'Export Test Recipe', { timeout: 5000 });
    await page.click('.query-recipe-save-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-item', { timeout: 5000 });

    // Trigger export and intercept download
    const [download] = await Promise.all([
      page.waitForEvent('download', { timeout: 5000 }),
      page.click('.query-recipe-export-btn', { timeout: 5000 })
    ]);

    const downloadStream = await download.createReadStream();
    let exportRaw = '';
    for await (const chunk of downloadStream) {
      exportRaw += chunk;
    }

    const exported = JSON.parse(exportRaw);
    const topKeys = Object.keys(exported).sort();
    assert.deepStrictEqual(topKeys, ['filters', 'kind', 'label', 'locale', 'portal', 'version'], 'Top level export keys must be strictly schema keys');
    assert.strictEqual(exported.version, 1, 'Version must be 1');
    assert.strictEqual(exported.kind, 'search');
    assert.strictEqual(exported.portal, 'MatPortal');
    assert.strictEqual(exported.filters.q, 'biomaterial');

    // Disallowed keys must NOT exist in filters or anywhere
    assert.strictEqual(exported.filters.apikey, undefined, 'API key must NEVER be included in export');
    assert.strictEqual(exported.filters.session_id, undefined, 'Session ID must NEVER be included in export');
    assert.strictEqual(exported.filters.unwanted, undefined, 'Unknown params must NEVER be included in export');
    assert.strictEqual(exportRaw.includes('SECRET_12345'), false, 'Exported string must not contain secret values');
    console.log('✓ Export schema keys and credential exclusion passed');

    // -------------------------------------------------------------
    // Test 4: Malformed/foreign-URL import rejected with form intact and zero outside requests
    // -------------------------------------------------------------
    console.log('Testing 4: Malformed and foreign-URL import rejection...');
    await page.fill('#search_q', 'preserve_this_value', { timeout: 5000 });

    const outsideRequests = [];
    page.on('request', req => {
      const u = req.url();
      if (!u.startsWith(`http://127.0.0.1:${port}`)) {
        outsideRequests.push(u);
      }
    });

    // 4a. Malformed JSON
    await page.setInputFiles('.query-recipe-file-input', {
      name: 'malformed.json',
      mimeType: 'application/json',
      buffer: Buffer.from('{ bad json')
    }, { timeout: 5000 });

    await page.waitForSelector('.query-recipe-message.alert-danger', { timeout: 5000 });
    assert.strictEqual(await page.inputValue('#search_q'), 'preserve_this_value', 'Form must remain intact after malformed import');

    // 4b. Foreign URL in JSON
    const evilPayload = {
      version: 1,
      label: 'Malicious Recipe',
      kind: 'search',
      portal: 'EvilPortal',
      locale: 'en',
      filters: {
        q: 'https://evil.example.com/exploit'
      }
    };

    await page.setInputFiles('.query-recipe-file-input', {
      name: 'evil.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(evilPayload))
    }, { timeout: 5000 });

    await page.waitForSelector('.query-recipe-message.alert-danger', { timeout: 5000 });
    assert.strictEqual(await page.inputValue('#search_q'), 'preserve_this_value', 'Form must remain intact after rejected import');
    assert.strictEqual(outsideRequests.length, 0, 'Zero outside network requests must be made');
    console.log('✓ Malformed and foreign-URL rejection passed');

    // -------------------------------------------------------------
    // Test 5: Rename/delete/clear-all leave other localStorage keys intact
    // -------------------------------------------------------------
    console.log('Testing 5: Namespaced storage isolation...');
    await page.evaluate(() => {
      localStorage.setItem('other_app_setting', 'preserve_me');
      localStorage.setItem('user_auth_token', 'token_123');
    });

    // Rename
    page.once('dialog', dialog => dialog.accept('Renamed Search Recipe'));
    await page.click('.query-recipe-rename-btn', { timeout: 5000 });
    await page.waitForFunction(
      () => document.querySelector('.query-recipe-title')?.textContent?.includes('Renamed Search Recipe'),
      { timeout: 5000 }
    );

    let otherSetting = await page.evaluate(() => localStorage.getItem('other_app_setting'));
    assert.strictEqual(otherSetting, 'preserve_me', 'Rename must not alter other localStorage keys');

    // Delete
    await page.click('.query-recipe-delete-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-message', { timeout: 5000 });

    otherSetting = await page.evaluate(() => localStorage.getItem('other_app_setting'));
    let userToken = await page.evaluate(() => localStorage.getItem('user_auth_token'));
    assert.strictEqual(otherSetting, 'preserve_me', 'Delete must not alter other localStorage keys');
    assert.strictEqual(userToken, 'token_123', 'Delete must not alter user_auth_token');

    // Clear all
    page.once('dialog', dialog => dialog.accept());
    await page.click('.query-recipe-clear-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-empty', { timeout: 5000 });

    otherSetting = await page.evaluate(() => localStorage.getItem('other_app_setting'));
    userToken = await page.evaluate(() => localStorage.getItem('user_auth_token'));
    assert.strictEqual(otherSetting, 'preserve_me', 'Clear all must leave other localStorage keys intact');
    assert.strictEqual(userToken, 'token_123', 'Clear all must leave user_auth_token intact');
    console.log('✓ Namespaced storage isolation passed');

    // -------------------------------------------------------------
    // Test 6: Storage-unavailable path
    // -------------------------------------------------------------
    console.log('Testing 6: Storage-unavailable handling...');
    await page.evaluate(() => {
      const err = new Error('SecurityError: LocalStorage is disabled');
      Object.defineProperty(window, 'localStorage', {
        get: () => ({
          getItem: () => { throw err; },
          setItem: () => { throw err; },
          removeItem: () => { throw err; }
        }),
        configurable: true
      });
    });

    await page.fill('#recipe-name-search', 'Storage Fail Test', { timeout: 5000 });
    await page.click('.query-recipe-save-btn', { timeout: 5000 });
    await page.waitForSelector('.query-recipe-message.alert-danger', { timeout: 5000 });

    const errorMsg = await page.textContent('.query-recipe-message');
    assert.match(errorMsg, /Local storage is unavailable/, 'Storage unavailable message must be shown');

    // Page must remain responsive and usable
    await page.fill('#search_q', 'page_still_works', { timeout: 5000 });
    assert.strictEqual(await page.inputValue('#search_q'), 'page_still_works', 'Form must remain usable when storage fails');
    console.log('✓ Storage-unavailable handling passed');

    // -------------------------------------------------------------
    // Test 7: Keyboard save/reopen/delete with focus
    // -------------------------------------------------------------
    console.log('Testing 7: Keyboard accessibility and focus management...');
    // Fresh navigation to reset localStorage mocks
    await page.goto(`http://127.0.0.1:${port}/search`, { timeout: 10000 });

    // Focus trigger button and press Enter to open panel
    await page.focus('.query-recipe-trigger-btn', { timeout: 5000 });
    await page.keyboard.press('Enter');
    await page.waitForSelector('.query-recipe-panel:not(.d-none)', { timeout: 5000 });

    // Type recipe name via keyboard
    await page.focus('#recipe-name-search', { timeout: 5000 });
    await page.keyboard.type('Keyboard Accessible Recipe');
    await page.keyboard.press('Enter');

    // Wait for recipe in list
    await page.waitForSelector('.query-recipe-item', { timeout: 5000 });

    // Reopen via keyboard Enter on reopen button
    await page.focus('.query-recipe-reopen-btn', { timeout: 5000 });
    await page.keyboard.press('Enter');

    // Verify focus returned to trigger button
    let activeClass = await page.evaluate(() => document.activeElement.className);
    assert.match(activeClass, /query-recipe-trigger-btn/, 'Focus should return to trigger button after reopen');

    // Re-open panel via Enter
    await page.keyboard.press('Enter');
    await page.waitForSelector('.query-recipe-panel:not(.d-none)', { timeout: 5000 });

    // Delete recipe via keyboard
    await page.focus('.query-recipe-delete-btn', { timeout: 5000 });
    await page.keyboard.press('Enter');

    // Verify focus returned to trigger button
    activeClass = await page.evaluate(() => document.activeElement.className);
    assert.match(activeClass, /query-recipe-trigger-btn/, 'Focus should return to trigger button after delete');

    // Press Escape closes panel and focuses trigger
    await page.keyboard.press('Enter');
    await page.waitForSelector('.query-recipe-panel:not(.d-none)', { timeout: 5000 });
    await page.keyboard.press('Escape');
    await page.waitForSelector('.query-recipe-panel.d-none', { timeout: 5000 });
    activeClass = await page.evaluate(() => document.activeElement.className);
    assert.match(activeClass, /query-recipe-trigger-btn/, 'Focus should return to trigger button after Escape');

    console.log('✓ Keyboard accessibility and focus management passed');

    console.log('\nALL 7 ISOLATED QUERY RECIPE CHECKS PASSED.');
  } finally {
    if (browser) await browser.close();
    if (server) server.close();
  }
}

run().catch(err => {
  console.error('Test failed with error:', err);
  process.exit(1);
});
