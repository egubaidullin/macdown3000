//
//  MPDocxWriter.m
//  MacDown
//
//  See MPDocxWriter.h. ZIP is written uncompressed (stored entries) with an
//  inline CRC32 so no new library or link phase is needed.
//

#import "MPDocxWriter.h"
#import <WebKit/WebKit.h>
#import <JavaScriptCore/JavaScriptCore.h>

NSString * const MPDocxWriterErrorDomain = @"MPDocxWriterErrorDomain";

// Half-points per CSS px at 96 dpi reference used by the snapshot.
static const double kMPDocxPointsPerPx = 0.75;
// EMUs per CSS px.
static const long long kMPDocxEmuPerPx = 9525;
// Letter, 1in margins, twips.
static const long kMPDocxPageWidth = 12240;
static const long kMPDocxPageHeight = 15840;
static const long kMPDocxMargin = 1440;
// Usable content box in EMU: images and diagrams are scaled down to it so
// nothing is pushed outside the page margins.
static const long long kMPDocxContentWidthEmu =
    (long long)(12240 - 2 * 1440) * 635;   // twips -> EMU
static const long long kMPDocxContentHeightEmu =
    (long long)(15840 - 2 * 1440) * 635;

#pragma mark - CRC32

static uint32_t MPDocxCRC32Table[256];
static dispatch_once_t MPDocxCRC32Once;

static void MPDocxInitCRC32(void)
{
    dispatch_once(&MPDocxCRC32Once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++)
                c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            MPDocxCRC32Table[i] = c;
        }
    });
}

static uint32_t MPDocxCRC32(NSData *data)
{
    MPDocxInitCRC32();
    uint32_t crc = 0xFFFFFFFFu;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++)
        crc = MPDocxCRC32Table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

#pragma mark - Helpers

static void MPDocxAppendLE16(NSMutableData *data, uint16_t v)
{
    uint8_t b[2] = { v & 0xFF, (v >> 8) & 0xFF };
    [data appendBytes:b length:2];
}

static void MPDocxAppendLE32(NSMutableData *data, uint32_t v)
{
    uint8_t b[4] = { v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF };
    [data appendBytes:b length:4];
}

static NSString *MPDocxEscape(NSString *s)
{
    if (!s)
        return @"";
    // Strip characters illegal in XML 1.0 (only tab/LF/CR survive below 0x20).
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 0x20)];
    NSMutableString *clean = [s mutableCopy];
    for (NSUInteger i = 0; i < clean.length; ) {
        unichar c = [clean characterAtIndex:i];
        if ([illegal characterIsMember:c] && c != '\t' && c != '\n' && c != '\r') {
            [clean deleteCharactersInRange:NSMakeRange(i, 1)];
        } else {
            i++;
        }
    }
    NSMutableString *out = clean;
    [out replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, out.length)];
    return out;
}

static NSString *MPDocxString(id value)
{
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static BOOL MPDocxFlag(NSDictionary *dict, NSString *key)
{
    id v = dict[key];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : NO;
}

static long MPDocxLong(id value, long fallback)
{
    if ([value isKindOfClass:[NSNumber class]])
        return [value longValue];
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value integerValue];
    return fallback;
}

