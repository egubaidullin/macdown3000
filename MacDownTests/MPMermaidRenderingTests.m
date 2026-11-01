//
//  MPMermaidRenderingTests.m
//  MacDownTests
//
//  Tests for Pele diagram rendering (```mermaid blocks) in the Obj-C pipeline.
//  Verifies that Pele scripts are included/excluded correctly,
//  code blocks get the proper language class, and rendering
//  survives preference changes and re-renders.
//
//  Related to #331
//

#import <XCTest/XCTest.h>
#import "MPRenderer.h"
#import "MPRendererTestHelpers.h"
#import "hoedown/document.h"
#import <WebKit/WebKit.h>
#import "WebView+WebViewPrivateHeaders.h"


#pragma mark - Test Class

@interface MPMermaidRenderingTests : XCTestCase
@property (nonatomic, strong) MPRenderer *renderer;
@property (nonatomic, strong) MPMockRendererDataSource *dataSource;
@property (nonatomic, strong) MPMockRendererDelegate *delegate;
@end


@implementation MPMermaidRenderingTests

- (void)setUp
{
    [super setUp];
    self.dataSource = [[MPMockRendererDataSource alloc] init];
    self.delegate = [[MPMockRendererDelegate alloc] init];

    self.renderer = [[MPRenderer alloc] init];
    self.renderer.dataSource = self.dataSource;
    self.renderer.delegate = self.delegate;
}

- (void)tearDown
{
    self.renderer = nil;
    self.dataSource = nil;
    self.delegate = nil;
    [super tearDown];
}


#pragma mark - Basic Mermaid Code Block Rendering

- (void)testMermaidCodeBlockProducesLanguageClass
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    XCTAssertTrue([html containsString:@"language-mermaid"],
                  @"Mermaid code block should have language-mermaid class");
}

- (void)testMermaidCodeBlockPreservesGraphSource
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    // The graph source should survive parsing (possibly HTML-escaped)
    XCTAssertTrue([html containsString:@"graph TD"] ||
                  [html containsString:@"graph TD;"],
                  @"Graph source text should be preserved in HTML output");
    XCTAssertTrue([html containsString:@"A--&gt;B"] ||
                  [html containsString:@"A-->B"],
                  @"Graph edges should be preserved (escaped or literal)");
}

- (void)testMermaidCodeBlockWithoutFencedCodeExtension
{
    self.delegate.extensions = 0;  // No fenced code extension
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    XCTAssertFalse([html containsString:@"language-mermaid"],
                   @"Without fenced code extension, no language-mermaid class");
}


#pragma mark - Pele Script Inclusion

- (void)testMermaidScriptsIncludedWhenEnabled
{
    self.delegate.mermaid = YES;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // Use render (MPAssetFullLink) so script URLs contain filenames
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];

    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.global.js"],
                  @"Should include Pele library");
    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.init.js"],
                  @"Should include Pele init script");
}

- (void)testMermaidScriptsExcludedWhenDisabled
{
    self.delegate.mermaid = NO;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // Use render (MPAssetFullLink) so script URLs contain filenames
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];

    XCTAssertFalse([self.delegate.lastHTML containsString:@"pele.global.js"],
                   @"Should NOT include Pele library when disabled");
    XCTAssertFalse([self.delegate.lastHTML containsString:@"pele.init.js"],
                   @"Should NOT include Pele init script when disabled");
}

- (void)testMermaidScriptsIncludedWhenSyntaxHighlightingDisabled
{
    self.delegate.mermaid = YES;
    self.delegate.syntaxHighlighting = NO;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // Use render (MPAssetFullLink) so script URLs contain filenames
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];

    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.global.js"],
                  @"Should include Pele library");
    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.init.js"],
                  @"Should include Pele init script");
}

- (void)testPrismScriptsExcludedWhenSyntaxHighlightingDisabledWithMermaidEnabled
{
    self.delegate.mermaid = YES;
    self.delegate.syntaxHighlighting = NO;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // Use render (MPAssetFullLink) so script URLs contain filenames
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];

    XCTAssertFalse([self.delegate.lastHTML containsString:@"prism-core.min.js"],
                   @"Should NOT include Prism when syntax highlighting is "
                   @"disabled, even though Mermaid is enabled");
    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.global.js"],
                  @"Should still include Pele library");
    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.init.js"],
                  @"Should still include Pele init script");
}


