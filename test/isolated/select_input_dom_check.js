/**
 * test/isolated/select_input_dom_check.js
 *
 * Isolated real-browser DOM test for SelectInput controller and LanguageSelector trust contract (ONTO-T-J02).
 * Verifies:
 * 1. Native Ruby ViewComponent rendering produces the explicit server-controlled language marker
 *    and properly Rails-escaped option labels for LanguageSelectorComponent.
 * 2. Plain selects escape ALL ordinary option text, item displayField (text and value),
 *    openAdd user-created values, special characters (quotes, ampersands, angle brackets,
 *    Unicode, pipes, line breaks, $100) using TomSelect's escape callback without injecting DOM elements.
 * 3. Multiple selection, remove_button plugin, searchable, and required behaviors are preserved.
 * 4. Language selects render known trusted first-party markup (earth SVG and flag icons) from the
 *    original server-generated option snapshot before TomSelect initialization.
 * 5. Dynamic, created, or incoming options cannot inject markup or self-opt-in via client properties.
 * 6. Zero network requests initiated during isolated browser execution.
 */

const { chromium } = require('playwright');
const esbuild = require('esbuild');
const path = require('path');
const assert = require('assert');
const { execFileSync } = require('child_process');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

function generateNativeRubyFixtures() {
  const rubyCode = `
# frozen_string_literal: true
require "action_view"
require "rails"
require "haml"
require "haml/rails_template"
ActionView::Template.register_template_handler(:haml, Haml::RailsTemplate.new)
require "view_component"
require "iso-639"
require "json"

module InternationalisationHelper
  def t(key)
    case key
    when "components.all_languages" then "All Languages"
    when "components.select_anguage" then "Choose a language"
    else key
    end
  end
end

module MultiLanguagesHelper
  def find_language_code_name(val)
    [val.to_s, val.to_s.upcase]
  end
end

module FlagIconsRails
  module Rails
    module ViewHelpers
      def flag_icon(code)
        "<span class=\\"flag-icon flag-icon-#{code}\\"></span>".html_safe
      end
    end
  end
end

module ApplicationHelper
  def inline_svg_tag(filename, options = {})
    "<svg class=\\"earth-icon\\" width=\\"#{options[:width]}\\" height=\\"#{options[:height]}\\"><circle cx=\\"8\\" cy=\\"8\\" r=\\"8\\"/></svg>".html_safe
  end
end

class ViewComponent::Base
  include InternationalisationHelper
  include ApplicationHelper
end

module Input; end
require "./app/components/select_input_component.rb"
require "./app/components/language_field_component.rb"
require "./app/components/input/language_selector_component.rb"

lookup = ActionView::LookupContext.new([File.expand_path("app/components")])
view_context = ActionView::Base.new(lookup, {}, nil)

# 1. First-party LanguageSelectorComponent with earth icon (enable_all) and flags
lang_selector = Input::LanguageSelectorComponent.new(
  languages: { en: "English", fr: "French", de: "German" },
  id: "language_select",
  name: "language_select",
  enable_all: true
)
lang_html = lang_selector.render_in(view_context)

# 2. Plain select with special characters in labels
plain_comp = SelectInputComponent.new(
  id: "plain_select",
  name: "plain_select",
  values: [
    ["Normal Option", "norm1"],
    ["<script>window.__xssTriggered.push(1)</script> \\"quotes\\" & 'amps' <b>bold</b> | pipe $100 \\n newline 🌍", "special1"]
  ]
)
plain_html = plain_comp.render_in(view_context)

# 3. Plain select with displayField = 'value'
display_val_comp = SelectInputComponent.new(
  id: "display_val_select",
  name: "display_val_select",
  values: [["Display Label", "<script>window.__xssTriggered.push(2)</script> & \\"val\\""], ["Simple", "simple_val"]],
  data: { "select-input-display-field-value": "value" }
)
display_val_html = display_val_comp.render_in(view_context)

# 4. Open-add select for user-created values
open_add_comp = SelectInputComponent.new(
  id: "open_add_select",
  name: "open_add_select",
  values: [["Initial 1", "init1"]],
  open_to_add_values: true
)
open_add_html = open_add_comp.render_in(view_context)

# 5. Multiple select with required: true
multi_comp = SelectInputComponent.new(
  id: "multi_select",
  name: "multi_select",
  values: [["Option A", "a"], ["Option B", "b"], ["Option C", "c"]],
  multiple: true,
  required: true
)
multi_html = multi_comp.render_in(view_context)

# 6. Non-searchable select
unsearchable_comp = SelectInputComponent.new(
  id: "unsearchable_select",
  name: "unsearchable_select",
  values: [["Item 1", "1"], ["Item 2", "2"]],
  data: { "select-input-searchable-value": false }
)
unsearchable_html = unsearchable_comp.render_in(view_context)

# 7. Required single select
required_comp = SelectInputComponent.new(
  id: "required_select",
  name: "required_select",
  values: [["First Req", "req1"], ["Second Req", "req2"]],
  required: true
)
required_html = required_comp.render_in(view_context)

puts JSON.generate({
  lang_html: lang_html,
  plain_html: plain_html,
  display_val_html: display_val_html,
  open_add_html: open_add_html,
  multi_html: multi_html,
  unsearchable_html: unsearchable_html,
  required_html: required_html
})
`;

  const output = execFileSync('ruby', ['-e', rubyCode], {
    cwd: ROOT_DIR,
    env: {
      ...process.env,
      LC_ALL: 'C.UTF-8',
      GEM_PATH: '/home/ranma/ontoportal/ontoportal_web_ui/vendor/bundle/ruby/3.3.0'
    },
    encoding: 'utf8'
  });

  return JSON.parse(output);
}

