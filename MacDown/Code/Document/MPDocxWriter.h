//
//  MPDocxWriter.h
//  MacDown
//
//  Minimal native DOCX writer for the export pipeline. Takes the JSON
//  document model produced by docx.snapshot.js in an offscreen WebView and
//  emits a self-contained .docx (stored ZIP, no compression, no new
//  dependencies). Diagrams arrive either as vector SVG with a PNG fallback
//  (native variant) or as PNG only (compatible variant).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const MPDocxWriterErrorDomain;

typedef NS_ENUM(NSInteger, MPDocxWriterError) {
    MPDocxWriterErrorBadModel = 1,
    MPDocxWriterErrorNoContent,
    MPDocxWriterErrorRenderFailed,
};

@interface MPDocxWriter : NSObject

/// Builds DOCX file data from self-contained export HTML (scripts embedded):
/// loads it in a hidden WebView, waits for diagrams to resolve, snapshots
/// the document model and serializes it. Main thread only; spins the runloop
/// bounded by timeouts. Returns nil + error on any failure.
+ (nullable NSData *)docxDataWithExportHTML:(NSString *)html
                                    baseURL:(nullable NSURL *)baseURL
                                      title:(NSString *)title
                                  nativeSVG:(BOOL)nativeSVG
                                      error:(NSError **)error;

/// Builds DOCX file data from a snapshot model dictionary:
/// @{@"meta": @{@"fontFamily":..., @"fontSize":...},
///   @"blocks": @[@{@"t":@"h",@"level":@1,@"runs":@[...]}, ...]}.
/// Runs look like @{@"text":..., @"bold":@YES, @"italic":@.., @"code":@..,
/// @"strike":@.., @"link":@"https://.."} or @{@"img":<data-url-or-null>}.
/// Diagram blocks: @{@"t":@"diagram", @"w":@(..), @"h":@(..),
/// @"svg":@"<svg..>", @"png":@"data:image/png;base64,.."} (svg/png may be
/// NSNull when unavailable). When nativeSVG is YES each diagram is embedded
/// as vector SVG with a PNG fallback; otherwise PNG only.
+ (nullable NSData *)docxDataWithModel:(NSDictionary *)model
                                 title:(NSString *)title
                             nativeSVG:(BOOL)nativeSVG
                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