// PNG/JPEG/GIF sniffing for image parts. Returns extension+content type or nil.
static NSDictionary *MPDocxImageKind(NSData *data)
{
    const uint8_t *b = data.bytes;
    if (data.length > 4 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G')
        return @{@"ext": @"png", @"type": @"image/png"};
    if (data.length > 2 && b[0] == 0xFF && b[1] == 0xD8)
        return @{@"ext": @"jpg", @"type": @"image/jpeg"};
    if (data.length > 4 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F')
        return @{@"ext": @"gif", @"type": @"image/gif"};
    return nil;
}

static NSData *MPDocxImageDataFromSource(NSString *src)
{
    if (![src isKindOfClass:[NSString class]] || src.length == 0)
        return nil;
    if ([src hasPrefix:@"data:"]) {
        NSRange comma = [src rangeOfString:@","];
        if (comma.location == NSNotFound)
            return nil;
        NSString *payload = [src substringFromIndex:comma.location + 1];
        if ([src containsString:@";base64"]) {
            return [[NSData alloc] initWithBase64EncodedString:payload
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
        }
        return nil;
    }
    NSURL *url = [NSURL URLWithString:src];
    if (url && url.isFileURL)
        return [NSData dataWithContentsOfURL:url];
    return nil;
}

#pragma mark - Stored ZIP

// Minimal stored (uncompressed) ZIP writer. Parts: array of
// @{@"name":..., @"data":...}. Part names are ASCII.
static NSData *MPDocxZip(NSArray<NSDictionary *> *parts)
{
    NSMutableData *zip = [NSMutableData data];
    NSMutableArray<NSDictionary *> *central = [NSMutableArray array];
    for (NSDictionary *part in parts) {
        NSString *name = part[@"name"];
        NSData *payload = part[@"data"];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = MPDocxCRC32(payload);
        uint32_t offset = (uint32_t)zip.length;
        MPDocxAppendLE32(zip, 0x04034b50);  // local header signature
        MPDocxAppendLE16(zip, 20);          // version needed
        MPDocxAppendLE16(zip, 0);           // flags
        MPDocxAppendLE16(zip, 0);           // method: stored
        MPDocxAppendLE16(zip, 0);           // time
        MPDocxAppendLE16(zip, 0x0021);      // date (1980-01-01)
        MPDocxAppendLE32(zip, crc);
        MPDocxAppendLE32(zip, (uint32_t)payload.length);
        MPDocxAppendLE32(zip, (uint32_t)payload.length);
        MPDocxAppendLE16(zip, (uint16_t)nameData.length);
        MPDocxAppendLE16(zip, 0);           // extra length
        [zip appendData:nameData];
        [zip appendData:payload];
        [central addObject:@{@"name": nameData, @"crc": @(crc),
                             @"size": @(payload.length), @"offset": @(offset)}];
    }
    uint32_t centralOffset = (uint32_t)zip.length;
    for (NSDictionary *entry in central) {
        NSData *nameData = entry[@"name"];
        MPDocxAppendLE32(zip, 0x02014b50);  // central signature
        MPDocxAppendLE16(zip, 20);          // version made by
        MPDocxAppendLE16(zip, 20);          // version needed
        MPDocxAppendLE16(zip, 0);
        MPDocxAppendLE16(zip, 0);
        MPDocxAppendLE16(zip, 0);
        MPDocxAppendLE16(zip, 0x0021);
        MPDocxAppendLE32(zip, [entry[@"crc"] unsignedIntValue]);
        MPDocxAppendLE32(zip, [entry[@"size"] unsignedIntValue]);
        MPDocxAppendLE32(zip, [entry[@"size"] unsignedIntValue]);
        MPDocxAppendLE16(zip, (uint16_t)[(NSData *)nameData length]);
        MPDocxAppendLE16(zip, 0);
        MPDocxAppendLE16(zip, 0);
        MPDocxAppendLE16(zip, 0);
        MPDocxAppendLE16(zip, 0);
        MPDocxAppendLE32(zip, 0);
        MPDocxAppendLE32(zip, [entry[@"offset"] unsignedIntValue]);
        [zip appendData:nameData];
    }
    uint32_t centralSize = (uint32_t)zip.length - centralOffset;
    MPDocxAppendLE32(zip, 0x06054b50);      // EOCD
    MPDocxAppendLE16(zip, 0);
    MPDocxAppendLE16(zip, 0);
    MPDocxAppendLE16(zip, (uint16_t)central.count);
    MPDocxAppendLE16(zip, (uint16_t)central.count);
    MPDocxAppendLE32(zip, centralSize);
    MPDocxAppendLE32(zip, centralOffset);
    MPDocxAppendLE16(zip, 0);
    return zip;
}

#pragma mark - Writer

@interface MPDocxWriter ()
@property (nonatomic) NSMutableArray<NSDictionary *> *parts;
@property (nonatomic) NSMutableArray<NSDictionary *> *imageRels;  // @{@"rId", @"target", @"kind"}
@property (nonatomic) NSMutableArray<NSString *> *contentOverrides;
@property (nonatomic) NSInteger nextRelId;
@property (nonatomic) NSInteger nextDocPrId;
@property (nonatomic) NSInteger nextNumId;
@property (nonatomic) NSMutableDictionary<NSString *, NSString *> *linkRelIds;
@end

@implementation MPDocxWriter

- (instancetype)init
{
    if (self = [super init]) {
        _parts = [NSMutableArray array];
        _imageRels = [NSMutableArray array];
        _contentOverrides = [NSMutableArray array];
        _nextRelId = 5;  // rId1..4 reserved for styles/numbering/header/footer
        _nextDocPrId = 1;
        _nextNumId = 10;
        _linkRelIds = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)addPart:(NSString *)name data:(NSData *)data
{
    [_parts addObject:@{@"name": name, @"data": data}];
}

- (NSString *)addImagePart:(NSData *)data ext:(NSString *)ext
                      type:(NSString *)type
{
    NSString *rId = [NSString stringWithFormat:@"rId%ld", (long)_nextRelId++];
    NSString *target = [NSString stringWithFormat:@"media/%@.%@",
                        [[rId lowercaseString] stringByReplacingOccurrencesOfString:@"rid" withString:@"image"], ext];
    NSString *partName = [@"word/" stringByAppendingString:target];
    [self addPart:partName data:data];
    [_contentOverrides addObject:
     [NSString stringWithFormat:
      @"<Override PartName=\"/%@\" ContentType=\"%@\"/>", partName, type]];
    [_imageRels addObject:@{@"rId": rId, @"target": target}];
    return rId;
}

- (NSString *)runXml:(NSDictionary *)run baseSize:(NSInteger)sz
{
    NSMutableString *pr = [NSMutableString string];
    NSMutableString *rPr = [NSMutableString string];
    if (MPDocxFlag(run, @"bold")) [rPr appendString:@"<w:b/>"];
    if (MPDocxFlag(run, @"italic")) [rPr appendString:@"<w:i/>"];
    if (MPDocxFlag(run, @"strike")) [rPr appendString:@"<w:strike/>"];
    NSString *link = run[@"link"];
    BOOL hasLink = [link isKindOfClass:[NSString class]] && link.length > 0;
    if (MPDocxFlag(run, @"code")) {
        [rPr appendString:@"<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\"/>"];
    }
    NSString *text = MPDocxString(run[@"text"]);
    if (text.length == 0)
        return @"";
    // Preserve edge whitespace exactly (Word collapses it otherwise).
    BOOL keepSpace = [text hasPrefix:@" "] || [text hasPrefix:@"\n"] ||
                     [text hasSuffix:@" "] || [text hasSuffix:@"\n"];
    [pr appendString:@"<w:r>"];
    if (rPr.length || hasLink)
        [pr appendFormat:@"<w:rPr>%@%@</w:rPr>", hasLink ? @"<w:rStyle w:val=\"Hyperlink\"/>" : @"", rPr];
    NSMutableArray<NSString *> *lines =
        [[text componentsSeparatedByString:@"\n"] mutableCopy];
    // Drop trailing empty lines: a trailing <w:br/> followed by an empty
    // <w:t/> is a spurious blank line that strict readers reject.
    while (lines.count > 0 && [(NSString *)lines.lastObject length] == 0)
        [lines removeLastObject];
    if (lines.count == 0)
        return @"";
    for (NSUInteger i = 0; i < lines.count; i++) {
        if (i > 0) [pr appendString:@"<w:br/>"];
        [pr appendFormat:@"<w:t%@>%@</w:t>",
         keepSpace ? @" xml:space=\"preserve\"" : @"", MPDocxEscape(lines[i])];
    }
    [pr appendString:@"</w:r>"];
    if (!hasLink)
        return pr;
    NSString *rId = _linkRelIds[link];
    if (!rId) {
        rId = [NSString stringWithFormat:@"rId%ld", (long)_nextRelId++];
        _linkRelIds[link] = rId;
        [_imageRels addObject:@{@"rId": rId, @"target": link, @"external": @YES}];
    }
    return [NSString stringWithFormat:@"<w:hyperlink r:id=\"%@\">%@</w:hyperlink>", rId, pr];
}

- (NSString *)runsXml:(NSArray *)runs baseSize:(NSInteger)sz
{
    NSMutableString *out = [NSMutableString string];
    for (id run in runs) {
        if (![run isKindOfClass:[NSDictionary class]])
            continue;
        if (run[@"img"]) {
            // Inline images (inside list items, table cells, headings or
            // quotes) become inline drawings, so they survive anywhere a
            // run is allowed.
            NSData *data = MPDocxImageDataFromSource(MPDocxString(run[@"img"]));
            if (!data)
                continue;
            long w = MPDocxLong(run[@"width"], 0);
            long h = MPDocxLong(run[@"height"], 0);
            NSString *inlineDrawing =
                [self embedImageData:data width:w height:h native:NO svg:nil error:NULL];
            if (inlineDrawing)
                [out appendString:inlineDrawing];
            continue;
        }
        [out appendString:[self runXml:run baseSize:sz]];
    }
    return out;
}

// A paragraph from runs with an optional style and extra pPr.
- (NSString *)paragraphXml:(NSArray *)runs style:(nullable NSString *)style
                 extraPr:(nullable NSString *)extraPr
{
    NSMutableString *p = [NSMutableString stringWithString:@"<w:p>"];
    if (style || extraPr)
        [p appendFormat:@"<w:pPr>%@%@</w:pPr>",
         style ? [NSString stringWithFormat:@"<w:pStyle w:val=\"%@\"/>", style] : @"",
         extraPr ?: @""];
    [p appendString:[self runsXml:runs baseSize:0]];
    [p appendString:@"</w:p>"];
    return p;
}

- (NSString *)drawingXml:(NSString *)pngRelId svgRelId:(nullable NSString *)svgRelId
                     cx:(long long)cx cy:(long long)cy
{
    NSInteger docPrId = _nextDocPrId++;
    NSString *blip;
    if (svgRelId) {
        // Canonical vector-image shape (as written by Word itself and by
        // Pandoc): an ordinary picture whose blip carries the SVG in an
        // extLst extension. A bare svgBlip graphicData or an
        // mc:AlternateContent wrapper makes this Word build reject the
        // whole document, so neither is used. When PNG data is present it
        // rides as the blip fallback for readers without SVG support.
        NSMutableString *exts = [NSMutableString stringWithFormat:
            @"<a:ext uri=\"{28A0092B-C50C-407E-A947-70E740481C1C}\">"
             "<a14:useLocalDpi xmlns:a14=\"http://schemas.microsoft.com/office/drawing/2010/main\" val=\"0\"/>"
             "</a:ext>"
             "<a:ext uri=\"{96DAC541-7B7A-43D3-8B79-37D633B846F1}\">"
             "<asvg:svgBlip xmlns:asvg=\"http://schemas.microsoft.com/office/drawing/2016/SVG/main\" r:embed=\"%@\"/>"
             "</a:ext>", svgRelId];
        blip = [NSString stringWithFormat:
            @"<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
             "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
             "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
             "<pic:nvPicPr><pic:cNvPr id=\"%ld\" descr=\"\" name=\"diagram\"/>"
             "<pic:cNvPicPr><a:picLocks noChangeArrowheads=\"1\" noChangeAspect=\"1\"/></pic:cNvPicPr></pic:nvPicPr>"
             "<pic:blipFill><a:blip%@><a:extLst>%@</a:extLst></a:blip>"
             "<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
             "<pic:spPr bwMode=\"auto\"><a:xfrm><a:off x=\"0\" y=\"0\"/>"
             "<a:ext cx=\"%lld\" cy=\"%lld\"/></a:xfrm>"
             "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
             "<a:noFill/><a:ln><a:noFill/></a:ln></pic:spPr>"
             "</pic:pic>"
             "</a:graphicData></a:graphic>",
            (long)docPrId,
            pngRelId ? [NSString stringWithFormat:@" r:embed=\"%@\"", pngRelId] : @"",
            exts, cx, cy];
    } else {
        blip = [NSString stringWithFormat:
            @"<a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
             "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
             "<pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
             "<pic:nvPicPr><pic:cNvPr id=\"%ld\" name=\"image\"/>"
             "<pic:cNvPicPr/></pic:nvPicPr>"
             "<pic:blipFill><a:blip r:embed=\"%@\"/>"
             "<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
             "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/>"
             "<a:ext cx=\"%lld\" cy=\"%lld\"/></a:xfrm>"
             "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
             "</pic:pic>"
             "</a:graphicData></a:graphic>",
            (long)docPrId, pngRelId, cx, cy];
    }
    return [NSString stringWithFormat:
        @"<w:r><w:drawing>"
         "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
         "<wp:extent cx=\"%lld\" cy=\"%lld\"/>"
         "<wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>"
         "<wp:docPr id=\"%ld\" name=\"diagram\"/>"
         "%@"
         "</wp:inline>"
         "</w:drawing></w:r>",
        cx, cy, (long)docPrId, blip];
}

- (nullable NSString *)embedImageData:(nullable NSData *)data width:(long)w height:(long)h
                            native:(BOOL)native svg:(nullable NSString *)svg
                             error:(NSError **)error
{
    (void)error;
    if (w <= 0) w = 300;
    if (h <= 0) h = 200;
    long long cx = (long long)w * kMPDocxEmuPerPx;
    long long cy = (long long)h * kMPDocxEmuPerPx;
    // Fit inside the printable area, preserving the aspect ratio.
    double scale = 1.0;
    if (cx > kMPDocxContentWidthEmu)
        scale = (double)kMPDocxContentWidthEmu / (double)cx;
    if ((double)cy * scale > kMPDocxContentHeightEmu) {
        double heightScale = (double)kMPDocxContentHeightEmu / (double)cy;
        if (heightScale < scale)
            scale = heightScale;
    }
    // Tiny diagrams (a 64px flowchart is 0.67in wide) are unreadable in a
    // document: grow them to at least a third of the printable width, but
    // never past the page box and never more than 2.5x.
    if (scale == 1.0 && cx < kMPDocxContentWidthEmu / 3) {
        double grow = (double)(kMPDocxContentWidthEmu / 3) / (double)cx;
        if (grow > 2.5)
            grow = 2.5;
        if ((double)cy * grow <= kMPDocxContentHeightEmu) {
            cx = (long long)llround((double)cx * grow);
            cy = (long long)llround((double)cy * grow);
        }
    }
    if (scale < 1.0) {
        cx = (long long)llround((double)cx * scale);
        cy = (long long)llround((double)cy * scale);
    }
    NSString *pngRelId = nil;
    if (data) {
        NSDictionary *kind = MPDocxImageKind(data);
        if (!kind)
            return nil;
        pngRelId = [self addImagePart:data ext:kind[@"ext"] type:kind[@"type"]];
    }
    NSString *svgRelId = nil;
    if (native && svg.length > 0) {
        NSData *svgData = [svg dataUsingEncoding:NSUTF8StringEncoding];
        svgRelId = [self addImagePart:svgData ext:@"svg" type:@"image/svg+xml"];
    }
    if (!pngRelId && !svgRelId)
        return nil;
    return [self drawingXml:pngRelId svgRelId:svgRelId cx:cx cy:cy];
}

- (NSString *)documentXml:(NSArray *)blocks nativeSVG:(BOOL)native
{
    NSMutableString *body = [NSMutableString string];
    NSMutableString *numbering = [NSMutableString string];
    for (NSDictionary *block in blocks) {
        if (![block isKindOfClass:[NSDictionary class]])
            continue;
        NSString *t = block[@"t"];
        if ([t isEqualToString:@"h"]) {
            long level = MPDocxLong(block[@"level"], 1);
            level = MAX(1, MIN(6, level));
            [body appendString:[self paragraphXml:block[@"runs"]
                                            style:[NSString stringWithFormat:@"Heading%ld", level]
                                          extraPr:nil]];
        } else if ([t isEqualToString:@"p"]) {
            [body appendString:[self paragraphXml:block[@"runs"] style:@"Normal" extraPr:nil]];
        } else if ([t isEqualToString:@"quote"]) {
            [body appendString:[self paragraphXml:block[@"runs"] style:@"Quote" extraPr:nil]];
        } else if ([t isEqualToString:@"code"]) {
            NSString *text = MPDocxString(block[@"text"]);
            [body appendString:[self paragraphXml:@[@{@"text": text, @"code": @YES}]
                                                 style:@"Normal"
                                               extraPr:@"<w:shd w:fill=\"F2F2F2\" w:val=\"clear\"/>"]];
        } else if ([t isEqualToString:@"hr"]) {
            [body appendString:@"<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"999999\"/></w:pBdr></w:pPr></w:p>"];
        } else if ([t isEqualToString:@"list"]) {
            BOOL ordered = MPDocxFlag(block, @"ordered");
            NSInteger numId = _nextNumId++;
            [numbering appendFormat:@"<w:num w:numId=\"%ld\"><w:abstractNumId w:val=\"%@\"/></w:num>",
             (long)numId, ordered ? @"1" : @"0"];
            for (NSDictionary *item in (NSArray *)block[@"items"]) {
                if (![item isKindOfClass:[NSDictionary class]])
                    continue;
                long level = MIN(8, MPDocxLong(item[@"level"], 0));
                [body appendString:[self paragraphXml:item[@"runs"] style:@"Normal"
                    extraPr:[NSString stringWithFormat:
                             @"<w:numPr><w:ilvl w:val=\"%ld\"/><w:numId w:val=\"%ld\"/></w:numPr>",
                             level, (long)numId]]];
            }
        } else if ([t isEqualToString:@"table"]) {
            NSArray *rows = block[@"rows"];
            if (![rows isKindOfClass:[NSArray class]] || rows.count == 0)
                continue;
            // Column count is the widest row: ragged rows must still match
            // the grid or strict readers reject the table.
            NSInteger cols = 0;
            for (id rowObj in rows) {
                if ([rowObj isKindOfClass:[NSArray class]])
                    cols = MAX(cols, (NSInteger)[(NSArray *)rowObj count]);
            }
            if (cols == 0)
                continue;
            long cellW = (kMPDocxPageWidth - 2 * kMPDocxMargin) / cols;
            NSMutableString *tbl = [NSMutableString stringWithString:
                @"<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>"
                 "<w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
                 "<w:left w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
                 "<w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
                 "<w:right w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
                 "<w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/>"
                 "<w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"999999\"/></w:tblBorders></w:tblPr>"
                 "<w:tblGrid>"];
            for (NSInteger c = 0; c < cols; c++)
                [tbl appendFormat:@"<w:gridCol w:w=\"%ld\"/>", cellW];
            [tbl appendString:@"</w:tblGrid>"];
            for (id rowObj in rows) {
                if (![rowObj isKindOfClass:[NSArray class]])
                    continue;
                [tbl appendString:@"<w:tr>"];
                for (id cellObj in (NSArray *)rowObj) {
                    if (![cellObj isKindOfClass:[NSDictionary class]])
                        continue;
                    NSDictionary *cell = cellObj;
                    BOOL header = MPDocxFlag(cell, @"header");
                    [tbl appendFormat:@"<w:tc><w:tcPr><w:tcW w:w=\"%ld\" w:type=\"dxa\"/>%@</w:tcPr>",
                     cellW, header ? @"<w:shd w:fill=\"D9D9D9\" w:val=\"clear\"/>" : @""];
                    NSArray *runs = cell[@"runs"];
                    if (header) {
                        NSMutableArray *bolded = [NSMutableArray array];
                        for (id r in (NSArray *)runs) {
                            if (![r isKindOfClass:[NSDictionary class]])
                                continue;
                            NSMutableDictionary *br = [r mutableCopy];
                            br[@"bold"] = @YES;
                            [bolded addObject:br];
                        }
                        runs = bolded;
                    }
                    [tbl appendString:[self paragraphXml:runs style:@"Normal" extraPr:nil]];
                    [tbl appendString:@"</w:tc>"];
                }
                [tbl appendString:@"</w:tr>"];
            }
            [tbl appendString:@"</w:tbl>"];
            [body appendString:tbl];
        } else if ([t isEqualToString:@"img"] || [t isEqualToString:@"diagram"]) {
            NSData *data = nil;
            NSString *svg = nil;
            long w = 0, h = 0;
            if ([t isEqualToString:@"diagram"]) {
                w = MPDocxLong(block[@"w"], 0);
                h = MPDocxLong(block[@"h"], 0);
                svg = MPDocxString(block[@"svg"]);
                // The compatible variant rasterizes to PNG; the native
                // variant embeds both (SVG primary, PNG fallback in blip).
                data = MPDocxImageDataFromSource(MPDocxString(block[@"png"]));
                if (!native)
                    svg = nil;
            } else {
                data = MPDocxImageDataFromSource(MPDocxString(block[@"src"]));
                w = MPDocxLong(block[@"width"], 0);
                h = MPDocxLong(block[@"height"], 0);
                if (data && (w <= 0 || h <= 0)) {
                    NSImage *probe = [[NSImage alloc] initWithData:data];
                    if (probe.size.width > 0) {
                        w = (long)probe.size.width;
                        h = (long)probe.size.height;
                    }
                }
            }
            NSString *drawing = [self embedImageData:data width:w height:h
                                                     native:(native && [t isEqualToString:@"diagram"])
                                                        svg:svg error:NULL];
            if (drawing) {
                [body appendFormat:@"<w:p>%@</w:p>", drawing];
            } else {
                [body appendString:[self paragraphXml:@[@{@"text": @"[image unavailable]"}]
                                                        style:@"Normal" extraPr:nil]];
            }
        }
    }
    if (body.length == 0)
        [body appendString:@"<w:p/>"];
    NSMutableString *numberingXml = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"];
    // Both abstracts define levels 0-8: nested items reference ilvl>0 and
    // Word rejects levels without a definition.
    for (int a = 0; a < 2; a++) {
        [numberingXml appendFormat:@"<w:abstractNum w:abstractNumId=\"%d\">", a];
        for (int l = 0; l <= 8; l++) {
            if (a == 0) {
                [numberingXml appendFormat:
                 @"<w:lvl w:ilvl=\"%d\"><w:start w:val=\"1\"/>"
                  "<w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\u2022\"/>"
                  "<w:lvlJc w:val=\"left\"/>"
                  "<w:pPr><w:ind w:left=\"%d\" w:hanging=\"360\"/></w:pPr></w:lvl>",
                 l, 720 + l * 360];
            } else {
                [numberingXml appendFormat:
                 @"<w:lvl w:ilvl=\"%d\"><w:start w:val=\"1\"/>"
                  "<w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%%%d.\"/>"
                  "<w:lvlJc w:val=\"left\"/>"
                  "<w:pPr><w:ind w:left=\"%d\" w:hanging=\"360\"/></w:pPr></w:lvl>",
                 l, l + 1, 720 + l * 360];
            }
        }
        [numberingXml appendString:@"</w:abstractNum>"];
    }
    [numberingXml appendFormat:@"%@</w:numbering>", numbering];
    [self addPart:@"word/numbering.xml"
             data:[numberingXml dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *sectPr =
        [NSString stringWithFormat:
         @"<w:sectPr><w:headerReference w:type=\"default\" r:id=\"rId3\"/>"
          "<w:footerReference w:type=\"default\" r:id=\"rId4\"/>"
          "<w:pgSz w:w=\"%ld\" w:h=\"15840\"/>"
          "<w:pgMar w:top=\"%ld\" w:right=\"%ld\" w:bottom=\"%ld\" w:left=\"%ld\" "
          "w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/>"
          "</w:sectPr>",
         kMPDocxPageWidth, kMPDocxMargin, kMPDocxMargin, kMPDocxMargin, kMPDocxMargin];
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
         "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
         "xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\" "
         "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
         "xmlns:asvg=\"http://schemas.microsoft.com/office/drawing/2016/SVG/main\" "
         "mc:Ignorable=\"asvg\">"
         "<w:body>%@%@</w:body></w:document>", body, sectPr];
}

- (NSString *)stylesXml:(NSString *)fontFamily halfPoints:(NSInteger)sz
{
    NSMutableString *s = [NSMutableString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
         "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\">"
         "<w:name w:val=\"Normal\"/><w:rPr>"
         "<w:rFonts w:ascii=\"%@\" w:hAnsi=\"%@\"/>"
         "<w:sz w:val=\"%ld\"/><w:szCs w:val=\"%ld\"/>"
         "</w:rPr></w:style>",
        MPDocxEscape(fontFamily), MPDocxEscape(fontFamily), (long)sz, (long)sz];
    const long sizes[] = { 44, 32, 28, 24, 22, 20 };
    for (int i = 1; i <= 6; i++) {
        [s appendFormat:
         @"<w:style w:type=\"paragraph\" w:styleId=\"Heading%d\">"
          "<w:name w:val=\"heading %d\"/><w:basedOn w:val=\"Normal\"/>"
          "<w:rPr><w:b/><w:sz w:val=\"%ld\"/><w:szCs w:val=\"%ld\"/></w:rPr></w:style>",
         i, i, sizes[i - 1], sizes[i - 1]];
    }
    [s appendString:
     @"<w:style w:type=\"paragraph\" w:styleId=\"Quote\">"
      "<w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/>"
      "<w:pPr><w:ind w:left=\"720\"/></w:pPr>"
      "<w:rPr><w:i/><w:color w:val=\"595959\"/></w:rPr></w:style>"
      "<w:style w:type=\"character\" w:styleId=\"Hyperlink\">"
      "<w:name w:val=\"Hyperlink\"/><w:rPr>"
      "<w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
      "</w:styles>"];
    return s;
}

+ (nullable NSData *)docxDataWithExportHTML:(NSString *)html
                                    baseURL:(nullable NSURL *)baseURL
                                      title:(NSString *)title
                                  nativeSVG:(BOOL)nativeSVG
                                      error:(NSError **)error
{
    NSError *(^fail)(NSString *) = ^NSError *(NSString *message) {
        return [NSError errorWithDomain:MPDocxWriterErrorDomain
                                   code:MPDocxWriterErrorRenderFailed
                               userInfo:@{NSLocalizedDescriptionKey: message}];
    };
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *snapshotURL = [bundle URLForResource:@"docx.snapshot"
                                  withExtension:@"js"
                                   subdirectory:@"Extensions"];
    if (!snapshotURL) {
        snapshotURL = [[NSBundle bundleForClass:self] URLForResource:@"docx.snapshot"
                                                       withExtension:@"js"
                                                        subdirectory:@"Extensions"];
    }
    NSString *snapshotJS = snapshotURL ?
        [NSString stringWithContentsOfURL:snapshotURL
                                 encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!snapshotJS) {
        if (error) *error = fail(@"Could not load the export script.");
        return nil;
    }
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 900, 1200)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    WebView *webView = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 900, 1200)];
    window.contentView = webView;
    [webView.mainFrame loadHTMLString:html baseURL:baseURL];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
    BOOL settled = NO;
    // Renderers (Pele, Viz) run from page load hooks and may be async. Rather
    // than enumerate their pending markers — which differ per preference —
    // wait until the DOM stops changing for a few consecutive polls.
    NSInteger stablePolls = 0;
    NSString *lastSignature = nil;
    while (!settled && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        JSContext *ctx = webView.mainFrame.javaScriptContext;
        if (!ctx || webView.isLoading)
            continue;
        JSValue *state = [ctx evaluateScript:
            @"document.readyState === 'complete'"
             " ? String(document.body.childElementCount) + ':' + "
             "   String(document.body.innerHTML.length)"
             " : 'loading'"];
        NSString *signature = [state toString];
        if (![signature isEqualToString:@"loading"] &&
            [signature isEqualToString:lastSignature ?: @""]) {
            if (++stablePolls >= 4)
                settled = YES;
        } else {
            stablePolls = 0;
        }
        lastSignature = signature;
    }
    NSData *docx = nil;
    if (settled) {
        JSContext *ctx = webView.mainFrame.javaScriptContext;
        [ctx evaluateScript:snapshotJS];
        [ctx evaluateScript:@"window.__docxRunSnapshot();"];
        NSString *json = nil;
        deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
        while (!json && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            JSValue *v = [ctx evaluateScript:@"String(window.__docxResult || '')"];
            NSString *s = [v toString];
            if (s.length > 0)
                json = s;
        }
        if (json && ![json hasPrefix:@"ERROR:"]) {
            NSDictionary *model = [NSJSONSerialization JSONObjectWithData:
                                   [json dataUsingEncoding:NSUTF8StringEncoding]
                                                                  options:0 error:NULL];
            if (model) {
                docx = [self docxDataWithModel:model title:title
                                     nativeSVG:nativeSVG error:error];
            }
        }
        if (!docx && error && !*error)
            *error = fail(@"Could not snapshot the rendered document.");
    } else if (error) {
        *error = fail(@"Timed out waiting for diagrams to render.");
    }
    [webView close];
    [window close];
    return docx;
}

+ (nullable NSData *)docxDataWithModel:(NSDictionary *)model
                                 title:(NSString *)title
                             nativeSVG:(BOOL)nativeSVG
                                 error:(NSError **)error
{
    if (![model isKindOfClass:[NSDictionary class]]) {
        if (error) *error = [NSError errorWithDomain:MPDocxWriterErrorDomain
                                                code:MPDocxWriterErrorBadModel userInfo:nil];
        return nil;
    }
    MPDocxWriter *w = [[MPDocxWriter alloc] init];
    NSDictionary *meta = model[@"meta"];
    if (![meta isKindOfClass:[NSDictionary class]])
        meta = @{};
    // Font from the preview theme; first family wins, quotes stripped.
    NSString *family = MPDocxString(meta[@"fontFamily"]);
    NSArray *families = [family componentsSeparatedByString:@","];
    family = families.count ? [families[0] stringByTrimmingCharactersInSet:
                               [NSCharacterSet characterSetWithCharactersInString:@" \"'"]] : @"";
    if (family.length == 0)
        family = @"Helvetica";
    // "14px" -> half-points at 96dpi.
    NSInteger sz = 24;
    NSString *sizeStr = MPDocxString(meta[@"fontSize"]);
    NSScanner *scanner = [NSScanner scannerWithString:sizeStr];
    double px = 0;
    if ([scanner scanDouble:&px] && px > 0)
        sz = (NSInteger)llround(px * kMPDocxPointsPerPx * 2.0);
    sz = MAX(16, MIN(48, sz));

    NSArray *blocks = model[@"blocks"];
    if (![blocks isKindOfClass:[NSArray class]])
        blocks = @[];
    NSString *docXml = [w documentXml:blocks nativeSVG:nativeSVG];
    if (!docXml)
        return nil;
    [w addPart:@"word/document.xml" data:[docXml dataUsingEncoding:NSUTF8StringEncoding]];
    [w addPart:@"word/styles.xml" data:[[w stylesXml:family halfPoints:sz]
                                         dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *safeTitle = MPDocxEscape(title.length ? title : @"Untitled");
    [w addPart:@"word/header1.xml" data:[[NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         "<w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
         "<w:p><w:r><w:t>%@</w:t></w:r></w:p></w:hdr>", safeTitle]
        dataUsingEncoding:NSUTF8StringEncoding]];
    [w addPart:@"word/footer1.xml" data:[@"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<w:ftr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
        "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
        "<w:r><w:instrText xml:space=\"preserve\">PAGE</w:instrText></w:r>"
        "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p></w:ftr>"
        dataUsingEncoding:NSUTF8StringEncoding]];
    [w addPart:@"docProps/core.xml" data:[[NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
         "xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
         "<dc:title>%@</dc:title><dc:creator>MacDown 3000</dc:creator></cp:coreProperties>",
        safeTitle] dataUsingEncoding:NSUTF8StringEncoding]];

    // document.xml.rels (styles/numbering/header/footer + images + link targets).
    NSMutableString *rels = [NSMutableString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
         "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
         "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
         "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>"
         "<Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>"];
    // settings.xml silences Compatibility Mode: declare Word 2013+ behavior.
    NSString *settingsRelId =
        [NSString stringWithFormat:@"rId%ld", (long)w->_nextRelId++];
    [rels appendFormat:@"<Relationship Id=\"%@\" "
     "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" "
     "Target=\"settings.xml\"/>", settingsRelId];
    [w addPart:@"word/settings.xml" data:[@"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        "<w:compat><w:compatSetting w:name=\"compatibilityMode\" "
        "w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/>"
        "</w:compat></w:settings>" dataUsingEncoding:NSUTF8StringEncoding]];
    [w.contentOverrides addObject:
     @"<Override PartName=\"/word/settings.xml\" "
     "ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>"];
    for (NSDictionary *rel in w.imageRels) {
        if (MPDocxFlag(rel, @"external")) {
            [rels appendFormat:@"<Relationship Id=\"%@\" "
             "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" "
             "Target=\"%@\" TargetMode=\"External\"/>",
             MPDocxEscape(rel[@"rId"]), MPDocxEscape(rel[@"target"])];
        } else {
            [rels appendFormat:@"<Relationship Id=\"%@\" "
             "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" "
             "Target=\"%@\"/>", MPDocxEscape(rel[@"rId"]), MPDocxEscape(rel[@"target"])];
        }
    }
    [rels appendString:@"</Relationships>"];
    [w addPart:@"word/_rels/document.xml.rels" data:[rels dataUsingEncoding:NSUTF8StringEncoding]];
    [w addPart:@"_rels/.rels" data:[@"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        "</Relationships>" dataUsingEncoding:NSUTF8StringEncoding]];

    NSMutableString *types = [NSMutableString stringWithString:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
         "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
         "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
         "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
         "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
         "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
         "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
         "<Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/>"
         "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"
         "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"];
    for (NSString *override in w.contentOverrides)
        [types appendString:override];
    [types appendString:@"</Types>"];
    [w addPart:@"[Content_Types].xml" data:[types dataUsingEncoding:NSUTF8StringEncoding]];
    // Word requires [Content_Types].xml to be the first entry in the package.
    // It is assembled last (image parts are discovered while building the
    // body), so move it to the front now.
    NSUInteger typesIndex = [w.parts indexOfObjectPassingTest:^BOOL(NSDictionary *part,
                                                                   NSUInteger idx,
                                                                   BOOL *stop) {
        (void)idx; (void)stop;
        return [part[@"name"] isEqualToString:@"[Content_Types].xml"];
    }];
    if (typesIndex != NSNotFound && typesIndex > 0) {
        NSDictionary *typesPart = w.parts[typesIndex];
        [w.parts removeObjectAtIndex:typesIndex];
        [w.parts insertObject:typesPart atIndex:0];
    }

    return MPDocxZip(w.parts);
}

@end
