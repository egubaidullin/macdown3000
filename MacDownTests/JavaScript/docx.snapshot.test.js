'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SNAPSHOT_PATH = path.join(__dirname,
  '../../MacDown/Resources/Extensions/docx.snapshot.js');

// Bare var(--name) without fallback must resolve via computed style;
// var(--name, fallback) must resolve or fall back. Word rejects documents
// whose SVG still contains var() references.
(async function () {
  const svgEl = {
    getBoundingClientRect: () => ({ width: 100, height: 50 }),
    width: { baseVal: { value: 100 } },
    height: { baseVal: { value: 50 } }
  };
  const span = { nodeType: 1, tagName: 'SPAN', className: 'pele-diagram',
    childNodes: [], querySelector: (sel) => sel === 'svg' ? svgEl : null };
  const context = {
    document: {
      readyState: 'complete',
      body: { contains: () => true, childNodes: [span] },
      querySelectorAll: (sel) => sel === 'span.pele-diagram' ? [span] : [],
      createElement: () => ({
        width: 0, height: 0,
        getContext: () => ({ drawImage() {} }),
        toDataURL: () => 'data:image/png;base64,AAA'
      })
    },
    XMLSerializer: class {
      serializeToString() {
        return '<svg fill="var(--_fg)" stroke="var(--nope,#123456)"><rect/></svg>';
      }
    },
    Blob: class {},
    Image: class {
      set src(v) {
        const self = this;
        setTimeout(() => self.onload(), 0);
      }
    },
    getComputedStyle: () => ({
      backgroundColor: 'rgb(255, 255, 255)',
      getPropertyValue: (name) => name === '--_fg' ? 'rgb(31, 31, 31)' : ''
    }),
    window: {
      URL: { createObjectURL: () => 'blob:x', revokeObjectURL() {} }
    },
    setTimeout: (callback) => { callback(); },
    console: { warn() {}, error() {} }
  };
  context.window.window = context.window;
  vm.runInNewContext(fs.readFileSync(SNAPSHOT_PATH, 'utf8'), context);
  context.window.__docxRunSnapshot();
  await new Promise((resolve) => setTimeout(resolve, 50));
  const model = JSON.parse(context.window.__docxResult);
  assert.equal(model.blocks.length, 1);
  const svg = model.blocks[0].svg;
  assert.match(svg, /fill="rgb\(31, 31, 31\)"/);
  assert.match(svg, /stroke="#123456"/);
  assert.doesNotMatch(svg, /var\(--/);
  process.stdout.write('Docx snapshot resolves CSS vars: passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
