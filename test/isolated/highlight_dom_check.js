/**
 * test/isolated/highlight_dom_check.js
 *
 * Isolated real-browser DOM test for Recommender and Annotator highlighted rendering (ONTO-T-J02).
 * Verifies safe text/DOM/URL binding, inert metacharacter rendering, scheme filtering,
 * repeated radio toggling without text loss, and annotator context slicing.
 *
 * Requirements:
 * - Native Ruby producer executed under onto-q02-proof:af254f34 (docker --network none).
 * - ESBuild bundled Stimulus controllers (recommender & annotator) registered on real Stimulus application.
 * - Real headless Chromium via Playwright.
 * - Zero network requests asserted independently.
 * - browser.close in finally.
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const path = require('path');
const assert = require('assert');
const { execSync } = require('child_process');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const DOCKER_IMAGE = 'onto-q02-proof:af254f34';

function runNativeRubyProducer() {
  console.log('[1/5] Running native Ruby Haml fragment producer in Docker container...');
  const rubyScript = `
$LOAD_PATH.unshift "/app"
require "logger"
require "active_support/all"
require "rails"
require "rails/version"
require "action_controller"
require "action_view"
require "view_component"
require "haml"
require "haml/template"
require "json"

module Input; end
require "app/components/input/radio_chip_component"

lookup_context = ActionView::LookupContext.new(["/app/app/components", "/app/app/views"])
view_context = ActionView::Base.with_empty_template_cache.new(lookup_context, {}, ActionController::Base.new)

haml_content = File.read("/app/app/views/recommender/index.html.haml")
lines = haml_content.lines
start_idx = lines.find_index { |l| l.include?("recommender-result-highlighted") }
extracted = lines[start_idx..start_idx+1].map { |l| l.sub(/^\\s{18}/, "") }.join

results = [
  {
    annotations: [
      { text: "melanoma", link: "/ontologies/NCIT?q=melanoma#overview" },
      { text: "carcinoma", link: "https://example.org/ontologies/DOID?view=class&id=123#sec%201" },
      { text: "skin", link: "http://example.org/ontologies/UBERON#frag?a=1&b=2" },
      { text: "<script>alert('xss')</script>", link: "/ontologies/TEST?id=xss" },
      { text: "quote\\\"&angle<>'|pipe", link: "/ontologies/SPECIAL" },
      { text: "weird=>payload:text", link: "/ontologies/WEIRD" },
      { text: "backslash\\\\test", link: "/ontologies/BACKSLASH" },
      { text: "ünicöde_térm", link: "/ontologies/UNICODE" },
      { text: "executable", link: "javascript:window.__xssTriggered.push('recommender_js')" },
      { text: "dataexploit", link: "data:text/html,<script>window.__xssTriggered.push('recommender_data')</script>" },
      { text: "vbscriptexploit", link: "vbscript:msgbox(1)" },
      { text: "protorelative", link: "//attacker.example.com/evil" }
    ],
    highlighted: true
  },
  {
    annotations: [
      { text: "paragraph", link: "/ontologies/PARA#p1" },
      { text: "spaces", link: "/ontologies/SPACES#sp" }
    ],
    highlighted: false
  }
]

template = ActionView::Template.new(
  extracted,
  "recommender_producer_fragment",
  Haml::Plugin,
  locals: [:result]
)

rendered = results.map { |res| template.render(view_context, { result: res }) }
puts JSON.generate(rendered)
`;

  const cmd = `docker run --rm --network none -v "${ROOT_DIR}:/app:ro" -w /app -e GEM_PATH=/usr/local/bundle/ruby/3.1.0 ${DOCKER_IMAGE} ruby -e '${rubyScript.replace(/'/g, "'\\''")}'`;
  const rawOutput = execSync(cmd, { encoding: 'utf8' }).trim();
  const renderedRadios = JSON.parse(rawOutput);
  console.log(`      Rendered ${renderedRadios.length} radio fragments successfully.`);
  return renderedRadios;
}

async function buildControllerBundle() {
  console.log('[2/5] Building production Stimulus bundle with esbuild...');
  const result = await esbuild.build({
    stdin: {
      contents: `
        import { Application } from "@hotwired/stimulus";
        import RecommenderController from "./app/javascript/controllers/recommender_controller.js";
        import AnnotatorController from "./app/javascript/controllers/annotator_controller.js";

        window.__stimulusErrors = [];
        window.StimulusApp = Application.start();
        const defaultHandleError = window.StimulusApp.handleError.bind(window.StimulusApp);
        window.StimulusApp.handleError = (error, message, detail) => {
          window.__stimulusErrors.push({
            message: message || (error && error.message) || String(error),
            error: (error && error.stack) ? error.stack : String(error),
            detail
          });
          defaultHandleError(error, message, detail);
        };
        window.StimulusApp.register("recommender", RecommenderController);
        window.StimulusApp.register("annotator", AnnotatorController);
        window.__controllersReady = true;
      `,
      resolveDir: ROOT_DIR
    },
    bundle: true,
    format: 'iife',
    write: false,
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  });
  console.log(`      Bundle size: ${result.outputFiles[0].text.length} bytes`);
  return result.outputFiles[0].text;
}

function generateHtmlFixture(renderedRadios) {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <base href="http://localhost:3000/">
  <title>Highlight DOM Isolated Check</title>
  <style>
    .d-none { display: none !important; }
    .highlighted-annotation { background: yellow; }
  </style>
  <script>
    window.__xssTriggered = [];
  </script>
</head>
<body>
  <!-- Recommender container -->
  <div id="recommender-fixture" data-controller="recommender">
    <div data-recommender-target="ontologieschoice">
      <label class="radio output_type">
        <input type="radio" name="output_type" value="1" checked>
        <span class="text">Ontologies</span>
        <span></span>
      </label>
    </div>
    <div data-recommender-target="button" class="d-none"></div>
    <div data-recommender-target="input" class="d-none"></div>
    <div data-recommender-target="maxset" class="d-none"></div>
    <div data-recommender-target="empty" class="d-none"></div>

    <!-- resultTarget contains markup-shaped strings, newlines, quotes, unicode, pipes, etc. as rendered by Rails Haml -->
    <div id="recommender-result" data-recommender-target="result">Patient has melanoma and carcinoma on skin.
Payloads: weird=&gt;payload:text and backslash\\test and ünicöde_térm.
Special: quote"&amp;angle&lt;&gt;'|pipe and &lt;script&gt;alert('xss')&lt;/script&gt;.
Schemes: executable and data_exploit and vbscript_exploit and proto_relative.
Multi-line:
First paragraph.

Second paragraph   with   spaces.</div>

    <div id="recommender-radios-container">
      ${renderedRadios[0]}
      ${renderedRadios[1]}
    </div>
  </div>

  <!-- Annotator container -->
  <div id="annotator-fixture" data-controller="annotator">
    <textarea data-annotator-target="input">The quick brown fox jumps over the lazy dog. In malignant melanoma diagnosis, <img src=x onerror=window.__xssTriggered.push('annotator_xss')> and <b>bold&quotes"</b> appear in clinical notes.</textarea>

    <!-- Context 1: Beginning of text (from 1 to 9: "The quick") -->
    <div id="annotator-ctx-beginning" class="annotation-context" data-from="1" data-to="9" data-annotator-target="context"></div>

    <!-- Context 2: Middle of text (from 49 to 66: "malignant melanoma") -->
    <div id="annotator-ctx-middle" class="annotation-context" data-from="49" data-to="66" data-annotator-target="context"></div>

    <!-- Context 3: Markup-shaped injection in text (from 79 to 140) -->
    <div id="annotator-ctx-markup" class="annotation-context" data-from="79" data-to="140" data-annotator-target="context"></div>

    <!-- Context 4: End of text (from 173 to 187: "clinical notes.") -->
    <div id="annotator-ctx-end" class="annotation-context" data-from="173" data-to="187" data-annotator-target="context"></div>
  </div>
</body>
</html>`;
}

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

  const renderedRadios = runNativeRubyProducer();
  const bundleJs = await buildControllerBundle();

  console.log('[3/5] Launching isolated headless Chromium browser...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true
  });

  try {
    const context = await browser.newContext({
      javaScriptEnabled: true
    });

    const recordedRequests = [];
    context.on('request', (req) => {
      recordedRequests.push(req.url());
    });
    await context.route('**', (route) => {
      route.abort();
    });

    const page = await context.newPage();
    const pageErrors = [];
    page.on('pageerror', (err) => {
      pageErrors.push(err.message || String(err));
    });

    console.log('[4/5] Setting up page content and injecting bundle...');
    const htmlFixture = generateHtmlFixture(renderedRadios);
    await page.setContent(htmlFixture);
    await page.addScriptTag({ content: bundleJs });

    const ready = await page.evaluate(() => window.__controllersReady);
    assert.strictEqual(ready, true, 'Stimulus controllers failed to initialize');
    await page.waitForTimeout(100);

    console.log('[5/5] Executing test assertions...');

    // 1. Ruby Producer verification
    {
      const radioValues = await page.evaluate(() => {
        const inputs = Array.from(document.querySelectorAll('input[name="highlighted_recommendation"]'));
        return inputs.map(i => ({ value: i.value, checked: i.checked }));
      });
      const parsedRadio0 = JSON.parse(radioValues[0].value);
      record('Radio 0 generated by native Ruby Haml producer contains valid JSON array',
        radioValues.length === 2 && Array.isArray(parsedRadio0),
        `Count: ${radioValues.length}`
      );
      const weirdItem = parsedRadio0.find(item => item.text === 'weird=>payload:text');
      const backslashItem = parsedRadio0.find(item => item.text && item.text.includes('backslash'));
      record('Radio 0 preserves => and :text payloads and escaped characters exactly',
        weirdItem && backslashItem && backslashItem.text === 'backslash\\test',
        `weirdItem: ${JSON.stringify(weirdItem)}, backslashItem: ${JSON.stringify(backslashItem)}`
      );
    }

    // 2. Recommender Safe Highlighting & URL resolution
    {
      const links = await page.evaluate(() => {
        const aTags = Array.from(document.querySelectorAll('#recommender-result a'));
        return aTags.map(a => ({
          text: a.textContent,
          attrHref: a.getAttribute('href'),
          propHref: a.href,
          style: a.getAttribute('style')
        }));
      });

      const melanomaLink = links.find(l => l.text === 'melanoma');
      const carcinomaLink = links.find(l => l.text === 'carcinoma');
      const skinLink = links.find(l => l.text === 'skin.');

      record('Recommender highlights safe relative URL resolved via baseURI',
        melanomaLink && melanomaLink.attrHref === '/ontologies/NCIT?q=melanoma#overview' && melanomaLink.propHref === 'http://localhost:3000/ontologies/NCIT?q=melanoma#overview',
        `melanomaLink: ${JSON.stringify(melanomaLink)}`
      );

      record('Recommender highlights safe absolute HTTPS URL preserving encoded query/fragment',
        carcinomaLink && carcinomaLink.attrHref === 'https://example.org/ontologies/DOID?view=class&id=123#sec%201' && carcinomaLink.propHref.includes('#sec%201'),
        `carcinomaLink: ${JSON.stringify(carcinomaLink)}`
      );

      record('Recommender highlights safe absolute HTTP URL with primary color style',
        skinLink && skinLink.attrHref === 'http://example.org/ontologies/UBERON#frag?a=1&b=2' && skinLink.style.includes('color:var(--primary-color) !important'),
        `skinLink: ${JSON.stringify(skinLink)}`
      );
    }

    // 3. Recommender Scheme Rejection & Disallowed URLs
    {
      // Safe-URL positive control: verify that all 3 canonical normalized matching terms highlight when links are safe
      const positiveControl = await page.evaluate(() => {
        const radio = document.querySelector('input[name="highlighted_recommendation"]');
        const originalValue = radio.value;
        const annotations = JSON.parse(originalValue);
        const safeAnnotations = annotations.map(item => {
          if (item && item.text === 'dataexploit') return { ...item, link: 'https://example.org/ontologies/DATA_EXPLOIT' };
          if (item && item.text === 'vbscriptexploit') return { ...item, link: 'https://example.org/ontologies/VBSCRIPT_EXPLOIT' };
          if (item && item.text === 'protorelative') return { ...item, link: 'https://example.org/ontologies/PROTO_RELATIVE' };
          return item;
        });
        radio.value = JSON.stringify(safeAnnotations);
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(
          document.getElementById('recommender-fixture'),
          'recommender'
        );
        ctrl.handleHighlightedChange();

        const resultEl = document.getElementById('recommender-result');
        const anchors = Array.from(resultEl.querySelectorAll('a')).map(a => ({
          text: a.textContent,
          href: a.getAttribute('href')
        }));

        const dataAnchor = anchors.find(a => a.text === 'data_exploit');
        const vbAnchor = anchors.find(a => a.text === 'vbscript_exploit');
        const protoAnchor = anchors.find(a => a.text === 'proto_relative.');

        const allThreeHighlighted = Boolean(
          dataAnchor && dataAnchor.href === 'https://example.org/ontologies/DATA_EXPLOIT' &&
          vbAnchor && vbAnchor.href === 'https://example.org/ontologies/VBSCRIPT_EXPLOIT' &&
          protoAnchor && protoAnchor.href === 'https://example.org/ontologies/PROTO_RELATIVE'
        );

        // Restore disallowed links and verify rejection
        radio.value = originalValue;
        ctrl.handleHighlightedChange();

        const restoredAnchors = Array.from(resultEl.querySelectorAll('a')).map(a => ({
          text: a.textContent,
          href: a.getAttribute('href')
        }));
        const hrefs = restoredAnchors.map(a => a.href);
        const texts = restoredAnchors.map(a => a.text);

        return {
          allThreeHighlighted,
          dataExploitHighlighted: Boolean(dataAnchor),
          vbscriptExploitHighlighted: Boolean(vbAnchor),
          protoRelativeHighlighted: Boolean(protoAnchor),
          hasJavascript: hrefs.some(h => h.startsWith('javascript:')),
          hasData: hrefs.some(h => h.startsWith('data:')),
          hasVbscript: hrefs.some(h => h.startsWith('vbscript:')),
          hasProtoRelative: hrefs.some(h => h.startsWith('//')),
          hasExecutableAnchor: texts.includes('executable'),
          hasDataAnchor: texts.includes('data_exploit'),
          hasVbAnchor: texts.includes('vbscript_exploit'),
          hasProtoAnchor: texts.includes('proto_relative.'),
          executableText: resultEl.textContent.includes('executable'),
          dataText: resultEl.textContent.includes('data_exploit'),
          vbText: resultEl.textContent.includes('vbscript_exploit'),
          protoText: resultEl.textContent.includes('proto_relative')
        };
      });

      record('Recommender highlights safe-URL positive control for all three canonical matching terms',
        positiveControl.allThreeHighlighted,
        `data_exploit: ${positiveControl.dataExploitHighlighted}, vbscript_exploit: ${positiveControl.vbscriptExploitHighlighted}, proto_relative: ${positiveControl.protoRelativeHighlighted}`
      );

      record('Recommender rejects javascript: scheme and falls back to plain text',
        !positiveControl.hasJavascript && !positiveControl.hasExecutableAnchor && positiveControl.executableText,
        `hasJavascript: ${positiveControl.hasJavascript}, hasAnchor: ${positiveControl.hasExecutableAnchor}`
      );

      record('Recommender rejects data: scheme and falls back to plain text',
        !positiveControl.hasData && !positiveControl.hasDataAnchor && positiveControl.dataText,
        `hasData: ${positiveControl.hasData}, hasAnchor: ${positiveControl.hasDataAnchor}`
      );

      record('Recommender rejects vbscript: scheme and falls back to plain text',
        !positiveControl.hasVbscript && !positiveControl.hasVbAnchor && positiveControl.vbText,
        `hasVbscript: ${positiveControl.hasVbscript}, hasAnchor: ${positiveControl.hasVbAnchor}`
      );

      record('Recommender rejects protocol-relative // URLs and falls back to plain text',
        !positiveControl.hasProtoRelative && !positiveControl.hasProtoAnchor && positiveControl.protoText,
        `hasProtoRelative: ${positiveControl.hasProtoRelative}, hasAnchor: ${positiveControl.hasProtoAnchor}`
      );
    }

    // 4. Recommender Inert Markup-Shaped Text & Metacharacters
    {
      const domSafety = await page.evaluate(() => {
        const resultEl = document.getElementById('recommender-result');
        return {
          scriptElementsInside: resultEl.querySelectorAll('script').length,
          allElementsInside: Array.from(resultEl.children).map(c => c.tagName.toLowerCase()),
          containsRawScriptText: resultEl.textContent.includes("<script>alert('xss')</script>"),
          containsSpecialPayloads: resultEl.textContent.includes('quote"&angle<>\'|pipe') &&
                                   resultEl.textContent.includes('weird=>payload:text') &&
                                   resultEl.textContent.includes('backslash\\test') &&
                                   resultEl.textContent.includes('ünicöde_térm')
        };
      });

      record('Recommender does not create DOM elements for inert markup-shaped text',
        domSafety.scriptElementsInside === 0 && domSafety.allElementsInside.every(tag => tag === 'a'),
        `Tags: ${domSafety.allElementsInside.join(', ')}`
      );

      record('Recommender preserves exact literal text for markup, quotes, angles, pipes, backslashes, Unicode',
        domSafety.containsRawScriptText && domSafety.containsSpecialPayloads,
        `containsRawScriptText: ${domSafety.containsRawScriptText}`
      );
    }

    // 5. Recommender Repeat / Radio-Change without Text Loss
    {
      const textBefore = await page.evaluate(() => document.getElementById('recommender-result').textContent);

      // Click radio 1
      await page.evaluate(() => {
        const radios = document.querySelectorAll('input[name="highlighted_recommendation"]');
        radios[1].checked = true;
        radios[1].dispatchEvent(new Event('change', { bubbles: true }));
      });
      await page.waitForTimeout(50);

      const stateAfterRadio1 = await page.evaluate(() => {
        const resultEl = document.getElementById('recommender-result');
        const anchors = Array.from(resultEl.querySelectorAll('a')).map(a => ({
          text: a.textContent,
          href: a.getAttribute('href')
        }));
        return {
          textContent: resultEl.textContent,
          anchors
        };
      });

      record('Radio change highlights newly selected terms (paragraph, spaces)',
        stateAfterRadio1.anchors.some(a => a.text === 'paragraph.') &&
        stateAfterRadio1.anchors.some(a => a.text === 'spaces.'),
        `Anchors: ${JSON.stringify(stateAfterRadio1.anchors)}`
      );

      record('Radio change preserves exact textContent without losing newlines or whitespace',
        stateAfterRadio1.textContent === textBefore &&
        stateAfterRadio1.textContent.includes('\n\nSecond paragraph   with   spaces.'),
        `Equal length: ${stateAfterRadio1.textContent.length === textBefore.length}`
      );

      // Switch back to radio 0
      await page.evaluate(() => {
        const radios = document.querySelectorAll('input[name="highlighted_recommendation"]');
        radios[0].checked = true;
        radios[0].dispatchEvent(new Event('change', { bubbles: true }));
      });
      await page.waitForTimeout(50);

      const stateAfterSwitchBack = await page.evaluate(() => {
        const resultEl = document.getElementById('recommender-result');
        return resultEl.textContent;
      });

      record('Switching back to original radio preserves exact textContent without corruption',
        stateAfterSwitchBack === textBefore,
        `Lengths: ${stateAfterSwitchBack.length} vs ${textBefore.length}`
      );
    }

    // 6. Recommender Invalid / Non-array JSON Tolerance
    {
      const invalidJsonHandled = await page.evaluate(() => {
        const resultEl = document.getElementById('recommender-result');
        const originalText = resultEl.textContent;
        const radio = document.querySelector('input[name="highlighted_recommendation"]');

        // Test 1: Invalid syntax JSON
        radio.value = 'invalid{json:format';
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(
          document.getElementById('recommender-fixture'),
          'recommender'
        );
        ctrl.handleHighlightedChange();
        const textAfterInvalid = resultEl.textContent;
        const noLinksAfterInvalid = resultEl.querySelectorAll('a').length === 0;

        // Test 2: JSON Object (non-array)
        radio.value = JSON.stringify({ not: 'an array' });
        ctrl.handleHighlightedChange();
        const textAfterNonArray = resultEl.textContent;

        return {
          textPreserved1: textAfterInvalid === originalText,
          noLinksAfterInvalid,
          textPreserved2: textAfterNonArray === originalText
        };
      });

      record('Recommender gracefully handles invalid syntax JSON without error or data loss',
        invalidJsonHandled.textPreserved1 && invalidJsonHandled.noLinksAfterInvalid,
        `textPreserved1: ${invalidJsonHandled.textPreserved1}`
      );

      record('Recommender gracefully handles non-array JSON object without error or data loss',
        invalidJsonHandled.textPreserved2,
        `textPreserved2: ${invalidJsonHandled.textPreserved2}`
      );
    }

    // 7. Annotator Context DOM Construction: Beginning of text
    {
      const ctxBeginning = await page.evaluate(() => {
        const el = document.getElementById('annotator-ctx-beginning');
        const nodes = Array.from(el.childNodes).map(n => ({
          type: n.nodeType,
          nodeName: n.nodeName,
          textContent: n.textContent,
          className: n.className
        }));
        return {
          childCount: el.childNodes.length,
          nodes,
          span: el.querySelector('span.highlighted-annotation')?.textContent
        };
      });

      record('Annotator beginning context omits leading ellipsis and highlights first words',
        ctxBeginning.span === ' The quick ' &&
        ctxBeginning.nodes[0].nodeName === 'SPAN' &&
        ctxBeginning.nodes[1].type === 3 && ctxBeginning.nodes[1].textContent.endsWith(' ...'),
        `Nodes: ${JSON.stringify(ctxBeginning.nodes)}`
      );
    }

    // 8. Annotator Context DOM Construction: Middle of text
    {
      const ctxMiddle = await page.evaluate(() => {
        const el = document.getElementById('annotator-ctx-middle');
        const nodes = Array.from(el.childNodes).map(n => ({
          type: n.nodeType,
          nodeName: n.nodeName,
          textContent: n.textContent,
          className: n.className
        }));
        return {
          childCount: el.childNodes.length,
          nodes,
          span: el.querySelector('span.highlighted-annotation')?.textContent
        };
      });

      record('Annotator middle context constructs leading ellipsis, highlight span, and trailing ellipsis',
        ctxMiddle.nodes.length === 3 &&
        ctxMiddle.nodes[0].type === 3 && ctxMiddle.nodes[0].textContent.startsWith('... ') &&
        ctxMiddle.span === ' malignant melanoma ' &&
        ctxMiddle.nodes[2].type === 3 && ctxMiddle.nodes[2].textContent.endsWith(' ...'),
        `Nodes: ${JSON.stringify(ctxMiddle.nodes)}`
      );
    }

    // 9. Annotator Context DOM Construction: End of text
    {
      const ctxEnd = await page.evaluate(() => {
        const el = document.getElementById('annotator-ctx-end');
        const nodes = Array.from(el.childNodes).map(n => ({
          type: n.nodeType,
          nodeName: n.nodeName,
          textContent: n.textContent,
          className: n.className
        }));
        return {
          childCount: el.childNodes.length,
          nodes,
          span: el.querySelector('span.highlighted-annotation')?.textContent
        };
      });

      record('Annotator end context constructs leading ellipsis and omits trailing ellipsis',
        ctxEnd.nodes[0].type === 3 && ctxEnd.nodes[0].textContent.startsWith('... ') &&
        ctxEnd.span === ' clinical notes. ' &&
        ctxEnd.nodes.length === 2,
        `Nodes: ${JSON.stringify(ctxEnd.nodes)}`
      );
    }

    // 10. Annotator Safe Inert Markup-Shaped Text Rendering
    {
      const ctxMarkup = await page.evaluate(() => {
        const el = document.getElementById('annotator-ctx-markup');
        return {
          imgCount: el.querySelectorAll('img').length,
          childElements: Array.from(el.children).map(c => c.tagName.toLowerCase()),
          spanText: el.querySelector('span.highlighted-annotation')?.textContent
        };
      });

      record('Annotator renders markup-shaped text safely via textContent with zero created img elements',
        ctxMarkup.imgCount === 0 && ctxMarkup.childElements.length === 1 && ctxMarkup.childElements[0] === 'span',
        `childElements: ${ctxMarkup.childElements.join(', ')}`
      );
      record('Annotator preserves literal markup string inside highlighted annotation span',
        ctxMarkup.spanText && ctxMarkup.spanText.includes('<img src=x onerror=window.__xssTriggered.push'),
        `spanText: ${ctxMarkup.spanText}`
      );
    }

    // 11. Zero XSS Executions
    {
      const xssTriggered = await page.evaluate(() => window.__xssTriggered);
      record('Zero XSS executions occurred across all recommender and annotator scenarios',
        xssTriggered.length === 0,
        `Triggers: ${JSON.stringify(xssTriggered)}`
      );
    }

    // 12. Zero Outgoing Network Requests
    {
      record('Zero external / non-fixture requests initiated during browser execution',
        recordedRequests.length === 0,
        `Recorded requests count: ${recordedRequests.length} (${recordedRequests.join(', ')})`
      );
    }

    // 13. Zero Stimulus Application Errors and Zero Browser Page Errors
    {
      const stimulusErrors = await page.evaluate(() => window.__stimulusErrors);
      assert.strictEqual(stimulusErrors.length, 0, `Stimulus errors occurred: ${JSON.stringify(stimulusErrors)}`);
      assert.strictEqual(pageErrors.length, 0, `Browser page errors occurred: ${JSON.stringify(pageErrors)}`);

      record('Zero Stimulus application errors and zero browser page errors across connect and actions',
        stimulusErrors.length === 0 && pageErrors.length === 0,
        `Stimulus errors: ${stimulusErrors.length}, Page errors: ${pageErrors.length}`
      );
    }

  } finally {
    await browser.close();
  }

  console.log('\n[SUMMARY]');
  console.log(`  Total:  ${testResults.total}`);
  console.log(`  Passed: ${testResults.passed}`);
  console.log(`  Failed: ${testResults.failed}`);

  if (testResults.failed > 0) {
    process.exit(1);
  }
}

runTests().catch(err => {
  console.error('Fatal error running highlight DOM check:', err);
  process.exit(1);
});
