'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const INIT_PATH = path.join(__dirname,
  '../../MacDown/Resources/Extensions/pele.init.js');

function makeElement(tag) {
  return {
    tagName: tag, style: {}, children: [],
    appendChild(child) { this.children.push(child); }
  };
}

// Exercise our DOM adapter with a controlled renderer rejection. Pele
// itself is deliberately not mocked as a security guarantee for its SVGs.
(async function () {
  let onLoad;
  let replacement;
  const pre = { tagName: 'PRE', parentNode: {
    replaceChild(element, original) {
      assert.equal(original, pre);
      replacement = element;
    }
  } };
  const code = { textContent: 'invalid graph', parentElement: pre };
  const message = '<img src=x onerror=alert(1)>';
  const context = {
    document: {
      readyState: 'complete', body: { contains: () => true },
      querySelectorAll: () => [code],
      createElement: makeElement
    },
    window: { addEventListener: (event, callback) => { onLoad = callback; } },
    console: { warn() {}, error() {} },
    pele: { render() { throw new Error(message); } }
  };
  vm.runInNewContext(fs.readFileSync(INIT_PATH, 'utf8'), context);
  await onLoad();
  assert.equal(replacement.tagName, 'pre');
  assert.equal(replacement.className, 'pele-error');
  assert.equal(replacement.children.length, 2);
  assert.equal(replacement.children[0].textContent, 'Pele Error: ' + message);
  assert.equal(replacement.children[1].textContent, 'invalid graph');
  assert.equal(replacement.innerHTML, undefined);
  assert.equal(pre.outerHTML, undefined);
  process.stdout.write('Pele error shows message and source as text: passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });

(async function () {
  let onLoad, onMutation, scheduled, resolveOld;
  const oldPre = { tagName: 'PRE' };
  const newPre = { tagName: 'PRE' };
  let currentPre = oldPre;
  let code = { textContent: 'old graph', parentElement: oldPre };
  const rendered = [];
  const context = {
    document: {
      readyState: 'complete',
      body: { contains: node => node === currentPre },
      querySelectorAll: () => code ? [code] : [],
      createElement: makeElement
    },
    window: { addEventListener: (event, callback) => { onLoad = callback; } },
    console: { warn() {}, error() {} },
    setTimeout: callback => { scheduled = callback; },
    MutationObserver: class {
      constructor(callback) { onMutation = callback; }
      observe() {}
    },
    pele: {
      render(source) {
        rendered.push(source);
        if (source === 'old graph') return new Promise(resolve => { resolveOld = resolve; });
        code = null;
        return Promise.resolve({ svg: '<svg>new graph</svg>' });
      }
    }
  };
  vm.runInNewContext(fs.readFileSync(INIT_PATH, 'utf8'), context);
  const oldRender = onLoad();
  currentPre = newPre;
  code = { textContent: 'new graph', parentElement: newPre };
  onMutation();
  resolveOld({ svg: '<svg>old graph</svg>' });
  await oldRender;
  assert.equal(oldPre.outerHTML, undefined);
  assert.equal(typeof scheduled, 'function');
  await scheduled();
  assert.deepEqual(rendered, ['old graph', 'new graph']);
  assert.match(newPre.outerHTML, /^<span class="pele-diagram" style="[^"]*--pele-bg:/);
  assert.match(newPre.outerHTML, /<svg>new graph<\/svg><\/span>$/);
  process.stdout.write('Pele replaced DOM during pending render: passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Same source rendered twice must invoke Pele only once (cache hit).
(async function () {
  let onLoad;
  let renderCalls = 0;
  const pre = { tagName: 'PRE' };
  const code = { textContent: 'same graph', parentElement: pre };
  const context = {
    document: {
      readyState: 'complete', body: { contains: () => true },
      querySelectorAll: () => [code],
      createElement: makeElement
    },
    window: { addEventListener: (event, callback) => { onLoad = callback; } },
    console: { warn() {}, error() {} },
    pele: { render() { renderCalls++; return { svg: '<svg>cached</svg>' }; } }
  };
  vm.runInNewContext(fs.readFileSync(INIT_PATH, 'utf8'), context);
  await onLoad();
  await onLoad();
  assert.equal(renderCalls, 1);
  assert.equal(context.window.__peleRenderStats.renders, 1);
  assert.equal(context.window.__peleRenderStats.cacheHits, 1);
  assert.match(pre.outerHTML, /<svg>cached<\/svg><\/span>$/);
  process.stdout.write('Pele caches by source hash: passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Theme follows the computed body background; transparent counts as light.
(async function () {
  async function runWithBackground(backgroundColor) {
    let onLoad;
    const pre = { tagName: 'PRE' };
    const code = { textContent: 'graph TD', parentElement: pre };
    const context = {
      document: {
        readyState: 'complete', body: { contains: () => true },
        querySelectorAll: () => [code],
        createElement: makeElement
      },
      getComputedStyle: () => ({ backgroundColor }),
      window: { addEventListener: (event, callback) => { onLoad = callback; } },
      console: { warn() {}, error() {} },
      pele: { render: () => ({ svg: '<svg>t</svg>' }) }
    };
    vm.runInNewContext(fs.readFileSync(INIT_PATH, 'utf8'), context);
    await onLoad();
    return pre.outerHTML;
  }
  const dark = await runWithBackground('rgb(30, 30, 30)');
  assert.match(dark, /--pele-bg:#1e1e1e;/);
  const light = await runWithBackground('rgb(255, 255, 255)');
  assert.match(light, /--pele-bg:#fff;/);
  const transparent = await runWithBackground('rgba(0, 0, 0, 0)');
  assert.match(transparent, /--pele-bg:#fff;/);
  process.stdout.write('Pele theme follows background: passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