async function buildControllerBundle() {
  const result = await esbuild.build({
    stdin: {
      contents: `
        import { Application } from "@hotwired/stimulus";
        import SelectInput from "./app/components/select_input_component/select_input_component_controller.js";

        window.StimulusApp = Application.start();
        window.StimulusApp.register("select-input", SelectInput);
        window.__selectControllerReady = true;
      `,
      resolveDir: ROOT_DIR
    },
    bundle: true,
    format: 'iife',
    write: false,
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  });
  return result.outputFiles[0].text;
}

function buildHtmlPage(fixtures) {
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>SelectInput Isolated DOM Check</title>
  <style>
    .ts-wrapper { position: relative; }
    .ts-dropdown { display: block; }
  </style>
  <script>
    window.__xssTriggered = [];
  </script>
</head>
<body>
  <div id="container-lang">
    ${fixtures.lang_html}
  </div>

  <div id="container-plain">
    ${fixtures.plain_html}
  </div>

  <div id="container-display-val">
    ${fixtures.display_val_html}
  </div>

  <div id="container-open-add">
    ${fixtures.open_add_html}
  </div>

  <div id="container-multi">
    ${fixtures.multi_html}
  </div>

  <div id="container-unsearchable">
    ${fixtures.unsearchable_html}
  </div>

  <div id="container-required">
    ${fixtures.required_html}
  </div>
</body>
</html>`;
}

async function runDomCheck() {
  console.log('[1/4] Generating native Ruby component fixtures...');
  const fixtures = generateNativeRubyFixtures();
  console.log('      Native Ruby fixtures generated.');

  console.log('[2/4] Building production Stimulus controller bundle with esbuild...');
  const bundleJs = await buildControllerBundle();
  console.log(`      Bundle size: ${bundleJs.length} bytes`);

  console.log('[3/4] Launching isolated headless Chromium browser...');
  const browser = await chromium.launch({
    executablePath: CHROME_PATH,
    headless: true
  });

  const testResults = {
    total: 0,
    passed: 0,
    failed: 0,
    details: []
  };

  function record(name, condition, extra = null) {
    testResults.total++;
    if (condition) {
      testResults.passed++;
      console.log(`  ✓ ${name}`);
      testResults.details.push({ name, status: 'PASS', extra });
    } else {
      testResults.failed++;
      console.error(`  ✗ FAIL: ${name} (${extra})`);
      testResults.details.push({ name, status: 'FAIL', extra });
    }
  }

  try {
    const context = await browser.newContext({
      javaScriptEnabled: true
    });

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

    await page.addInitScript(() => {
      window.__xssTriggered = [];
    });

    const htmlContent = buildHtmlPage(fixtures);
    await page.setContent(htmlContent);
    await page.addScriptTag({ content: bundleJs });

    // Wait for Stimulus controller to connect and TomSelect instances to initialize
    await page.waitForFunction(() => window.__selectControllerReady === true);
    await page.waitForTimeout(200);

    console.log('[4/4] Running isolated DOM security, escaping, and trust verification tests...');

    // -------------------------------------------------------------
    // Test 1: Native Ruby LanguageSelectorComponent markup and marker
    // -------------------------------------------------------------
    {
      const hasLanguageMarker = fixtures.lang_html.includes('data-select-input-is-language-value="true"');
      const plainHasNoMarker = !fixtures.plain_html.includes('data-select-input-is-language-value');

      record('LanguageSelector explicitly outputs server-controlled is-language marker',
        hasLanguageMarker && plainHasNoMarker,
        `hasLanguageMarker: ${hasLanguageMarker}, plainHasNoMarker: ${plainHasNoMarker}`
      );
    }

    // -------------------------------------------------------------
    // Test 2: Plain select - Ordinary option text & exact text escaping
    // -------------------------------------------------------------
    {
      const res = await page.evaluate(() => {
        const sel = document.getElementById('select_plain_select');
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(sel, 'select-input');
        const ts = ctrl.select;

        // Render option 'special1'
        const optEl = ts.render('option', ts.options['special1']);

        return {
          innerHTML: optEl.innerHTML,
          textContent: optEl.textContent,
          scriptCount: optEl.querySelectorAll('script').length,
          boldCount: optEl.querySelectorAll('b').length,
          childElementCount: optEl.childElementCount
        };
      });

      const rawSpecial = `<script>window.__xssTriggered.push(1)</script> "quotes" & 'amps' <b>bold</b> | pipe $100 \n newline 🌍`;

      record('Plain option escapes markup, quotes, ampersands, angle brackets into literal text without elements',
        res.childElementCount === 0 && res.scriptCount === 0 && res.boldCount === 0 &&
        res.innerHTML.includes('&lt;script&gt;') && res.innerHTML.includes('&amp;'),
        `childElements: ${res.childElementCount}, innerHTML: ${res.innerHTML.slice(0, 80)}...`
      );

      record('Plain option preserves exact raw textContent including $100, quotes, ampersands, Unicode, and newlines',
        res.textContent.trim() === rawSpecial.trim(),
        `textContent: ${res.textContent}`
      );
    }

    // -------------------------------------------------------------
    // Test 3: Plain select - Item displayField text escaping
    // -------------------------------------------------------------
    {
      const itemRes = await page.evaluate(() => {
        const sel = document.getElementById('select_plain_select');
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(sel, 'select-input');
        const ts = ctrl.select;

        ts.addItem('special1');
        const itemEl = sel.parentElement.querySelector('.item[data-value="special1"]');

        return {
          textContent: itemEl ? itemEl.textContent.trim() : null,
          innerHTML: itemEl ? itemEl.innerHTML : null,
          hasScript: itemEl ? itemEl.querySelectorAll('script').length > 0 : false,
          hasBold: itemEl ? itemEl.querySelectorAll('b').length > 0 : false
        };
      });

      const rawSpecial = `<script>window.__xssTriggered.push(1)</script> "quotes" & 'amps' <b>bold</b> | pipe $100 \n newline 🌍`;

      record('Plain item with displayField text escapes all markup and renders literal text',
        itemRes.textContent === rawSpecial.trim() && !itemRes.hasScript && !itemRes.hasBold &&
        itemRes.innerHTML.includes('&lt;script&gt;'),
        `item innerHTML: ${itemRes.innerHTML ? itemRes.innerHTML.slice(0, 80) : null}`
      );
    }

    // -------------------------------------------------------------
    // Test 4: Plain select - Item displayField value escaping
    // -------------------------------------------------------------
    {
      const valRes = await page.evaluate(() => {
        const sel = document.getElementById('select_display_val_select');
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(sel, 'select-input');
        const ts = ctrl.select;

        const evilValue = '<script>window.__xssTriggered.push(2)</script> & "val"';
        ts.addItem(evilValue);
        const itemEl = sel.parentElement.querySelector('.item');

        return {
          textContent: itemEl ? itemEl.textContent.trim() : null,
          innerHTML: itemEl ? itemEl.innerHTML : null,
          scriptCount: itemEl ? itemEl.querySelectorAll('script').length : 0
        };
      });

      const expectedVal = '<script>window.__xssTriggered.push(2)</script> & "val"';

      record('Plain item with displayField value renders escaped value text without script elements',
        valRes.textContent === expectedVal && valRes.scriptCount === 0 &&
        valRes.innerHTML.includes('&lt;script&gt;'),
        `valRes textContent: ${valRes.textContent}`
      );
    }

    // -------------------------------------------------------------
    // Test 5: openAdd user-created values are plain escaped
    // -------------------------------------------------------------
    {
      const openAddRes = await page.evaluate(() => {
        const sel = document.getElementById('select_open_add_select');
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(sel, 'select-input');
        const ts = ctrl.select;

        const evilCreated = '<img src=x onerror="window.__xssTriggered.push(3)"> "created" & $100';
        ts.createItem(evilCreated);

        const itemEl = sel.parentElement.querySelector('.item[data-value*="img"]');

        return {
          found: !!itemEl,
          textContent: itemEl ? itemEl.textContent.trim() : null,
          innerHTML: itemEl ? itemEl.innerHTML : null,
          imgCount: itemEl ? itemEl.querySelectorAll('img').length : 0
        };
      });

      const expectedCreated = '<img src=x onerror="window.__xssTriggered.push(3)"> "created" & $100';

      record('openAdd user-created values are escaped and literal text without injected elements',
        openAddRes.found && openAddRes.textContent === expectedCreated && openAddRes.imgCount === 0 &&
        openAddRes.innerHTML.includes('&lt;img'),
        `openAddRes innerHTML: ${openAddRes.innerHTML}`
      );
    }

    // -------------------------------------------------------------
    // Test 6: Multiple, remove_button, searchable: false, and required behaviors preserved
    // -------------------------------------------------------------
    {
      const behaviorRes = await page.evaluate(() => {
        // Multi select check
        const multiSel = document.getElementById('select_multi_select');
        const multiCtrl = window.StimulusApp.getControllerForElementAndIdentifier(multiSel, 'select-input');
        const multiTs = multiCtrl.select;

        multiTs.addItem('a');
        multiTs.addItem('b');
        const itemsBefore = multiSel.parentElement.querySelectorAll('.item');
        const hasRemoveButtons = Array.from(itemsBefore).every(el => !!el.querySelector('.remove'));

        // Click remove button on item 'a'
        const removeBtn = itemsBefore[0].querySelector('.remove');
        if (removeBtn) removeBtn.click();
        const itemsAfter = multiSel.parentElement.querySelectorAll('.item');

        // Unsearchable select check
        const unsearchableSel = document.getElementById('select_unsearchable_select');
        const unsearchableCtrl = window.StimulusApp.getControllerForElementAndIdentifier(unsearchableSel, 'select-input');
        const tsUnsearchable = unsearchableCtrl.select;

        // Required single select check
        const reqSel = document.getElementById('select_required_select');
        const reqCtrl = window.StimulusApp.getControllerForElementAndIdentifier(reqSel, 'select-input');
        const tsReq = reqCtrl.select;

        // Clear value and trigger change event
        tsReq.setValue('', false);
        let changeFired = false;
        const changeListener = () => { changeFired = true; };
        document.addEventListener('change', changeListener);
        tsReq.trigger('change');
        document.removeEventListener('change', changeListener);
        const reqValueAfter = tsReq.getValue();

        return {
          hasRemoveButtons,
          countBefore: itemsBefore.length,
          countAfter: itemsAfter.length,
          controlInputNull: tsUnsearchable.settings.controlInput === null && !tsUnsearchable.control.querySelector('input'),
          reqAutoSelected: reqValueAfter === 'req1',
          changeFired
        };
      });

      record('Multiple select has remove_button plugin enabled and removes items properly',
        behaviorRes.hasRemoveButtons && behaviorRes.countBefore === 2 && behaviorRes.countAfter === 1,
        `hasRemoveButtons: ${behaviorRes.hasRemoveButtons}, before: ${behaviorRes.countBefore}, after: ${behaviorRes.countAfter}`
      );

      record('Searchable false disables controlInput on TomSelect instance',
        behaviorRes.controlInputNull,
        `controlInputNull: ${behaviorRes.controlInputNull}`
      );

      record('Required single select auto-selects first item when empty and dispatches change event',
        behaviorRes.reqAutoSelected && behaviorRes.changeFired,
        `autoSelected: ${behaviorRes.reqAutoSelected}, changeFired: ${behaviorRes.changeFired}`
      );
    }

    // -------------------------------------------------------------
    // Test 7: Language select - Trusted first-party markup (earth SVG and flag icons)
    // -------------------------------------------------------------
    {
      const langRes = await page.evaluate(() => {
        const sel = document.getElementById('select_language_select');
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(sel, 'select-input');
        const ts = ctrl.select;

        // Render option 'all'
        const optAll = ts.render('option', ts.options['all']);
        const svgInAll = optAll.querySelector('svg.earth-icon');

        // Render option 'en'
        const optEn = ts.render('option', ts.options['en']);
        const flagInEn = optEn.querySelector('span.flag-icon.flag-icon-gb');

        // Render option 'fr'
        const optFr = ts.render('option', ts.options['fr']);
        const flagInFr = optFr.querySelector('span.flag-icon.flag-icon-fr');

        // Select 'en' and check rendered item
        ts.addItem('en');
        const itemEn = sel.parentElement.querySelector('.item[data-value="en"]');
        const flagInItemEn = itemEn ? itemEn.querySelector('span.flag-icon.flag-icon-gb') : null;

        // Switch selection to 'fr' and check updated item
        ts.addItem('fr');
        const itemFr = sel.parentElement.querySelector('.item[data-value="fr"]');
        const flagInItemFr = itemFr ? itemFr.querySelector('span.flag-icon.flag-icon-fr') : null;

        return {
          noCreate: !ts.settings.create,
          allHasSvg: !!svgInAll,
          allText: optAll.textContent.trim(),
          enHasFlag: !!flagInEn,
          enText: optEn.textContent.trim(),
          frHasFlag: !!flagInFr,
          frText: optFr.textContent.trim(),
          itemEnHasFlag: !!flagInItemEn,
          itemEnText: itemEn ? itemEn.textContent.trim() : null,
          itemFrHasFlag: !!flagInItemFr,
          itemFrText: itemFr ? itemFr.textContent.trim() : null,
          currentValue: ts.getValue()
        };
      });

      record('Language select preserves no-create setting (create is false)',
        langRes.noCreate,
        `noCreate: ${langRes.noCreate}`
      );

      record('Language select renders trusted earth SVG for all-languages option',
        langRes.allHasSvg && langRes.allText.includes('All Languages'),
        `allHasSvg: ${langRes.allHasSvg}, allText: ${langRes.allText}`
      );

      record('Language select renders trusted flag icons and labels for English and French options',
        langRes.enHasFlag && langRes.enText.includes('English') &&
        langRes.frHasFlag && langRes.frText.includes('French'),
        `enHasFlag: ${langRes.enHasFlag}, frHasFlag: ${langRes.frHasFlag}`
      );

      record('Language select renders rich flag icon and label in selected item and updates on change',
        langRes.itemEnHasFlag && langRes.itemFrHasFlag && langRes.currentValue === 'fr',
        `itemEnHasFlag: ${langRes.itemEnHasFlag}, itemFrHasFlag: ${langRes.itemFrHasFlag}, currentValue: ${langRes.currentValue}`
      );
    }

    // -------------------------------------------------------------
    // Test 8: Language select - Dynamic / created / incoming data cannot inject markup or self-opt-in
    // -------------------------------------------------------------
    {
      const injectionRes = await page.evaluate(() => {
        const sel = document.getElementById('select_language_select');
        const ctrl = window.StimulusApp.getControllerForElementAndIdentifier(sel, 'select-input');
        const ts = ctrl.select;

        // 1. Dynamic untrusted option with markup
        ts.addOption({ value: 'injected1', text: '<img src=x onerror="window.__xssTriggered.push(4)"> Injected' });
        const optInjected1 = ts.render('option', ts.options['injected1']);

        // 2. Dynamic option attempting to self-opt-in via isLanguage / trusted flags
        ts.addOption({
          value: 'injected2',
          text: '<b>Fake Rich</b>',
          isLanguage: true,
          trusted: true,
          markup: '<div><b>Bypass</b></div>'
        });
        const optInjected2 = ts.render('option', ts.options['injected2']);

        // 3. Dynamic option attempting to overwrite existing 'en' value with markup
        ts.options['en'].text = '<img src=x onerror="window.__xssTriggered.push(5)"> English Hacked';
        const optEnTampered = ts.render('option', ts.options['en']);

        return {
          injected1ImgCount: optInjected1.querySelectorAll('img').length,
          injected1Escaped: optInjected1.innerHTML.includes('&lt;img'),
          injected2BoldCount: optInjected2.querySelectorAll('b').length,
          injected2Escaped: optInjected2.innerHTML.includes('&lt;b&gt;'),
          enTamperedStillSafe: optEnTampered.querySelectorAll('img').length === 0,
          enTamperedHasOriginalFlag: !!optEnTampered.querySelector('span.flag-icon.flag-icon-gb')
        };
      });

      record('Dynamic injected option in language select is plain escaped without rendering HTML',
        injectionRes.injected1ImgCount === 0 && injectionRes.injected1Escaped,
        `injected1ImgCount: ${injectionRes.injected1ImgCount}, escaped: ${injectionRes.injected1Escaped}`
      );

      record('Dynamic option with client-side isLanguage/trusted flags cannot self-opt-in and remains plain escaped',
        injectionRes.injected2BoldCount === 0 && injectionRes.injected2Escaped,
        `injected2BoldCount: ${injectionRes.injected2BoldCount}, escaped: ${injectionRes.injected2Escaped}`
      );

      record('Tampered option text for known language value uses original server snapshot instead of injected string',
        injectionRes.enTamperedStillSafe && injectionRes.enTamperedHasOriginalFlag,
        `stillSafe: ${injectionRes.enTamperedStillSafe}, hasOriginalFlag: ${injectionRes.enTamperedHasOriginalFlag}`
      );
    }

    // -------------------------------------------------------------
    // Test 9: Zero script payloads executed across all tests
    // -------------------------------------------------------------
    {
      const xssCount = await page.evaluate(() => window.__xssTriggered.length);
      record('Zero XSS/script execution occurred across all plain and language select test scenarios',
        xssCount === 0,
        `XSS triggered count: ${xssCount}`
      );
    }

    // -------------------------------------------------------------
    // Test 10: Zero network requests made during tested rendering
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
}

runDomCheck().catch((err) => {
  console.error('Test run failed with error:', err);
  process.exit(1);
});