#pragma mark - Preference Change Detection

- (void)testRenderIfPreferencesChangedDetectsMermaidToggle
{
    self.delegate.mermaid = NO;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // Initial render to cache state
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];
    self.delegate.lastHTML = nil;

    // Toggle mermaid on
    self.delegate.mermaid = YES;
    [self.renderer renderIfPreferencesChanged];

    XCTAssertNotNil(self.delegate.lastHTML,
                    @"Toggling mermaid should trigger a re-render");
}

- (void)testRenderIfPreferencesChangedIgnoresWhenMermaidUnchanged
{
    self.delegate.mermaid = YES;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // Initial render to cache state
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];
    self.delegate.lastHTML = nil;

    // No change
    [self.renderer renderIfPreferencesChanged];

    XCTAssertNil(self.delegate.lastHTML,
                 @"Should NOT re-render when mermaid preference is unchanged");
}

- (void)testStyleNameChangeTriggersReRender
{
    self.delegate.mermaid = YES;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.styleName = @"GitHub2";
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // Initial render
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];
    self.delegate.lastHTML = nil;

    // Change theme
    self.delegate.styleName = @"Clearness";
    [self.renderer renderIfPreferencesChanged];

    XCTAssertNotNil(self.delegate.lastHTML,
                    @"Changing theme should trigger re-render (full reload path)");
}


#pragma mark - Multiple Mermaid Diagrams and Mixed Content

- (void)testMultipleMermaidDiagramsInSameDocument
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.dataSource.markdown =
        @"```mermaid\ngraph TD;\n    A-->B;\n```\n\n"
        @"Some text\n\n"
        @"```mermaid\nsequenceDiagram\n    Alice->>Bob: Hello\n```";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    // Count occurrences of language-mermaid
    NSUInteger count = 0;
    NSRange searchRange = NSMakeRange(0, html.length);
    while (searchRange.location < html.length) {
        NSRange found = [html rangeOfString:@"language-mermaid"
                                   options:0
                                     range:searchRange];
        if (found.location == NSNotFound) break;
        count++;
        searchRange.location = found.location + found.length;
        searchRange.length = html.length - searchRange.location;
    }

    XCTAssertEqual(count, 2,
                   @"Both mermaid blocks should have language-mermaid class");
}

- (void)testMermaidWithOtherFencedCodeBlocks
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.dataSource.markdown =
        @"```mermaid\ngraph TD;\n    A-->B;\n```\n\n"
        @"```javascript\nconst x = 1;\n```";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    XCTAssertTrue([html containsString:@"language-mermaid"],
                  @"Should contain mermaid code block");
    XCTAssertTrue([html containsString:@"language-javascript"],
                  @"Should contain javascript code block alongside mermaid");
}

- (void)testMermaidDiagramTypesPreserved
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.dataSource.markdown =
        @"```mermaid\ngraph TD;\n    A-->B;\n```\n\n"
        @"```mermaid\nsequenceDiagram\n    Alice->>Bob: Hello\n```\n\n"
        @"```mermaid\ngantt\n    title A Gantt\n    section S1\n    Task1 :a1, 2024-01-01, 30d\n```";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    XCTAssertTrue([html containsString:@"graph TD"],
                  @"Flow chart source should be preserved");
    XCTAssertTrue([html containsString:@"sequenceDiagram"],
                  @"Sequence diagram source should be preserved");
    XCTAssertTrue([html containsString:@"gantt"],
                  @"Gantt chart source should be preserved");
}


#pragma mark - Edge Cases

- (void)testEmptyMermaidCodeBlock
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.dataSource.markdown = @"```mermaid\n\n```";

    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    XCTAssertNotNil(html, @"Should not crash on empty mermaid block");
    XCTAssertTrue([html containsString:@"language-mermaid"],
                  @"Empty mermaid block should still have language class");
}

