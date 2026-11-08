/**
 * test/isolated/browse_search_layout_check.js
 *
 * ONTO-AT-S02: geometry of the browse / personal-ontologies search row at the media-query
 * boundaries. Compiles app/assets/stylesheets/browse.scss with the repository's sassc gem
 * (Docker image onto-q02-proof:af254f34, no network) for the base revision and the working tree,
 * renders the shared search-bar markup of ontologies/browser/browse and my_ontologies/index, and
 * checks that the search input and the format/sort selects stay inside the result column, do not
 * overlap each other and cause no horizontal document scrolling. Also exercises typing and
 * selection so the form names and the existing data-action stay usable.
 *
 * Usage: node test/isolated/browse_search_layout_check.js   (CSS_BASE_REV defaults to the pre-fix commit)
 */
const { chromium } = require('playwright');
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT_DIR = path.resolve(__dirname, '../..');
const CHROME_PATH = process.env.CHROME_BIN || '/usr/bin/google-chrome';
const BASE = process.env.CSS_BASE_REV || '94754b92102711ebb961d2bd45eb3dac53bd4287'; // browse.scss before ONTO-AT-S02
const SCSS = 'app/assets/stylesheets/browse.scss';
const WIDTHS = [1005, 1006, 1100, 1250, 1251, 1440];

function compile(scss) {
  return execFileSync('docker', ['run', '--rm', '-i', '--network', 'none', '-e', 'GEM_PATH=/usr/local/bundle/ruby/3.1.0',
    'onto-q02-proof:af254f34', 'ruby', '-e', 'require "sassc"; print SassC::Engine.new(STDIN.read, syntax: :scss).render'],
    { input: scss, encoding: 'utf8', timeout: 120000 });
}

const LABELS = {
  en: { placeholder: 'Search an ontology', formats: ['All formats', 'OWL', 'SKOS'], sorts: ['Sort by popularity', 'Sort by name'] },
  fr: { placeholder: 'Rechercher une ontologie', formats: ['Tous les formats', 'OWL', 'SKOS'], sorts: ['Trier par popularité', 'Trier par nom'] }
};

// Same structure as the two templates (bootstrap's border-box reset included).
const page = (css, l) => `<!doctype html><html><head><style>*,*::before,*::after{box-sizing:border-box} body{margin:0;font-family:sans-serif}${css}</style></head><body>
<div class="browse-center"><div class="browse-container">
 <div data-controller="browse-filters"><div class="browse-sub-container">
  <div class="browse-first-row"><div class="pt-1">upload</div><p class="browse-filters-title">Filters</p></div>
  <div class="browse-second-row">
   <div class="browse-search-bar"><div class="browse-search-container">
    <input name="search" placeholder="${l.placeholder}" type="text" data-action="input->browse-filters#dispatchInputEvent">
    <div class="browse-search-filters">
     <select id="format" class="browse-format-filter" name="format">${l.formats.map((f, i) => `<option value="${i}">${f}</option>`).join('')}</select>
     <select id="Sort_by" class="browse-sort-by-filter" name="Sort_by" data-browse-filters-target="sort">${l.sorts.map((s, i) => `<option value="${i}">${s}</option>`).join('')}</select>
    </div></div></div>
   <div class="browse-ontologies"><div style="height:400px">results</div></div>
  </div></div></div>
</div></div></body></html>`;

async function measure(p) {
  return p.evaluate(() => {
    const r = (s) => { const b = document.querySelector(s).getBoundingClientRect(); return { l: b.left, r: b.right, t: b.top, b: b.bottom }; };
    return { row: r('.browse-second-row'), input: r('.browse-search-bar input'), format: r('#format'), sort: r('#Sort_by'),
      scroll: document.documentElement.scrollWidth, inner: window.innerWidth };
  });
}

function problems(m) {
  const out = [];
  const hit = (a, b) => a.l < b.r - 0.5 && b.l < a.r - 0.5 && a.t < b.b - 0.5 && b.t < a.b - 0.5;
  for (const k of ['input', 'format', 'sort']) {
    if (m[k].l < m.row.l - 0.5 || m[k].r > m.row.r + 0.5) out.push(`${k} outside result column (${Math.round(m[k].l)}-${Math.round(m[k].r)} vs ${Math.round(m.row.l)}-${Math.round(m.row.r)})`);
  }
  if (hit(m.input, m.format)) out.push('input overlaps format');
  if (hit(m.input, m.sort)) out.push('input overlaps sort');
  if (hit(m.format, m.sort)) out.push('format overlaps sort');
  if (m.scroll > m.inner) out.push(`horizontal scroll ${m.scroll}>${m.inner}`);
  return out;
}

(async () => {
  const css = { base: compile(execFileSync('git', ['-C', ROOT_DIR, 'show', `${BASE}:${SCSS}`], { encoding: 'utf8' })),
    current: compile(fs.readFileSync(path.join(ROOT_DIR, SCSS), 'utf8')) };
  const browser = await chromium.launch({ executablePath: CHROME_PATH, headless: true });
  const report = {};
  const rects = {};
  try {
    const p = await browser.newPage();
    for (const which of ['base', 'current']) {
      for (const lang of ['en', 'fr']) {
        for (const w of WIDTHS) {
          await p.setViewportSize({ width: w, height: 800 });
          await p.setContent(page(css[which], LABELS[lang]));
          const m = await measure(p);
          rects[`${which}/${lang}/${w}`] = m;
          report[`${which}/${lang}/${w}`] = problems(m);
        }
      }
    }
    for (const [k, v] of Object.entries(report)) console.log(`  ${k}: ${v.length ? v.join('; ') : 'ok'}`);

    const failing = (which) => Object.entries(report).filter(([k, v]) => k.startsWith(which) && v.length).map(([k]) => k);
    assert.ok(failing('base').some(k => /\/(1006|1100|1250)$/.test(k)), 'reproduction: base layout fails in the 1006-1250 interval');
    assert.deepStrictEqual(failing('current'), [], 'current layout has no overlap/overflow at any width or language');
    for (const lang of ['en', 'fr']) {
      for (const w of [1005, 1251, 1440]) {
        assert.deepStrictEqual(rects[`current/${lang}/${w}`], rects[`base/${lang}/${w}`], `stacked/desktop layout unchanged at ${lang}/${w}`);
      }
    }

    // Controls stay usable: typing, format and sort selection with unchanged names.
    for (const w of [1005, 1100, 1251]) {
      await p.setViewportSize({ width: w, height: 800 });
      await p.setContent(page(css.current, LABELS.fr));
      await p.click('.browse-search-bar input');
      await p.keyboard.type('anat');
      await p.selectOption('#format', '1');
      await p.selectOption('#Sort_by', '1');
      const v = await p.evaluate(() => [...document.querySelectorAll('[name]')].map(e => `${e.name}=${e.value}`).join('&'));
      assert.strictEqual(v, 'search=anat&format=1&Sort_by=1', `form values at ${w}`);
    }
    console.log('PASS browse search layout');
  } finally {
    await browser.close();
  }
})().catch(e => { console.error('FAIL', e.message || e); process.exit(1); });
