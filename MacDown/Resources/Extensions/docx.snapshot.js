// docx snapshot (evaluated on demand in an offscreen export WebView,
// never auto-loaded). Walks the rendered body and builds a JSON document
// model for the native DOCX writer: {meta, blocks}. Diagrams are rasterized
// to PNG data URLs; their SVG is serialized with CSS var() fallbacks
// resolved (export pins the light theme), so Word needs no variables.
(function () {

  function textOf(node) {
    return node.textContent || '';
  }

  // Runs contributed by one element. Handles elements that do not recurse
  // (images, checkboxes, breaks, MathJax source) and applies the element's
  // own inline semantics (bold/italic/code/strike/link) to its children.
  function elementRuns(node, flags) {
    flags = flags || {};
    var tag = node.tagName;
    if (tag === 'SCRIPT' && node.type && node.type.indexOf('math') !== -1) {
      return [{ text: textOf(node), code: true }];
    }
    if (tag === 'BR') {
      return [{ text: '\n' }];
    }
    if (tag === 'IMG') {
      return [{ img: node.src || null,
                width: node.naturalWidth || node.width || 0,
                height: node.naturalHeight || node.height || 0 }];
    }
    if (tag === 'INPUT' && node.type === 'checkbox') {
      return [{ text: node.checked ? '\u2611 ' : '\u2610 ' }];
    }
    var child = { bold: !!flags.bold || tag === 'B' || tag === 'STRONG',
                  italic: !!flags.italic || tag === 'I' || tag === 'EM',
                  code: !!flags.code || tag === 'CODE',
                  strike: !!flags.strike || tag === 'S' || tag === 'DEL' ||
                          tag === 'STRIKE',
                  link: (tag === 'A' && node.href) ? node.href : (flags.link || null) };
    return runsOf(node, child);
  }

  // Inline runs of an element: [{text, bold, italic, code, strike, link}]
  // plus {img} runs for images. Prism token spans collapse to plain runs
  // (the writer styles code monospace).
  function runsOf(el, flags) {
    flags = flags || {};
    var runs = [];
    var nodes = el.childNodes;
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (node.nodeType === 3) {
        if (node.nodeValue) {
          runs.push({ text: node.nodeValue, bold: !!flags.bold,
                      italic: !!flags.italic, code: !!flags.code,
                      strike: !!flags.strike, link: flags.link || null });
        }
        continue;
      }
      if (node.nodeType !== 1) continue;
      var inner = elementRuns(node, flags);
      for (var j = 0; j < inner.length; j++) runs.push(inner[j]);
    }
    return runs;
  }

  // Runs of a list item: its inline content plus the text of its own
  // paragraphs (Hoedown wraps items of a loose list in <p>), excluding
  // nested lists, which become items of their own at level + 1.
  function listItemRuns(li) {
    var runs = [];
    var nodes = li.childNodes;
    var afterParagraph = false;
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.nodeType === 3) {
        if (n.nodeValue) runs.push({ text: n.nodeValue });
        continue;
      }
      if (n.nodeType !== 1) continue;
      if (n.tagName === 'UL' || n.tagName === 'OL') continue;
      if (n.tagName === 'P') {
        if (afterParagraph) runs.push({ text: '\n' });
        afterParagraph = true;
        var pruns = runsOf(n, {});
        for (var p = 0; p < pruns.length; p++) runs.push(pruns[p]);
        continue;
      }
      var inner = elementRuns(n, {});
      for (var j = 0; j < inner.length; j++) runs.push(inner[j]);
    }
    return runs;
  }

  // Walks a list, emitting items at their real nesting depth.
  function collectListItems(listEl, level, out) {
    var children = listEl.children || listEl.childNodes;
    for (var i = 0; i < children.length; i++) {
      var li = children[i];
      if (!li || li.nodeType !== 1 || li.tagName !== 'LI') continue;
      out.push({ runs: listItemRuns(li), level: level });
      var sub = li.children || [];
      for (var s = 0; s < sub.length; s++) {
        if (sub[s].nodeType === 1 &&
            (sub[s].tagName === 'UL' || sub[s].tagName === 'OL')) {
          collectListItems(sub[s], level + 1, out);
        }
      }
    }
  }

  function hasImage(runs) {
    for (var i = 0; i < runs.length; i++) {
      if (runs[i].img) return true;
    }
    return false;
  }

  // Table block for a <table> element (or null when it has no rows).
  function tableBlock(node) {
    var rows = [];
    var trs = node.querySelectorAll('tr');
    for (var r = 0; r < trs.length; r++) {
      var cells = [];
      var tds = trs[r].childNodes;
      for (var c = 0; c < tds.length; c++) {
        var td = tds[c];
        if (td.nodeType === 1 && (td.tagName === 'TD' || td.tagName === 'TH')) {
          cells.push({ runs: runsOf(td, {}),
                       header: td.tagName === 'TH' });
        }
      }
      if (cells.length) rows.push(cells);
    }
    return rows.length ? { t: 'table', rows: rows } : null;
  }

  function hasText(runs) {
    for (var i = 0; i < runs.length; i++) {
      if (runs[i].text && /\S/.test(runs[i].text)) return true;
    }
    return false;
  }

  // Block-level walk. Returns array of blocks; transparent containers
  // (DIV, SPAN) recurse. Returns null for consumed MathJax output.
  function blocksOf(el, out) {
    out = out || [];
    var nodes = el.childNodes;
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (node.nodeType === 3) {
        if (/\S/.test(node.nodeValue || '')) {
          out.push({ t: 'p', runs: [{ text: node.nodeValue }] });
        }
        continue;
      }
      if (node.nodeType !== 1) continue;
      var tag = node.tagName;
      if (tag === 'SCRIPT' || tag === 'STYLE') continue;
      // Rendered MathJax output duplicates the kept <script type=math> node.
      if (node.className && /(^|\s)MathJax/.test(node.className)) continue;
      if (tag === 'SPAN' && node.className === 'pele-diagram') {
        out.push({ t: 'diagram', ref: (out._diagrams = out._diagrams || []).length });
        out._diagrams.push(node);
        continue;
      }
      // Graphviz (viz.init.js) replaces the code block with a bare <svg>.
      // In an HTML document SVG elements keep lowercase tagName.
      if (tag === 'svg' || tag === 'SVG') {
        out.push({ t: 'diagram', ref: (out._diagrams = out._diagrams || []).length });
        out._diagrams.push(node);
        continue;
      }
      if (tag === 'PRE' && node.className === 'pele-error') {
        out.push({ t: 'code', text: textOf(node) });
        continue;
      }
      if (/^H[1-6]$/.test(tag)) {
        var hruns = runsOf(node, {});
        if (hasText(hruns) || hasImage(hruns)) {
          out.push({ t: 'h', level: +tag[1], runs: hruns });
        }
        continue;
      }
      if (tag === 'P') {
        // Markdown images live inside paragraphs as <img> runs. Text goes to
        // the paragraph; images become their own image blocks, otherwise
        // they would be dropped (the writer cannot inline them).
        var pruns = runsOf(node, {});
        var textRuns = [];
        for (var pr = 0; pr < pruns.length; pr++) {
          if (pruns[pr].img) {
            out.push({ t: 'img', src: pruns[pr].img,
                       width: pruns[pr].width, height: pruns[pr].height });
          } else {
            textRuns.push(pruns[pr]);
          }
        }
        if (hasText(textRuns)) out.push({ t: 'p', runs: textRuns });
        continue;
      }
      if (tag === 'UL' || tag === 'OL') {
        var items = [];
        collectListItems(node, 0, items);
        if (items.length) {
          out.push({ t: 'list', ordered: tag === 'OL', items: items });
        }
        continue;
      }
      if (tag === 'TABLE') {
        var table = tableBlock(node);
        if (table) out.push(table);
        continue;
      }
      if (tag === 'PRE') {
        out.push({ t: 'code', text: textOf(node) });
        continue;
      }
      if (tag === 'BLOCKQUOTE') {
        // Walk the quote's own blocks: each paragraph is a separate quote
        // block, lists inside a quote keep their structure, and anything
        // else recurses so no content is dropped.
        var qkids = node.children || [];
        var emitted = 0;
        for (var qk = 0; qk < qkids.length; qk++) {
          var qc = qkids[qk];
          if (qc.nodeType !== 1) continue;
          if (qc.tagName === 'P') {
            var qruns = runsOf(qc, {});
            if (hasText(qruns) || hasImage(qruns)) {
              out.push({ t: 'quote', runs: qruns });
              emitted++;
            }
          } else if (/^H[1-6]$/.test(qc.tagName)) {
            var qh = runsOf(qc, {});
            if (hasText(qh) || hasImage(qh)) {
              out.push({ t: 'h', level: +qc.tagName[1], runs: qh });
              emitted++;
            }
          } else if (qc.tagName === 'PRE') {
            out.push({ t: 'code', text: textOf(qc) });
            emitted++;
          } else if (qc.tagName === 'UL' || qc.tagName === 'OL') {
            var qitems = [];
            collectListItems(qc, 0, qitems);
            if (qitems.length) {
              out.push({ t: 'list', ordered: qc.tagName === 'OL', items: qitems });
              emitted++;
            }
          } else if (qc.tagName === 'TABLE') {
            var qtable = tableBlock(qc);
            if (qtable) {
              out.push(qtable);
              emitted++;
            }
          } else if (qc.tagName === 'HR') {
            out.push({ t: 'hr' });
            emitted++;
          } else {
            blocksOf(qc, out);
            emitted++;
          }
        }
        if (!emitted) {
          var qall = runsOf(node, {});
          if (hasText(qall) || hasImage(qall)) out.push({ t: 'quote', runs: qall });
        }
        continue;
      }
      if (tag === 'HR') {
        out.push({ t: 'hr' });
        continue;
      }
      if (tag === 'IMG') {
        out.push({ t: 'img', src: node.src || null,
                   width: node.naturalWidth || node.width || 0,
                   height: node.naturalHeight || node.height || 0 });
        continue;
      }
      // Transparent wrapper (DIV, SPAN, SECTION, ...): recurse.
      blocksOf(node, out);
    }
    return out;
  }

  function svgSize(svg) {
    var w = (svg.width && svg.width.baseVal && svg.width.baseVal.value) || 0;
    var h = (svg.height && svg.height.baseVal && svg.height.baseVal.value) || 0;
    if (!w || !h) {
      var r = svg.getBoundingClientRect();
      w = w || r.width;
      h = h || r.height;
    }
    return { w: Math.max(1, Math.round(w)), h: Math.max(1, Math.round(h)) };
  }

  function rasterize(svg, scale) {
    return new Promise(function (resolve) {
      try {
        var xml = new XMLSerializer().serializeToString(svg);
        var blob = new Blob([xml], { type: 'image/svg+xml;charset=utf-8' });
        var URL_ = window.URL || window.webkitURL;
        var url = URL_.createObjectURL(blob);
        var img = new Image();
        img.onload = function () {
          try {
            var size = svgSize(svg);
            var c = document.createElement('canvas');
            c.width = size.w * scale;
            c.height = size.h * scale;
            c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
            resolve(c.toDataURL('image/png'));
          } catch (e) {
            resolve(null);
          }
          URL_.revokeObjectURL(url);
        };
        img.onerror = function () {
          URL_.revokeObjectURL(url);
          resolve(null);
        };
        img.src = url;
      } catch (e) {
        resolve(null);
      }
    });
  }

  // Resolves every var(--name[, fallback]) in a serialized SVG against the
  // live element's computed style. Pele also emits bare var(--name) with no
  // fallback (e.g. fill="var(--_fg)"); Word cannot resolve variables at all
  // and rejects the document, so unresolvable-with-fallback falls back to
  // the fallback, and only a truly unknown variable is kept as-is.
  function resolveVars(svg, xml) {
    var lookup = {};
    try {
      var cs = getComputedStyle(svg);
      var names = {};
      xml.replace(/var\(--([\w-]+)/g, function (m, n) {
        names[n] = 1;
        return m;
      });
      for (var n in names) {
        if (!names.hasOwnProperty(n)) continue;
        var v = cs.getPropertyValue('--' + n);
        if (v && v.trim()) lookup[n] = v.trim();
      }
    } catch (e) { /* fallbacks apply */ }
    return xml.replace(/var\(--([\w-]+)(?:,([^)]*))?\)/g,
      function (m, n, fb) {
        if (lookup.hasOwnProperty(n)) return lookup[n];
        if (fb !== undefined) return fb;
        return m;
      });
  }

  // Entry point called by ObjC after diagrams render. Resolves
  // window.__docxResult to the JSON model string (never throws outward).
  window.__docxRunSnapshot = function () {
    try {
      var model = { meta: {}, blocks: [] };
      try {
        var cs = getComputedStyle(document.body);
        model.meta.fontFamily = cs.fontFamily || '';
        model.meta.fontSize = cs.fontSize || '';
      } catch (e) { /* defaults apply */ }
      var acc = blocksOf(document.body, []);
      var spans = acc._diagrams || [];
      delete acc._diagrams;
      var jobs = [];
      for (var i = 0; i < spans.length; i++) {
        /* jshint loopfunc: true */
        jobs.push((function (span) {
          var svg = (span.tagName && span.tagName.toLowerCase() === 'svg')
              ? span : span.querySelector('svg');
          if (!svg) return Promise.resolve(null);
          var size = svgSize(svg);
          var xml = new XMLSerializer().serializeToString(svg);
          // Resolve CSS variables to concrete values: export pins the light
          // theme, and Word knows no variables.
          var light = resolveVars(svg, xml);
          return rasterize(svg, 2).then(function (png) {
            return { w: size.w, h: size.h, svg: light, png: png };
          });
        })(spans[i]));
      }
      Promise.all(jobs).then(function (diagrams) {
        var out = [];
        for (var k = 0; k < acc.length; k++) {
          var b = acc[k];
          if (b.t === 'diagram') {
            var d = diagrams[b.ref];
            if (d) out.push({ t: 'diagram', w: d.w, h: d.h,
                              svg: d.svg, png: d.png });
            // else: diagram vanished mid-snapshot; drop it.
          } else {
            out.push(b);
          }
        }
        model.blocks = out;
        window.__docxResult = JSON.stringify(model);
      }, function (e) {
        window.__docxResult = 'ERROR:' + (e && e.message || e);
      });
    } catch (e) {
      window.__docxResult = 'ERROR:' + (e && e.message || e);
    }
  };
})();
