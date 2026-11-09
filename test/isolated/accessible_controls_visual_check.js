/**
 * test/isolated/accessible_controls_visual_check.js
 *
 * ONTO-T-U05: the p/div -> label/button changes must not change how the controls look.
 * Compiles Bootstrap 4.2.1 (gem in onto-q02-proof:af254f34, no network) with the project's
 * login, register, dropdown, nested-form and input-field stylesheets, renders the old and the new
 * markup of each control and compares box geometry and key computed styles. Also checks that the
 * new buttons are reachable with Tab.
 */
const { chromium } = require('playwright');
const assert = require('assert');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const SCSS = '@import "bootstrap"; @import "register"; @import "login"; @import "components/dropdown"; @import "components/nested_form"; @import "components/input_field";';
const css = execFileSync('docker', ['run', '--rm', '-i', '--network', 'none', '-v', `${ROOT_DIR}:/app:ro`, '-w', '/app',
  '-e', 'GEM_PATH=/usr/local/bundle/ruby/3.1.0', 'onto-q02-proof:af254f34', 'ruby', '-e',
  'require "sassc"; print SassC::Engine.new(STDIN.read, syntax: :scss, load_paths: ["app/assets/stylesheets", "/usr/local/bundle/ruby/3.1.0/gems/bootstrap-4.2.1/assets/stylesheets"]).render'],
  { input: SCSS, encoding: 'utf8', timeout: 120000 });

const svg = '<svg width="14" height="14"><path d="M0 0h14v14H0z"/></svg>';
const CASES = {
  login: [`<div class="login-form" style="width:400px"><p class="login-input-title">Email</p><input id="user_username" class="login-input email-input"></div>`,
          `<div class="login-form" style="width:400px"><label class="login-input-title d-block" for="user_username">Email</label><input id="user_username" class="login-input email-input"></div>`],
  register: [`<div style="width:400px"><div class="register-first-input"><p class="register-input-title">First name <font color="red">*</font></p><input id="user_firstName" class="register-input-short"></div></div>`,
             `<div style="width:400px"><div class="register-first-input"><label class="register-input-title d-block" for="user_firstName">First name <font color="red">*</font></label><input id="user_firstName" class="register-input-short"></div></div>`],
  dropdown: [`<div class="dropdown-container" style="width:300px"><div class="dropdown-title-bar" data-toggle="collapse"><p class="dropdown-title">Formats</p><i>v</i></div></div>`,
             `<div class="dropdown-container" style="width:300px"><button class="dropdown-title-bar border-0 bg-transparent text-left w-100" type="button" data-toggle="collapse"><p class="dropdown-title">Formats</p><i>v</i></button></div>`],
  nested: [`<div class="nested-form-input-container" style="width:500px"><div class="d-flex justify-content-end" style="width:10%"><div class="delete">${svg}</div></div><div class="add-another-object">${svg}<div>Add another contact</div></div></div>`,
           `<div class="nested-form-input-container" style="width:500px"><div class="d-flex justify-content-end" style="width:10%"><button class="delete bg-transparent p-0 text-reset text-left" type="button" aria-label="Remove row">${svg}</button></div><button class="add-another-object w-100 bg-transparent text-reset text-left" type="button">${svg}<div>Add another contact</div></button></div>`]
};
const PROPS = ['display', 'color', 'background-color', 'border-top-width', 'border-top-style', 'font-size', 'font-weight', 'font-family', 'padding-top', 'padding-left', 'margin-bottom', 'text-align'];

(async () => {
  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    const snap = async (html) => {
      await page.setContent(`<!doctype html><html><head><style>${css}</style></head><body><div id="root">${html}</div></body></html>`);
      return page.evaluate((PROPS) => [...document.querySelectorAll('#root *')].filter(e => !e.closest('svg') || e.tagName === 'svg').map(e => {
        const b = e.getBoundingClientRect(); const cs = getComputedStyle(e);
        return { box: [b.x, b.y, b.width, b.height].map(Math.round), style: Object.fromEntries(PROPS.filter(p => !(p === 'display' && /^(P|LABEL|DIV|BUTTON)$/.test(e.tagName))).map(p => [p, cs.getPropertyValue(p)])) };
      }), PROPS);
    };
    for (const [name, [before, after]] of Object.entries(CASES)) {
      assert.deepStrictEqual(await snap(after), await snap(before), `${name}: new markup renders like the old markup`);
      console.log(`  ${name}: identical geometry and computed styles`);
    }
    await page.setContent(`<!doctype html><html><head><style>${css}</style></head><body>${CASES.nested[1]}${CASES.dropdown[1]}</body></html>`);
    const order = [];
    for (let i = 0; i < 3; i++) { await page.keyboard.press('Tab'); order.push(await page.evaluate(() => document.activeElement.className.split(' ')[0])); }
    assert.deepStrictEqual(order, ['delete', 'add-another-object', 'dropdown-title-bar'], 'new buttons are reachable with Tab');
    console.log('PASS accessible controls visual parity; tab order', order.join(' > '));
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e.message || e); process.exit(1); });
