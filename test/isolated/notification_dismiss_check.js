/**
 * test/isolated/notification_dismiss_check.js
 *
 * ONTO-AT-S01: a dismissed notification (timer or close button) must be removed, so it no
 * longer intercepts clicks or focus; auto_remove: false stays until closed; reduced motion
 * still dismisses; disconnect cancels timers. NotificationComponent is rendered natively in the
 * Ruby image; the real controller and notification.scss (native CSS nesting) run in headless Chrome.
 */
const { chromium } = require('playwright');
const esbuild = require('esbuild');
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';

function renderComponents() {
  const ruby = `
require "action_view"
require "rails"
require "haml"
require "haml/template"
require "view_component"
require "json"
class ViewComponent::Base
  def inline_svg_tag(name, options = {}) = "<svg class=\\"#{options[:class]}\\" data-icon=\\"#{name}\\"></svg>".html_safe
end
require "./app/components/notification_component.rb"
view = ActionView::Base.new(ActionView::LookupContext.new([File.expand_path("app/components")]), {}, nil)
puts JSON.generate(
  auto: NotificationComponent.new(title: "Saved <b>x</b>", type: "success").render_in(view),
  sticky: NotificationComponent.new(title: "Sticky", type: "error", auto_remove: false).render_in(view)
)`;
  const out = execFileSync('docker', ['run', '--rm', '--network', 'none', '-v', `${ROOT_DIR}:/app:ro`, '-w', '/app',
    '-e', 'GEM_PATH=/usr/local/bundle/ruby/3.1.0', 'onto-q02-proof:af254f34', 'bundle', 'exec', 'ruby', '-e', ruby],
    { encoding: 'utf8', timeout: 120000 });
  return JSON.parse(out.trim().split('\n').pop());
}

(async () => {
  const html = renderComponents();
  assert.match(html.auto, /data-notification-auto-remove-value=['"]true['"]/, 'default auto_remove renders auto dismissal');
  assert.match(html.sticky, /data-notification-auto-remove-value=['"]false['"]/);
  assert.match(html.auto, /Saved &lt;b&gt;x&lt;\/b&gt;/, 'title still rendered as text');
  assert.doesNotMatch(html.auto, /onClick/i, 'no inline opacity handler');

  const bundle = (await esbuild.build({
    stdin: {
      contents: `
        const { Application } = require('@hotwired/stimulus');
        const N = require('../../app/components/notification_component/notification_component_controller.js').default;
        const app = window.__app = Application.start();
        window.__stimulusErrors = [];
        app.handleError = (e) => window.__stimulusErrors.push(String(e));
        app.register('notification', N);
      `,
      resolveDir: path.resolve(__dirname)
    },
    bundle: true, format: 'iife', write: false,
    nodePaths: ['/home/ranma/ontoportal/bioportal_web_ui/node_modules']
  })).outputFiles[0].text;
  const css = fs.readFileSync(path.join(ROOT_DIR, 'app/assets/stylesheets/components/notification.scss'), 'utf8');

  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const outside = [];
  const errors = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
    page.on('pageerror', e => errors.push(String(e)));
    await page.route('**/*', route => {
      if (route.request().url() === 'http://notice.fixture/') {
        return route.fulfill({ contentType: 'text/html', body: `<!doctype html><head><style>${css}</style></head><body>
          <button id="under" style="position:fixed;top:0;right:0;width:600px;height:300px" onclick="window.__clicks=(window.__clicks||0)+1">under</button>
          <div id="host"></div></body>` });
      }
      outside.push(route.request().url());
      return route.abort();
    });
    await page.goto('http://notice.fixture/');
    await page.addScriptTag({ content: bundle });

    const mount = (markup, delay) => page.evaluate(({ markup, delay }) => {
      const host = document.getElementById('host');
      host.insertAdjacentHTML('beforeend', markup);
      const el = host.lastElementChild;
      if (delay !== undefined) el.setAttribute('data-notification-delay-value', String(delay));
      return host.children.length;
    }, { markup, delay });
    const count = () => page.evaluate(() => document.querySelectorAll('#host .notification').length);
    const clickUnder = async () => {
      const before = await page.evaluate(() => window.__clicks || 0);
      const box = await page.evaluate(() => { const r = document.getElementById('under').getBoundingClientRect(); return { x: r.right - 100, y: r.top + 100 }; });
      await page.mouse.click(box.x, box.y);
      return (await page.evaluate(() => window.__clicks || 0)) - before;
    };

    // Timer dismissal removes the node; the click lands on the target beneath.
    await mount(html.auto, 300);
    await page.waitForFunction(() => document.querySelector('#host .notification-inner').getBoundingClientRect().width > 0);
    await page.waitForFunction(() => !document.querySelector('#host .notification'), null, { timeout: 3000 });
    assert.strictEqual(await clickUnder(), 1, 'target beneath receives the click after timed dismissal');

    // auto_remove: false stays; close button removes it, moves focus out, and frees the area.
    await mount(html.sticky, 100);
    await page.waitForTimeout(400);
    assert.strictEqual(await count(), 1, 'sticky notification not auto-dismissed');
    await page.waitForTimeout(1200); // let the slide-in finish so the card is clickable
    assert.strictEqual(await clickUnder(), 0, 'a visible notice covers the target beneath it');
    await page.focus('#host .notification-close');
    await page.click('#host .notification-close');
    assert.strictEqual(await count(), 0, 'close button removes the notification');
    assert.strictEqual(await page.evaluate(() => document.activeElement === document.body), true, 'focus not left on a removed control');
    assert.strictEqual(await clickUnder(), 1, 'target beneath receives the click after manual dismissal');

    // Reduced motion: dismissal does not depend on animation events.
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await mount(html.auto, 200);
    await page.waitForFunction(() => !document.querySelector('#host .notification'), null, { timeout: 3000 });

    // Several notices clean up independently; removing one before its timer cancels that timer.
    await mount(html.auto, 300);
    await mount(html.auto, 600);
    await page.evaluate(() => document.querySelector('#host .notification').remove());
    assert.strictEqual(await count(), 1);
    await page.waitForFunction(() => !document.querySelector('#host .notification'), null, { timeout: 3000 });
    await page.waitForTimeout(400);

    assert.deepStrictEqual(await page.evaluate(() => window.__stimulusErrors), [], 'no Stimulus errors');
    assert.deepStrictEqual(errors, [], 'no page errors');
    assert.deepStrictEqual(outside, [], 'no requests outside fixtures');
    console.log(`PASS notification dismissal; outside=${outside.length}; pageerrors=${errors.length}`);
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e); process.exit(1); });
