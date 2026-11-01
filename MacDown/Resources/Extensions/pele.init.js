// init pele (Pele 1.13.0, MIT)
// Renders pre>code.language-mermaid blocks via pele.render and
// replaces each <pre> with the resulting SVG. Mirrors the structure of
// the former mermaid.init.js, including the MutationObserver for DOM
// replacement re-rendering (GitHub issue #331).

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
          // Pele's render returns { svg, width, height, ... } (awaited for
          // safety; a plain value simply passes through).
          var result = await pele.render(graphSource, { idPrefix: uniqueId });
          if (document.body.contains(pre)) pre.outerHTML = result.svg;
        } catch (error) {
          console.error('Pele rendering error:', error);
          // Display error message in place of the <pre>. textContent only:
          // never innerHTML, so a hostile diagram source cannot inject markup.
          var errorElement = document.createElement('pre');
          errorElement.style.cssText = 'color: red; padding: 10px; background: #fee;';
          errorElement.textContent = 'Pele Error: ' + (error.message || error);
          if (document.body.contains(pre) && pre.parentNode) pre.parentNode.replaceChild(errorElement, pre);
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