- (void)testMermaidAfterReparse
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;

    // First parse: plain markdown
    self.dataSource.markdown = @"# Hello";
    [self.renderer parseMarkdown:self.dataSource.markdown];

    // Second parse: mermaid
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";
    [self.renderer parseMarkdown:self.dataSource.markdown];
    NSString *html = [self.renderer currentHtml];

    XCTAssertTrue([html containsString:@"language-mermaid"],
                  @"Re-parse should produce mermaid content");
    XCTAssertFalse([html containsString:@"Hello"],
                   @"Previous parse content should be gone");
}

- (void)testMermaidDisabledAfterBeingEnabled
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.dataSource.markdown = @"```mermaid\ngraph TD;\n    A-->B;\n```";

    // First: enabled — use render (MPAssetFullLink) for filename checks
    self.delegate.mermaid = YES;
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];
    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.global.js"],
                  @"Should include mermaid scripts when enabled");

    // Second: disabled
    self.delegate.mermaid = NO;
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];
    XCTAssertFalse([self.delegate.lastHTML containsString:@"pele.global.js"],
                   @"Should exclude mermaid scripts after disabling");
}


#pragma mark - Mermaid with Other Features

- (void)testMermaidWithMathJax
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.delegate.mathJax = YES;
    self.dataSource.markdown =
        @"```mermaid\ngraph TD;\n    A-->B;\n```\n\nInline math: $x^2$";

    // Use render (MPAssetFullLink) for filename checks
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];

    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.init.js"],
                  @"Should include mermaid init script");
    XCTAssertTrue([self.delegate.lastHTML containsString:@"MathJax.js"],
                  @"Should include MathJax script alongside mermaid");
}

- (void)testMermaidWithGraphviz
{
    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.syntaxHighlighting = YES;
    self.delegate.mermaid = YES;
    self.delegate.graphviz = YES;
    self.dataSource.markdown =
        @"```mermaid\ngraph TD;\n    A-->B;\n```\n\n"
        @"```dot\ndigraph G { A -> B }\n```";

    // Use render (MPAssetFullLink) for filename checks
    [self.renderer parseMarkdown:self.dataSource.markdown];
    [self.renderer render];

    XCTAssertTrue([self.delegate.lastHTML containsString:@"pele.init.js"],
                  @"Should include mermaid init script");
    XCTAssertTrue([self.delegate.lastHTML containsString:@"viz.init.js"],
                  @"Should include graphviz init script alongside mermaid");
}

#pragma mark - Live Rendering In WebView

