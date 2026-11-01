// init pele (Pele 1.13.0, MIT)
// Renders pre>code.language-mermaid blocks via pele.render and replaces
// each <pre> with the resulting SVG wrapped in a theme-variable span.
// Results are cached by source hash so live-preview re-renders (which
// replace body.innerHTML on every keystroke) don't re-invoke Pele.
// Mirrors the structure of the former mermaid.init.js, including the
// MutationObserver for DOM replacement re-rendering (GitHub issue #331).

(function () {

  // Check if Pele library is loaded. Note: the UMD global build exposes
  // the synchronous render/mount API from core (not the renderAsync of the
  // ESM lazy entry point).
  if (typeof pele === 'undefined' || typeof pele.render !== 'function') {
    console.warn('Pele library not loaded');
    return;
  }

  // Generate unique ID to avoid collisions on re-renders.
  // The 'mermaid_' prefix is kept so existing CSS (export.css) and tests
  // that match svg[id^="mermaid_"] keep working.
  var renderCount = 0;
  var sessionId = Date.now().toString(36) + Math.random().toString(36).substr(2, 5);

  // Guard against re-entrant calls (e.g. MutationObserver firing during render).
  // The primary safety net is the domAll.length === 0 check below, which prevents
  // unnecessary re-renders once all .language-mermaid elements have been replaced
  // with SVGs. This flag is an additional belt-and-suspenders measure.
  var rendering = false;
  var renderRequested = false;

  // Render cache: source hash -> SVG markup, bounded FIFO so long editing
  // sessions don't grow memory without limit.
  var svgCache = {};
  var svgCacheOrder = [];
  var SVG_CACHE_LIMIT = 50;

  // Observable counters for tests: real Pele invocations vs cache hits.
  window.__peleRenderStats = { renders: 0, cacheHits: 0 };

  // FNV-1a hash, base36-encoded. Collisions across distinct diagram
  // sources are vanishingly unlikely at this scale.
  function hashSource(source) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < source.length; i++) {
      hash ^= source.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0).toString(36);
  }

  // Theme variable sets. Light matches Pele's built-in defaults; dark is
  // tuned for dark preview styles (Clearness Dark, Github2 (dark), ...).
  var LIGHT_VARS = {
    'bg': '#fff', 'fg': '#1f1f1f',
    'surface': '#f3f3f3', 'surface-alt': '#e6e6e6',
    'border': '#8a8a8a', 'line': '#1f1f1f', 'muted': '#6e6e6e',
    'accent': '#5b7bd5', 'critical': '#e45756', 'error': '#e45756',
    'fg-on-dark': '#fff', 'fg-on-light': '#1f1f1f'
  };
  var DARK_VARS = {
    'bg': '#1e1e1e', 'fg': '#e8e8e8',
    'surface': '#2d2d2d', 'surface-alt': '#3d3d3d',
    'border': '#707070', 'line': '#c9c9c9', 'muted': '#a6a6a6',
    'accent': '#93a5e8', 'critical': '#ef7b7a', 'error': '#ef7b7a',
    'fg-on-dark': '#fff', 'fg-on-light': '#1f1f1f'
  };

  // Pick the variable set from the preview body's background luminance,
  // so diagrams follow the active preview style without Obj-C plumbing.
  function currentThemeVars() {
    try {
      if (document && document.body &&
          typeof getComputedStyle === 'function') {
        var bg = getComputedStyle(document.body).backgroundColor;
        var m = bg && bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
        // Fully transparent (unstyled page default) counts as light.
        if (m && !(m[4] !== undefined && (+m[4]) === 0)) {
          var luminance = 0.299 * (+m[1]) + 0.587 * (+m[2]) + 0.114 * (+m[3]);
          if (luminance < 128) return DARK_VARS;
        }
      }
    } catch (e) { /* fall through to light */ }
    return LIGHT_VARS;
  }

  function wrapThemed(svg, vars) {
    var style = 'display:block;';
    for (var name in vars) {
      if (vars.hasOwnProperty(name)) {
        style += '--pele-' + name + ':' + vars[name] + ';';
      }
    }
    return '<span class="pele-diagram" style="' + style + '">' +
           svg + '</span>';
  }

  // Error block: message plus the offending source, built with DOM APIs
  // (textContent only) so a hostile diagram source cannot inject markup.
  function showError(pre, message, source) {
    var errorElement = document.createElement('pre');
    errorElement.className = 'pele-error';
    errorElement.style.cssText = 'color: red; padding: 10px; background: #fee;';
    var messageElement = document.createElement('div');
    messageElement.textContent = 'Pele Error: ' + message;
    var sourceElement = document.createElement('code');
    sourceElement.textContent = source;
    errorElement.appendChild(messageElement);
    errorElement.appendChild(sourceElement);
    if (document.body.contains(pre) && pre.parentNode) {
      pre.parentNode.replaceChild(errorElement, pre);
    }
  }

  var init = async function() {
    if (rendering) {
      renderRequested = true;
      return;
    }

    var domAll = document.querySelectorAll(".language-mermaid");
    if (domAll.length === 0) return;

    rendering = true;
    try {
      for (var i = 0; i < domAll.length; i++) {
        var codeElement = domAll[i];
        var graphSource = codeElement.innerText || codeElement.textContent;

        // The <code> element is always inside a <pre>. Replace the <pre>
        // directly using outerHTML so that sibling <pre> elements (other
        // diagrams in the same document) are not destroyed (GitHub issue #331).
        var pre = codeElement.parentElement;
        if (!pre || pre.tagName !== "PRE") {
          console.warn('Pele: unexpected DOM structure, skipping element');
          codeElement.classList.remove('language-mermaid');
          continue;
        }

        // Generate unique ID to prevent collisions on document re-renders
        var uniqueId = 'mermaid_' + sessionId + '_' + (renderCount++);

        try {
          var key = hashSource(graphSource);
          var svg = svgCache[key];
          if (svg) {
            window.__peleRenderStats.cacheHits++;
          } else {
            // Pele's render returns { svg, width, height, ... } (awaited
            // for safety; a plain value simply passes through).
            var result = await pele.render(graphSource, { idPrefix: uniqueId });
            if (!result || typeof result.svg !== 'string') {
              throw new Error('empty render result');
            }
            svg = result.svg;
            window.__peleRenderStats.renders++;
            svgCache[key] = svg;
            svgCacheOrder.push(key);
            if (svgCacheOrder.length > SVG_CACHE_LIMIT) {
              delete svgCache[svgCacheOrder.shift()];
            }
          }
          if (document.body.contains(pre)) {
            pre.outerHTML = wrapThemed(svg, currentThemeVars());
          }
        } catch (error) {
          console.error('Pele rendering error:', error);
          showError(pre, (error && error.message) || error, graphSource);
        }
      }
    } finally {
      rendering = false;
      if (renderRequested) {
        renderRequested = false;
        setTimeout(init, 0);
      }
    }
  };

  // Initial render on page load
  if (typeof window.addEventListener != "undefined") {
    window.addEventListener("load", init, false);
  } else {
    window.attachEvent("onload", init);
  }

  // Re-render on DOM replacement (GitHub issue #331).
  // When MPDocument.m replaces body.innerHTML, the window.load event does not
  // fire again. A MutationObserver detects new .language-mermaid elements and
  // triggers rendering automatically. After rendering, those elements are
  // replaced with SVGs, so there is no risk of infinite re-trigger loops.
  if (typeof MutationObserver !== 'undefined') {
    var observer = new MutationObserver(function() {
      if (document.querySelectorAll(".language-mermaid").length > 0) {
        init();
      }
    });

    var startObserving = function() {
      if (document.body) {
        observer.observe(document.body, { childList: true, subtree: true });
      }
    };

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', startObserving);
    } else {
      startObserving();
    }
  }
})();
