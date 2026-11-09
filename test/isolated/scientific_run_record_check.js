/**
 * test/isolated/scientific_run_record_check.js
 *
 * ONTO-AT-OP05: Validates the scientific run record Stimulus controller
 * in headless Chrome via Playwright:
 * 1. Download makes zero outside requests and uses captured data only.
 * 2. Import of an exact Unicode/whitespace record round-trips into the form without submitting.
 * 3. Malformed JSON, foreign-URL, credential, and unsupported-tool imports are rejected with a visible message and form intact.
 * 4. Zero outside requests throughout all operations.
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const path = require('path');
const fs = require('fs');

const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const ROOT_DIR = path.resolve(__dirname, '../..');

const UNICODE_SAMPLE_TEXT = "café crème\nα-globin\tβ-amyloid\n{pH: 7.4}";
const UNICODE_SAMPLE_SHA256 = "2a0e4f1432254df1ad22ae427f4207562cbb1a3462ee244e8db2175826aebf3a";

const CAPTURED_RECORD = {
  record_type: "scientific_run_record",
  schema_version: "1.0.0",
  tool: "annotator",
  source_portal: "matportal",
  timestamp: "2026-11-08T00:00:00Z",
  service_version: "unknown",
  settings: {
    selected: {
      ontologies: "ONT1,ONT2",
      whole_word_only: true,
      longest_only: true,
      class_hierarchy_max_level: "2",
      score: "cvalue"
    },
    effective: {
      ontologies: "ONT1",
      whole_word_only: true,
      longest_only: true,
      class_hierarchy_max_level: "2",
      score: "cvalue"
    }
  },
  input: {
    mode: "text",
    text: UNICODE_SAMPLE_TEXT,
    sha256: UNICODE_SAMPLE_SHA256,
    digest_serialization: "SHA-256 of raw UTF-8 input text bytes",
    byte_size: 47,
    char_count: 38
  },
  captured_result: {
    representation: "ui_snapshot",
    count: 1,
    items: [
      {
        class_label: "Graphene",
        ontology_version: "unknown",
        service_version: "unknown",
        score: 12.34
      }
    ]
  }
};

const HTML_FIXTURE = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Scientific Run Record Test Fixture</title>
  <style>
    .d-none { display: none !important; }
    .alert { padding: 8px; margin: 4px 0; }
    .alert-danger { background: #f8d7da; color: #721c24; }
    .alert-success { background: #d4edda; color: #155724; }
    .alert-info { background: #d1ecf1; color: #0c5460; }
  </style>
</head>
<body>
  <form id="annotator-form" action="/annotator" method="get">
    <textarea name="text" id="text-area">initial text</textarea>
    <input type="checkbox" name="whole_word_only" id="whole_word_only">
    <input type="checkbox" name="longest_only" id="longest_only">
    <select name="class_hierarchy_max_level" id="class_hierarchy_max_level">
      <option value="None" selected>None</option>
      <option value="1">1</option>
      <option value="2">2</option>
      <option value="All">All</option>
    </select>
    <select name="score" id="score">
      <option value="none" selected>none</option>
      <option value="old">old</option>
      <option value="cvalue">cvalue</option>
    </select>
    <select name="ontologies[]" id="ontologies" multiple>
      <option value="ONT1">ONT1</option>
      <option value="ONT2">ONT2</option>
      <option value="ONT3">ONT3</option>
    </select>
    <button type="submit" id="submit-btn">Run Annotator</button>
  </form>

  <div class="scientific-run-record-container"
       data-controller="scientific-run-record"
       data-scientific-run-record-tool-value="annotator"
       data-scientific-run-record-form-selector-value="#annotator-form">
    <div class="scientific-run-record-status d-none" data-scientific-run-record-target="status" role="status"></div>
    <input type="file" id="file-input" class="d-none" data-scientific-run-record-target="fileInput" data-action="change->scientific-run-record#importFile">
    <button type="button" id="import-btn" data-action="click->scientific-run-record#triggerImport" data-scientific-run-record-target="importBtn">Import Record</button>
    <div class="scientific-run-record-export">
      <button type="button" id="download-btn" data-action="click->scientific-run-record#downloadRecord" data-scientific-run-record-target="downloadBtn">Download Record</button>
      <label>
        <input type="checkbox" id="include-text-cb" data-scientific-run-record-target="includeInputText">
        Include input text
      </label>
      <label>
        <input type="checkbox" id="include-results-cb" checked data-scientific-run-record-target="includeResults">
        Include captured results
      </label>
      <div class="settings-only-note" data-scientific-run-record-target="settingsNote">Settings-only record requires the original input to rerun.</div>
      <script type="application/json" data-scientific-run-record-target="recordPayload">${JSON.stringify(CAPTURED_RECORD)}</script>
    </div>
  </div>

  <script>
    window.__formSubmits = 0;
    document.getElementById('annotator-form').addEventListener('submit', function(e) {
      e.preventDefault();
      window.__formSubmits++;
    });
  </script>
</body>
</html>`;

(async () => {
  console.log('[scientific_run_record_check] Bundling Stimulus controller with esbuild...');
  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const { Application } = require('@hotwired/stimulus');
        const ScientificRunRecordController = require('${path.join(ROOT_DIR, 'app/javascript/controllers/scientific_run_record_controller.js')}').default;
        window.__stimulusErrors = [];
        const app = window.__app = Application.start();
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('scientific-run-record', ScientificRunRecordController);
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

  console.log('[scientific_run_record_check] Launching Chrome...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true
  });

  const pageErrors = [];
  const outsideRequests = [];

  try {
    const page = await browser.newPage({ viewport: { width: 1024, height: 768 } });
    page.on('pageerror', err => pageErrors.push(String(err)));

    // Route interceptor: only fulfill local fixture, capture any outside requests
    await page.route('**/*', async (route) => {
      const url = route.request().url();
      if (url === 'http://localhost.test/fixture') {
        return route.fulfill({
          status: 200,
          contentType: 'text/html',
          body: HTML_FIXTURE
        });
      }
      outsideRequests.push(url);
      return route.abort();
    });

    console.log('[scientific_run_record_check] Loading test fixture...');
    await page.goto('http://localhost.test/fixture', { waitUntil: 'load', timeout: 10000 });
    await page.addScriptTag({ content: bundle });
    await page.waitForFunction(() => window.__app && window.__app.controllers && window.__app.controllers.length > 0, { timeout: 10000 });
    console.log('[scientific_run_record_check] Controller connected.');

    // =========================================================================
    // Test 1: Download makes zero outside requests and uses captured data only
    // =========================================================================
    console.log('[scientific_run_record_check] Test 1: Testing download (settings-only default)...');
    const requestsBeforeDownload = outsideRequests.length;

    const [downloadEvent] = await Promise.all([
      page.waitForEvent('download', { timeout: 10000 }),
      page.click('#download-btn', { timeout: 5000 })
    ]);

    assert.equal(outsideRequests.length, requestsBeforeDownload, 'Download must make zero outside requests');

    const downloadStream = await downloadEvent.createReadStream();
    const downloadChunks = [];
    for await (const chunk of downloadStream) {
      downloadChunks.push(chunk);
    }
    const downloadedJson1 = JSON.parse(Buffer.concat(downloadChunks).toString('utf-8'));

    assert.equal(downloadedJson1.tool, 'annotator');
    assert.equal(downloadedJson1.schema_version, '1.0.0');
    assert.equal(downloadedJson1.input.mode, 'digest');
    assert.equal(downloadedJson1.input.text, undefined, 'Default settings-only download must omit raw input text');
    assert.equal(downloadedJson1.input.sha256, UNICODE_SAMPLE_SHA256, 'Digest must match input text');
    assert.ok(downloadedJson1.captured_result, 'Captured result included by default');

    // Download with include input text checked
    console.log('[scientific_run_record_check] Test 1b: Testing download with input text included...');
    await page.check('#include-text-cb', { timeout: 5000 });
    const [downloadEvent2] = await Promise.all([
      page.waitForEvent('download', { timeout: 10000 }),
      page.click('#download-btn', { timeout: 5000 })
    ]);
    assert.equal(outsideRequests.length, requestsBeforeDownload, 'Full download must make zero outside requests');

    const downloadStream2 = await downloadEvent2.createReadStream();
    const downloadChunks2 = [];
    for await (const chunk of downloadStream2) {
      downloadChunks2.push(chunk);
    }
    const downloadedJson2 = JSON.parse(Buffer.concat(downloadChunks2).toString('utf-8'));
    assert.equal(downloadedJson2.input.mode, 'text');
    assert.equal(downloadedJson2.input.text, UNICODE_SAMPLE_TEXT, 'Exact Unicode and whitespace must be preserved in export');
    console.log('[scientific_run_record_check] Download tests passed with 0 outside requests.');

    // =========================================================================
    // Test 2: Import of exact Unicode/whitespace record populates form without submitting
    // =========================================================================
    console.log('[scientific_run_record_check] Test 2: Testing valid record import with exact Unicode/whitespace...');
    const formSubmitsBefore = await page.evaluate(() => window.__formSubmits);

    const importRecordValid = {
      record_type: "scientific_run_record",
      schema_version: "1.0.0",
      tool: "annotator",
      settings: {
        selected: {
          ontologies: "ONT1,ONT2",
          whole_word_only: true,
          longest_only: true,
          class_hierarchy_max_level: "2",
          score: "cvalue"
        }
      },
      input: {
        mode: "text",
        text: UNICODE_SAMPLE_TEXT,
        sha256: UNICODE_SAMPLE_SHA256
      }
    };

    await page.setInputFiles('#file-input', {
      name: 'run-record.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(importRecordValid), 'utf-8')
    });

    await page.waitForFunction(() => {
      const status = document.querySelector('.scientific-run-record-status');
      return status && !status.classList.contains('d-none') && status.classList.contains('alert-success');
    }, { timeout: 5000 });

    const formSubmitsAfter = await page.evaluate(() => window.__formSubmits);
    assert.equal(formSubmitsAfter, formSubmitsBefore, 'Import must NOT submit the form');

    // Verify populated values
    const formValues = await page.evaluate(() => ({
      text: document.getElementById('text-area').value,
      whole_word_only: document.getElementById('whole_word_only').checked,
      longest_only: document.getElementById('longest_only').checked,
      class_hierarchy_max_level: document.getElementById('class_hierarchy_max_level').value,
      score: document.getElementById('score').value,
      ontologies: Array.from(document.getElementById('ontologies').selectedOptions).map(o => o.value)
    }));

    assert.equal(formValues.text, UNICODE_SAMPLE_TEXT, 'Exact Unicode & whitespace must round-trip into textarea');
    assert.equal(formValues.whole_word_only, true, 'whole_word_only checkbox must be checked');
    assert.equal(formValues.longest_only, true, 'longest_only checkbox must be checked');
    assert.equal(formValues.class_hierarchy_max_level, '2', 'class_hierarchy_max_level select must be 2');
    assert.equal(formValues.score, 'cvalue', 'score select must be cvalue');
    assert.deepEqual(formValues.ontologies, ['ONT1', 'ONT2'], 'ontologies select must have ONT1 and ONT2 selected');
    console.log('[scientific_run_record_check] Valid import round-trip passed.');

    // =========================================================================
    // Test 3: Malformed JSON rejected, form intact
    // =========================================================================
    console.log('[scientific_run_record_check] Test 3: Testing rejection of malformed JSON...');
    await page.setInputFiles('#file-input', {
      name: 'malformed.json',
      mimeType: 'application/json',
      buffer: Buffer.from('{not valid json string', 'utf-8')
    });

    await page.waitForFunction(() => {
      const status = document.querySelector('.scientific-run-record-status');
      return status && status.classList.contains('alert-danger') && status.textContent.includes('Invalid record');
    }, { timeout: 5000 });

    const textAfterBadJson = await page.$eval('#text-area', el => el.value);
    assert.equal(textAfterBadJson, UNICODE_SAMPLE_TEXT, 'Form text must remain intact on malformed JSON rejection');
    console.log('[scientific_run_record_check] Malformed JSON rejection passed.');

    // =========================================================================
    // Test 4: Foreign endpoint URL rejected, form intact
    // =========================================================================
    console.log('[scientific_run_record_check] Test 4: Testing rejection of foreign endpoint URLs...');
    const foreignUrlRecord = {
      schema_version: "1.0.0",
      tool: "annotator",
      settings: {
        selected: {
          ontologies: "http://malicious.evil.com/leak"
        }
      }
    };

    await page.setInputFiles('#file-input', {
      name: 'foreign-url.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(foreignUrlRecord), 'utf-8')
    });

    await page.waitForFunction(() => {
      const status = document.querySelector('.scientific-run-record-status');
      return status && status.classList.contains('alert-danger') && status.textContent.includes('foreign endpoint URLs');
    }, { timeout: 5000 });

    const textAfterForeignUrl = await page.$eval('#text-area', el => el.value);
    assert.equal(textAfterForeignUrl, UNICODE_SAMPLE_TEXT, 'Form text must remain intact on foreign URL rejection');
    console.log('[scientific_run_record_check] Foreign URL rejection passed.');

    // =========================================================================
    // Test 5: Credential fields rejected, form intact
    // =========================================================================
    console.log('[scientific_run_record_check] Test 5: Testing rejection of credential fields...');
    const credRecord = {
      schema_version: "1.0.0",
      tool: "annotator",
      settings: {
        selected: {
          apikey: "super-secret-token"
        }
      }
    };

    await page.setInputFiles('#file-input', {
      name: 'credentials.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(credRecord), 'utf-8')
    });

    await page.waitForFunction(() => {
      const status = document.querySelector('.scientific-run-record-status');
      return status && status.classList.contains('alert-danger') && status.textContent.includes('credential');
    }, { timeout: 5000 });

    const textAfterCred = await page.$eval('#text-area', el => el.value);
    assert.equal(textAfterCred, UNICODE_SAMPLE_TEXT, 'Form text must remain intact on credential rejection');
    console.log('[scientific_run_record_check] Credential rejection passed.');

    // =========================================================================
    // Test 6: Unsupported tool rejected, form intact
    // =========================================================================
    console.log('[scientific_run_record_check] Test 6: Testing rejection of unsupported tool...');
    const wrongToolRecord = {
      schema_version: "1.0.0",
      tool: "recommender",
      settings: { selected: {} }
    };

    await page.setInputFiles('#file-input', {
      name: 'wrong-tool.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(wrongToolRecord), 'utf-8')
    });

    await page.waitForFunction(() => {
      const status = document.querySelector('.scientific-run-record-status');
      return status && status.classList.contains('alert-danger') && status.textContent.includes('Unsupported tool');
    }, { timeout: 5000 });

    const textAfterWrongTool = await page.$eval('#text-area', el => el.value);
    assert.equal(textAfterWrongTool, UNICODE_SAMPLE_TEXT, 'Form text must remain intact on unsupported tool rejection');
    console.log('[scientific_run_record_check] Unsupported tool rejection passed.');

    // =========================================================================
    // Test 7: Verify zero outside requests made throughout
    // =========================================================================
    assert.equal(outsideRequests.length, 0, `Zero outside requests must be made, but found: ${JSON.stringify(outsideRequests)}`);
    assert.equal(pageErrors.length, 0, `Zero page errors expected, but found: ${pageErrors.join(', ')}`);

    console.log('\n[PASS] All scientific run record browser criteria verified successfully.');
  } finally {
    await browser.close();
  }
})().catch(err => {
  console.error('[FAIL] Check failed:', err);
  process.exit(1);
});
