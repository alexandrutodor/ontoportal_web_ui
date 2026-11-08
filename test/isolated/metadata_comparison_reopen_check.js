/**
 * test/isolated/metadata_comparison_reopen_check.js
 *
 * ONTO-AT-OP03: Playwright isolated test for reopening metadata comparison record.
 * Validates:
 * 1. esbuild-bundled Stimulus controller in headless Chrome.
 * 2. Reopening a valid package renders captured matrix values with ZERO outside network requests.
 * 3. Two same-acronym submissions remain distinct rows in rendered matrix.
 * 4. Missing/unavailable submission rendered as explicit unavailable row, not replaced by latest.
 * 5. Distinct presentation for ontology-level vs submission-level fields, empty, unknown, and unavailable.
 * 6. Malformed JSON and missing schema fields are rejected with an explicit error message.
 * 7. Zero page errors, explicit timeouts on all waits.
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

const page_html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Metadata Comparison Reopen Test</title>
  <style>
    .d-none { display: none !important; }
    .badge { display: inline-block; padding: 2px 5px; font-size: 11px; }
  </style>
</head>
<body>
  <div id="comparison-root"
       data-controller="metadata-comparison-record">
    <input type="file"
           data-metadata-comparison-record-target="fileInput"
           data-action="change->metadata-comparison-record#onFileChange"
           class="d-none">
    <div id="error-box"
         data-metadata-comparison-record-target="error"
         class="d-none"
         role="alert"></div>
    <div id="timestamp-box"
         data-metadata-comparison-record-target="timestamp"></div>
    <div id="summary-box"
         data-metadata-comparison-record-target="summary"></div>
    <div id="table-container"
         data-metadata-comparison-record-target="container"></div>
  </div>
</body>
</html>`;

const validPackage = {
  schema_version: '1.0.0',
  retrieval_timestamp: '2026-11-08T01:00:00Z',
  selection_criteria: {
    ontology: 'ONT',
    submission_ids: ['1', '2', '999'],
    properties: ['name', 'version', 'description', 'keywords', 'contact', 'empty_field']
  },
  properties: [
    { id: 'name', level: 'ontology', label: 'Name', note: 'current at capture' },
    { id: 'version', level: 'submission', label: 'Version', note: 'submission-level' },
    { id: 'description', level: 'submission', label: 'Description', note: 'submission-level' },
    { id: 'keywords', level: 'submission', label: 'Keywords', note: 'submission-level' },
    { id: 'contact', level: 'submission', label: 'Contact', note: 'submission-level' },
    { id: 'empty_field', level: 'submission', label: 'Empty Field', note: 'submission-level' }
  ],
  records: [
    {
      row_key: 'ONT#1',
      ontology_acronym: 'ONT',
      submission_id: '1',
      ontology_uri: 'http://data.example.org/ontologies/ONT',
      submission_uri: 'http://data.example.org/ontologies/ONT/submissions/1',
      status: 'available',
      error: null,
      version_identifier: '1.0.0',
      values: {
        name: { level: 'ontology', state: 'present', value: 'Ontology Test' },
        version: { level: 'submission', state: 'present', value: '1.0.0' },
        description: { level: 'submission', state: 'present', value: 'First submission text' },
        keywords: { level: 'submission', state: 'present', value: ['tag1', 'tag2, with comma', '日本語'] },
        contact: { level: 'submission', state: 'present', value: { '@value': 'Alice', '@language': 'fr' } },
        empty_field: { level: 'submission', state: 'empty', value: null }
      }
    },
    {
      row_key: 'ONT#2',
      ontology_acronym: 'ONT',
      submission_id: '2',
      ontology_uri: 'http://data.example.org/ontologies/ONT',
      submission_uri: 'http://data.example.org/ontologies/ONT/submissions/2',
      status: 'available',
      error: null,
      version_identifier: '1.0.0', // Same version label, distinct row
      values: {
        name: { level: 'ontology', state: 'present', value: 'Ontology Test' },
        version: { level: 'submission', state: 'unknown', value: null },
        description: { level: 'submission', state: 'present', value: 'Second submission text' },
        keywords: { level: 'submission', state: 'empty', value: [] },
        contact: { level: 'submission', state: 'empty', value: null },
        empty_field: { level: 'submission', state: 'empty', value: null }
      }
    },
    {
      row_key: 'ONT#999',
      ontology_acronym: 'ONT',
      submission_id: '999',
      ontology_uri: 'http://data.example.org/ontologies/ONT',
      submission_uri: null,
      status: 'unavailable',
      error: 'Submission 999 not found',
      version_identifier: null,
      values: {
        name: { level: 'ontology', state: 'unavailable', value: null },
        version: { level: 'submission', state: 'unavailable', value: null },
        description: { level: 'submission', state: 'unavailable', value: null },
        keywords: { level: 'submission', state: 'unavailable', value: null },
        contact: { level: 'submission', state: 'unavailable', value: null },
        empty_field: { level: 'submission', state: 'unavailable', value: null }
      }
    }
  ],
  unknowns: ['Submission 2 upstream version unknown', 'Submission 999 unavailable'],
  digest: {
    algorithm: 'SHA-256',
    value: 'dummy-digest',
    serialization: 'SHA-256 hex digest of canonical UTF-8 JSON serialization of {selection_criteria, properties, records}'
  }
};

(async () => {
  console.log('[metadata_comparison_reopen_check] Bundling Stimulus controller with esbuild...');
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const { Application } = require('@hotwired/stimulus');
        const Controller = require('../../app/javascript/controllers/metadata_comparison_record_controller.js').default;
        const app = window.__app = Application.start();
        window.__stimulusErrors = [];
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('metadata-comparison-record', Controller);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true,
    format: 'iife',
    write: false,
    platform: 'browser',
    logLevel: 'silent',
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  })).outputFiles[0].text;

  console.log('[metadata_comparison_reopen_check] Launching Chrome...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu']
  });

  const outside = [];
  const errors = [];

  try {
    const page = await browser.newPage();
    page.on('pageerror', e => errors.push(String(e)));

    await page.route('**/*', route => {
      if (route.request().url() === 'http://comparison.fixture/') {
        return route.fulfill({ contentType: 'text/html', body: page_html });
      }
      outside.push(route.request().url());
      return route.abort();
    });

    console.log('[metadata_comparison_reopen_check] Loading fixture page...');
    await page.goto('http://comparison.fixture/', { timeout: 10000 });
    await page.addScriptTag({ content: bundle });

    await page.waitForFunction(
      () => window.__app && window.__app.getControllerForElementAndIdentifier(document.getElementById('comparison-root'), 'metadata-comparison-record'),
      null,
      { timeout: 5000 }
    );

    console.log('[metadata_comparison_reopen_check] Test 1: Reopening valid package with ZERO network requests...');
    const outsideBefore = outside.length;

    await page.evaluate((pkg) => {
      const el = document.getElementById('comparison-root');
      const ctrl = window.__app.getControllerForElementAndIdentifier(el, 'metadata-comparison-record');
      ctrl.reopen(pkg);
    }, validPackage);

    // Wait for table to be populated
    await page.waitForSelector('tr[data-row-key="ONT#1"]', { timeout: 5000 });
    await page.waitForSelector('tr[data-row-key="ONT#2"]', { timeout: 5000 });
    await page.waitForSelector('tr[data-row-key="ONT#999"]', { timeout: 5000 });

    const outsideAfter = outside.length;
    assert.strictEqual(outsideAfter, outsideBefore, 'Reopening MUST make zero outside network requests');
    console.log('[metadata_comparison_reopen_check] Zero network requests verified.');

    // Verify row distinctness
    const rowKeys = await page.$$eval('tbody tr', trs => trs.map(tr => tr.getAttribute('data-row-key')));
    assert.deepStrictEqual(rowKeys, ['ONT#1', 'ONT#2', 'ONT#999'], 'Rows must contain ONT#1, ONT#2, and ONT#999');

    // Verify ontology level vs submission level badges
    const ontologyBadgeCount = await page.$$eval('.badge.bg-info', badges => badges.length);
    assert.ok(ontologyBadgeCount >= 1, 'Must render ontology-level header badge');
    const ontologyBadgeText = await page.$eval('.badge.bg-info', el => el.textContent.trim());
    assert.strictEqual(ontologyBadgeText, 'Ontology level (current at capture)');

    // Verify missing row is marked unavailable
    const missingRowClass = await page.$eval('tr[data-row-key="ONT#999"]', el => el.className);
    assert.ok(missingRowClass.includes('unavailable-row'), 'Missing row must have unavailable-row class');
    const missingBadgeText = await page.$eval('tr[data-row-key="ONT#999"] .badge.bg-danger', el => el.textContent.trim());
    assert.strictEqual(missingBadgeText, 'Unavailable', 'Missing row must display Unavailable badge');

    // Verify state distinctness in cells
    const emptyCells = await page.$$eval('.state-empty', els => els.length);
    assert.ok(emptyCells >= 1, 'Must render empty cells');

    const unknownCells = await page.$$eval('.state-unknown', els => els.length);
    assert.ok(unknownCells >= 1, 'Must render unknown cells');

    const unavailableCells = await page.$$eval('.state-unavailable', els => els.length);
    assert.ok(unavailableCells >= 1, 'Must render unavailable cells');

    // Verify structured values: array and language tag
    const descCell = await page.$eval('tr[data-row-key="ONT#1"] td[data-prop-id="description"]', el => el.textContent);
    assert.ok(descCell.includes('First submission text'), 'Description text rendered');

    const keywordsCell = await page.$eval('tr[data-row-key="ONT#1"] td[data-prop-id="keywords"]', el => el.innerHTML);
    assert.ok(keywordsCell.includes('tag1'), 'Array keyword rendered');
    assert.ok(keywordsCell.includes('tag2, with comma'), 'Array keyword with comma rendered');
    assert.ok(keywordsCell.includes('日本語'), 'Array keyword unicode rendered');

    const contactCell = await page.$eval('tr[data-row-key="ONT#1"] td[data-prop-id="contact"]', el => el.innerHTML);
    assert.ok(contactCell.includes('Alice'), 'Contact name rendered');
    assert.ok(contactCell.includes('(fr)'), 'Contact language tag rendered');

    const timestampText = await page.$eval('#timestamp-box', el => el.textContent);
    assert.ok(timestampText.includes('Reopened Local Snapshot'), 'Timestamp must indicate reopened snapshot');

    console.log('[metadata_comparison_reopen_check] Valid package reopening passed.');

    console.log('[metadata_comparison_reopen_check] Test 2: Reopen malformed JSON string...');
    await page.evaluate(() => {
      const el = document.getElementById('comparison-root');
      const ctrl = window.__app.getControllerForElementAndIdentifier(el, 'metadata-comparison-record');
      ctrl.reopenFromText('invalid json {');
    });

    await page.waitForFunction(
      () => {
        const err = document.getElementById('error-box');
        return err && !err.classList.contains('d-none') && err.textContent.includes('malformed JSON');
      },
      null,
      { timeout: 5000 }
    );
    console.log('[metadata_comparison_reopen_check] Malformed JSON rejection passed.');

    console.log('[metadata_comparison_reopen_check] Test 3: Reopen invalid schema (missing properties/records)...');
    await page.evaluate(() => {
      const el = document.getElementById('comparison-root');
      const ctrl = window.__app.getControllerForElementAndIdentifier(el, 'metadata-comparison-record');
      ctrl.reopen({ foo: 'bar' });
    });

    await page.waitForFunction(
      () => {
        const err = document.getElementById('error-box');
        return err && !err.classList.contains('d-none') && err.textContent.includes('missing required properties');
      },
      null,
      { timeout: 5000 }
    );
    console.log('[metadata_comparison_reopen_check] Missing schema rejection passed.');

    assert.deepStrictEqual(await page.evaluate(() => window.__stimulusErrors), [], 'No Stimulus errors');
    assert.deepStrictEqual(errors, [], 'No page errors');

    console.log(`[PASS] Metadata comparison reopen verified: 0 outside requests, 0 page errors.`);
  } finally {
    await browser.close();
  }
})().catch(e => {
  console.error('[FAIL] Metadata comparison reopen check failed:', e);
  process.exit(1);
});