// Spins the main run loop until condition returns YES or timeout elapses.
static BOOL MPPeleSpinUntil(NSTimeInterval timeout, BOOL (^condition)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
    {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

// Loads the bundled Pele library and pele.init.js into a legacy WebView.
// On success returns YES with the live objects in outView/outWindow
// (caller closes them).
- (BOOL)peleLoadTestPage:(WebView **)outView window:(NSWindow **)outWindow
{
    NSURL *peleURL = [[NSBundle mainBundle] URLForResource:@"pele.global"
                                             withExtension:@"js"
                                              subdirectory:@"Extensions"];
    XCTAssertNotNil(peleURL, @"The bundled Pele library is missing");
    if (!peleURL)
        return NO;
    NSURL *baseURL = peleURL.URLByDeletingLastPathComponent;

    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 800, 600)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;  // ARC owns the window.
    WebView *webView = [[WebView alloc]
        initWithFrame:NSMakeRect(0, 0, 800, 600)];
    window.contentView = webView;

    NSString *html =
        @"<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
         "<script src=\"pele.global.js\"></script>"
         "<script src=\"pele.init.js\"></script>"
         "</head><body></body></html>";
    [webView.mainFrame loadHTMLString:html baseURL:baseURL];
    BOOL loaded = MPPeleSpinUntil(20.0, ^{
        return (BOOL)(!webView.isLoading && [[webView
            stringByEvaluatingJavaScriptFromString:
                @"String(document.readyState === 'complete' && "
                 "typeof pele !== 'undefined' && "
                 "typeof pele.render === 'function')"]
            isEqualToString:@"true"]);
    });
    XCTAssertTrue(loaded, @"The page with Pele did not finish loading");
    if (!loaded)
    {
        [webView close];
        [window close];
        return NO;
    }
    *outView = webView;
    *outWindow = window;
    return YES;
}

// Escapes a diagram source for embedding in a JS string literal.
- (NSString *)peleEscapeSource:(NSString *)source
{
    return [[[[source
        stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]
        stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
}

// Injects one ```mermaid block with the given source into the page.
- (void)peleInjectSource:(NSString *)source intoWebView:(WebView *)webView
{
    NSString *injectJS = [NSString stringWithFormat:
        @"var pre = document.createElement('pre');"
         "var code = document.createElement('code');"
         "code.className = 'language-mermaid';"
         "code.textContent = '%@';"
         "pre.appendChild(code); document.body.appendChild(pre);",
        [self peleEscapeSource:source]];
    [webView stringByEvaluatingJavaScriptFromString:injectJS];
}

// Loads the bundled Pele library and pele.init.js into a legacy WebView,
// injects one ```mermaid block with the given source, and waits until the
// init script replaces it with an SVG. Returns YES when exactly one <svg>
// is present and no .language-mermaid element remains.
- (BOOL)peleRendersDiagramSource:(NSString *)source
{
    WebView *webView = nil;
    NSWindow *window = nil;
    if (![self peleLoadTestPage:&webView window:&window])
        return NO;

    [self peleInjectSource:source intoWebView:webView];

    BOOL rendered = MPPeleSpinUntil(20.0, ^{
        return [[webView stringByEvaluatingJavaScriptFromString:
            @"String(document.querySelectorAll('svg').length)"]
            isEqualToString:@"1"];
    });
    BOOL replaced = [[webView stringByEvaluatingJavaScriptFromString:
        @"String(document.querySelectorAll('.language-mermaid').length)"]
        isEqualToString:@"0"];

    [webView close];
    [window close];

    XCTAssertTrue(rendered, @"Pele did not render an SVG for: %@", source);
    XCTAssertTrue(replaced, @"The .language-mermaid block was not replaced");
    return rendered && replaced;
}

- (void)testFlowchartRendersToSVG
{
    [self peleRendersDiagramSource:
        @"graph TD\n    A[Start] --> B[Process]\n    B --> C[End]"];
}

- (void)testSequenceDiagramRendersToSVG
{
    [self peleRendersDiagramSource:
        @"sequenceDiagram\n    Alice->>Bob: Hello\n    Bob-->>Alice: Hi"];
}

- (void)testInvalidDiagramShowsErrorAndSource
{
    WebView *webView = nil;
    NSWindow *window = nil;
    if (![self peleLoadTestPage:&webView window:&window])
        return;

    NSString *source = @"not a diagram {{{";
    [self peleInjectSource:source intoWebView:webView];

    BOOL errored = MPPeleSpinUntil(20.0, ^{
        return [[webView stringByEvaluatingJavaScriptFromString:
            @"String(document.querySelectorAll('pre.pele-error').length)"]
            isEqualToString:@"1"];
    });
    NSString *errorText = [webView stringByEvaluatingJavaScriptFromString:
        @"String((document.querySelector('pre.pele-error') || {}).textContent)"];

    [webView close];
    [window close];

    XCTAssertTrue(errored, @"Invalid diagram should produce an error block");
    XCTAssertTrue([errorText containsString:source],
                  @"Error block should show the offending source, got: %@",
                  errorText);
}

- (void)testRepeatedSourceRendersOnce
{
    WebView *webView = nil;
    NSWindow *window = nil;
    if (![self peleLoadTestPage:&webView window:&window])
        return;

    NSString *source = @"graph TD\n    A --> B";
    [self peleInjectSource:source intoWebView:webView];
    BOOL first = MPPeleSpinUntil(20.0, ^{
        return [[webView stringByEvaluatingJavaScriptFromString:
            @"String(document.querySelectorAll('svg').length)"]
            isEqualToString:@"1"];
    });

    // Simulate a live-preview DOM replacement with identical content.
    [self peleInjectSource:source intoWebView:webView];
    BOOL second = MPPeleSpinUntil(20.0, ^{
        return [[webView stringByEvaluatingJavaScriptFromString:
            @"String(document.querySelectorAll('svg').length)"]
            isEqualToString:@"2"];
    });
    NSString *renders = [webView stringByEvaluatingJavaScriptFromString:
        @"String(window.__peleRenderStats.renders)"];
    NSString *hits = [webView stringByEvaluatingJavaScriptFromString:
        @"String(window.__peleRenderStats.cacheHits)"];

    [webView close];
    [window close];

    XCTAssertTrue(first && second, @"Both diagrams should render");
    XCTAssertTrue([renders isEqualToString:@"1"],
                  @"Repeated source must hit the cache (renders=%@)", renders);
    XCTAssertTrue([hits isEqualToString:@"1"],
                  @"Expected one cache hit (hits=%@)", hits);
}

- (void)testDarkBackgroundUsesDarkVariables
{
    WebView *webView = nil;
    NSWindow *window = nil;
    if (![self peleLoadTestPage:&webView window:&window])
        return;

    [webView stringByEvaluatingJavaScriptFromString:
        @"document.body.style.background = '#1e1e1e';"];
    [self peleInjectSource:@"graph TD\n    A --> B" intoWebView:webView];
    BOOL rendered = MPPeleSpinUntil(20.0, ^{
        return [[webView stringByEvaluatingJavaScriptFromString:
            @"String(document.querySelectorAll('svg').length)"]
            isEqualToString:@"1"];
    });
    NSString *wrapperStyle = [webView stringByEvaluatingJavaScriptFromString:
        @"String(document.querySelector('svg').parentElement.getAttribute('style'))"];

    [webView close];
    [window close];

    XCTAssertTrue(rendered, @"Diagram should render on dark background");
    XCTAssertTrue([wrapperStyle containsString:@"--pele-bg:#1e1e1e"],
                  @"Dark background should select dark variables, got: %@",
                  wrapperStyle);
}

- (void)testLightBackgroundUsesLightVariables
{
    WebView *webView = nil;
    NSWindow *window = nil;
    if (![self peleLoadTestPage:&webView window:&window])
        return;

    [self peleInjectSource:@"graph TD\n    A --> B" intoWebView:webView];
    BOOL rendered = MPPeleSpinUntil(20.0, ^{
        return [[webView stringByEvaluatingJavaScriptFromString:
            @"String(document.querySelectorAll('svg').length)"]
            isEqualToString:@"1"];
    });
    NSString *wrapperStyle = [webView stringByEvaluatingJavaScriptFromString:
        @"String(document.querySelector('svg').parentElement.getAttribute('style'))"];

    [webView close];
    [window close];

    XCTAssertTrue(rendered, @"Diagram should render on light background");
    XCTAssertTrue([wrapperStyle containsString:@"--pele-bg:#fff"],
                  @"Light background should select light variables, got: %@",
                  wrapperStyle);
}

// The self-contained HTML export (all scripts inlined) must render every
// diagram type in the pele-diagrams fixture when opened in a WebView.
- (void)testExportedHTMLRendersAllDiagramTypes
{
    NSURL *fixtureURL = [[NSBundle bundleForClass:[self class]]
        URLForResource:@"pele-diagrams" withExtension:@"md"
         subdirectory:@"Fixtures"];
    XCTAssertNotNil(fixtureURL, @"pele-diagrams.md fixture is missing");
    if (!fixtureURL)
        return;
    NSString *markdown = [NSString stringWithContentsOfURL:fixtureURL
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    XCTAssertNotNil(markdown);

    self.delegate.extensions = HOEDOWN_EXT_FENCED_CODE;
    self.delegate.mermaid = YES;
    [self.renderer parseMarkdown:markdown];
    NSString *html =
        [self.renderer HTMLForExportWithStyles:YES highlighting:NO];
    XCTAssertNotNil(html);

    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 800, 600)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;  // ARC owns the window.
    WebView *webView = [[WebView alloc]
        initWithFrame:NSMakeRect(0, 0, 800, 600)];
    window.contentView = webView;

    [webView.mainFrame loadHTMLString:html baseURL:nil];
    BOOL rendered = MPPeleSpinUntil(30.0, ^{
        return (BOOL)(!webView.isLoading && [[webView
            stringByEvaluatingJavaScriptFromString:
                @"String(document.querySelectorAll('svg').length)"]
            isEqualToString:@"5"]);
    });

    [webView close];
    [window close];

    XCTAssertTrue(rendered, @"Exported HTML should render all 5 diagrams");
}

@end
