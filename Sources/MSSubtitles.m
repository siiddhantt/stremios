#import "MSSubtitles.h"
#import <math.h>

NSString * const MSSubtitlesErrorDomain = @"MiniStream.Subtitles";
static const NSUInteger MSSubtitleMaxBytes = 2 * 1024 * 1024;
static const NSUInteger MSSubtitleMaxCues = 20000;
static const NSUInteger MSSubtitleMaxText = 2000;
static const NSUInteger MSSubtitleMaxBlock = 16384;
static const NSUInteger MSSubtitleMaxOverlaps = 4;

@interface MSSubtitleCue ()
@property (nonatomic) NSTimeInterval startTime;
@property (nonatomic) NSTimeInterval endTime;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) NSUInteger ordinal;
- (instancetype)initWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text ordinal:(NSUInteger)ordinal;
@end

@implementation MSSubtitleCue
- (instancetype)initWithStart:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text ordinal:(NSUInteger)ordinal {
    self = [super init];
    if (self) { _startTime = start; _endTime = end; _text = [text copy]; _ordinal = ordinal; }
    return self;
}
@end

static void MSSubtitleSetError(NSError **error, MSSubtitlesErrorCode code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:MSSubtitlesErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *MSSubtitleTrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL MSSubtitleBlockDirective(NSString *first) {
    return [first isEqualToString:@"WEBVTT"] || [first hasPrefix:@"WEBVTT "] || [first hasPrefix:@"WEBVTT\t"] ||
        [first isEqualToString:@"NOTE"] || [first hasPrefix:@"NOTE "] || [first hasPrefix:@"NOTE\t"] ||
        [first isEqualToString:@"STYLE"] || [first isEqualToString:@"REGION"];
}

static NSString *MSSubtitleDecodeEntity(NSString *entity) {
    if ([entity isEqualToString:@"amp"]) return @"&";
    if ([entity isEqualToString:@"lt"]) return @"<";
    if ([entity isEqualToString:@"gt"]) return @">";
    if ([entity isEqualToString:@"quot"]) return @"\"";
    if ([entity isEqualToString:@"apos"] || [entity isEqualToString:@"#39"]) return @"'";
    if ([entity isEqualToString:@"nbsp"]) return @"\u00a0";
    if (![entity hasPrefix:@"#"]) return nil;
    NSUInteger index = 1, base = 10;
    if (entity.length > 2 && ([entity characterAtIndex:1] == 'x' || [entity characterAtIndex:1] == 'X')) {
        index = 2; base = 16;
    }
    if (index == entity.length) return nil;
    uint32_t scalar = 0;
    for (; index < entity.length; ++index) {
        unichar c = [entity characterAtIndex:index];
        NSUInteger digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (base == 16 && c >= 'a' && c <= 'f') digit = 10 + c - 'a';
        else if (base == 16 && c >= 'A' && c <= 'F') digit = 10 + c - 'A';
        else return nil;
        if (digit >= base || scalar > (0x10ffffU - digit) / base) return nil;
        scalar = (uint32_t)(scalar * base + digit);
    }
    if (scalar == 0 || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) return nil;
    if (scalar <= 0xffff) { unichar c = (unichar)scalar; return [NSString stringWithCharacters:&c length:1]; }
    scalar -= 0x10000;
    unichar pair[] = {(unichar)(0xd800 + (scalar >> 10)), (unichar)(0xdc00 + (scalar & 0x3ff))};
    return [NSString stringWithCharacters:pair length:2];
}

// Repair only the exact signatures of musical symbols decoded as a Western
// single-byte encoding. Re-encoding whole captions would damage real accents
// and non-Latin scripts. At most two mistaken decoding rounds are recognized.
static NSString *MSSubtitleRepairMusicSymbols(NSString *text) {
    static NSArray<NSArray<NSString *> *> *replacements;
    static NSCharacterSet *candidateStarts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        candidateStarts = [NSCharacterSet characterSetWithCharactersInString:@"âÃð"];
        NSMutableDictionary<NSString *, NSString *> *variants = [NSMutableDictionary dictionary];
        for (NSString *symbol in @[@"♩", @"♪", @"♫", @"♬", @"🎵", @"🎶"]) {
            NSArray<NSString *> *generation = @[symbol];
            for (NSUInteger round = 0; round < 2; round++) {
                NSMutableArray<NSString *> *next = [NSMutableArray array];
                for (NSString *prior in generation) {
                    NSData *utf8 = [prior dataUsingEncoding:NSUTF8StringEncoding];
                    for (NSNumber *encoding in @[@(NSWindowsCP1252StringEncoding), @(NSISOLatin1StringEncoding)]) {
                        NSString *damaged = [[NSString alloc] initWithData:utf8 encoding:encoding.unsignedIntegerValue];
                        if (damaged && ![damaged isEqualToString:symbol]) {
                            variants[damaged] = symbol;
                            [next addObject:damaged];
                        }
                    }
                }
                generation = next;
            }
        }
        NSArray<NSString *> *keys = [variants.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            if (a.length != b.length) return a.length > b.length ? NSOrderedAscending : NSOrderedDescending;
            return [a compare:b];
        }];
        NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:keys.count];
        for (NSString *key in keys) [pairs addObject:@[key, variants[key]]];
        replacements = [pairs copy];
    });
    if ([text rangeOfCharacterFromSet:candidateStarts].location == NSNotFound) return text;
    for (NSArray<NSString *> *pair in replacements)
        text = [text stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    return text;
}

// UTF-8/BOMs always take priority. The legacy fallback is limited to apparent
// SRT input: WebVTT requires UTF-8, and arbitrary non-UTF-8 files are not text.
static NSString *MSSubtitleLegacySRT(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
    if (!text) return nil;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c < 0x20 && c != '\t' && c != '\r' && c != '\n') || c == 0x7f) return nil;
    }
    NSString *prefix = [text substringToIndex:MIN(text.length, (NSUInteger)65536)];
    if ([MSSubtitleTrim(prefix) hasPrefix:@"WEBVTT"]) return nil;
    static NSRegularExpression *timing;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timing = [NSRegularExpression regularExpressionWithPattern:
            @"^[ \\t]*[0-9]{2,6}:[0-5][0-9]:[0-5][0-9],[0-9]{3}[ \\t]+-->[ \\t]+[0-9]{2,6}:[0-5][0-9]:[0-5][0-9],[0-9]{3}[ \\t]*\\r?$"
            options:NSRegularExpressionAnchorsMatchLines error:NULL];
    });
    return [timing firstMatchInString:prefix options:0 range:NSMakeRange(0, prefix.length)] ? text : nil;
}

static NSString *MSSubtitlePlainText(NSString *text) {
    static NSRegularExpression *breaks, *tags, *assTags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        breaks = [NSRegularExpression regularExpressionWithPattern:@"<br[ \\t]*/?>"
            options:NSRegularExpressionCaseInsensitive error:NULL];
        tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>\\n]{0,256}>" options:0 error:NULL];
        assTags = [NSRegularExpression regularExpressionWithPattern:@"\\{\\\\[^}\\n]{0,128}\\}" options:0 error:NULL];
    });
    NSString *plain = [breaks stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@"\n"];
    plain = [tags stringByReplacingMatchesInString:plain options:0 range:NSMakeRange(0, plain.length) withTemplate:@""];
    plain = [assTags stringByReplacingMatchesInString:plain options:0 range:NSMakeRange(0, plain.length) withTemplate:@""];
    NSMutableString *decoded = [NSMutableString stringWithCapacity:plain.length];
    NSUInteger index = 0;
    while (index < plain.length) {
        if ([plain characterAtIndex:index] == '&') {
            NSUInteger available = MIN((NSUInteger)12, plain.length - index);
            NSRange semicolon = [plain rangeOfString:@";" options:0 range:NSMakeRange(index, available)];
            if (semicolon.location != NSNotFound) {
                NSString *entity = [plain substringWithRange:NSMakeRange(index + 1, semicolon.location - index - 1)];
                NSString *value = MSSubtitleDecodeEntity(entity);
                if (value) { [decoded appendString:value]; index = semicolon.location + 1; continue; }
            }
        }
        [decoded appendString:[plain substringWithRange:NSMakeRange(index, 1)]];
        ++index;
    }
    return MSSubtitleTrim(MSSubtitleRepairMusicSymbols(decoded));
}

static BOOL MSSubtitleParseTime(NSString *token, NSTimeInterval *result) {
    NSArray<NSString *> *parts = [[token stringByReplacingOccurrencesOfString:@"," withString:@"."] componentsSeparatedByString:@":"];
    if (parts.count != 2 && parts.count != 3) return NO;
    double hours = parts.count == 3 ? parts[0].doubleValue : 0;
    double minutes = parts[parts.count - 2].doubleValue;
    double seconds = parts.lastObject.doubleValue;
    if (!isfinite(hours) || minutes < 0 || minutes >= 60 || seconds < 0 || seconds >= 60) return NO;
    *result = hours * 3600 + minutes * 60 + seconds;
    return isfinite(*result) && *result >= 0;
}

static BOOL MSSubtitleParseBlock(NSArray<NSString *> *lines, NSMutableArray<MSSubtitleCue *> *cues, NSError **error) {
    if (lines.count == 0 || MSSubtitleBlockDirective(MSSubtitleTrim(lines[0]))) return YES;
    NSUInteger timingIndex = [lines[0] rangeOfString:@"-->"].location != NSNotFound ? 0 : 1;
    if (timingIndex >= lines.count) return YES;
    static NSRegularExpression *timing;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *stamp = @"(?:[0-9]{1,6}:)?[0-9]{2}:[0-9]{2}[.,][0-9]{3}";
        NSString *pattern = [NSString stringWithFormat:@"^(%@)[ \\t]+-->[ \\t]+(%@)(?:[ \\t]+.*)?$", stamp, stamp];
        timing = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    });
    NSString *line = MSSubtitleTrim(lines[timingIndex]);
    NSTextCheckingResult *match = [timing firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!match) return YES;
    NSTimeInterval start, end;
    if (!MSSubtitleParseTime([line substringWithRange:[match rangeAtIndex:1]], &start) ||
        !MSSubtitleParseTime([line substringWithRange:[match rangeAtIndex:2]], &end) || end <= start) return YES;
    if (timingIndex + 1 >= lines.count) return YES;
    NSString *raw = [[lines subarrayWithRange:NSMakeRange(timingIndex + 1, lines.count - timingIndex - 1)] componentsJoinedByString:@"\n"];
    NSString *text = MSSubtitlePlainText(raw);
    if (text.length == 0) return YES;
    if (text.length > MSSubtitleMaxText || cues.count >= MSSubtitleMaxCues) {
        MSSubtitleSetError(error, MSSubtitlesErrorLimitExceeded, @"The subtitle track exceeds the cue or text limit.");
        return NO;
    }
    [cues addObject:[[MSSubtitleCue alloc] initWithStart:start end:end text:text ordinal:cues.count]];
    return YES;
}

static double MSSubtitleBuildTree(NSArray<MSSubtitleCue *> *cues, double *tree, NSUInteger node, NSUInteger lo, NSUInteger hi) {
    if (lo == hi) return tree[node] = cues[lo].endTime;
    NSUInteger mid = lo + (hi - lo) / 2;
    return tree[node] = MAX(MSSubtitleBuildTree(cues, tree, node * 2, lo, mid),
        MSSubtitleBuildTree(cues, tree, node * 2 + 1, mid + 1, hi));
}

static void MSSubtitleCollect(NSArray<MSSubtitleCue *> *cues, const double *tree, NSUInteger node,
    NSUInteger lo, NSUInteger hi, NSUInteger lastStarted, NSTimeInterval time, NSMutableArray<NSString *> *texts) {
    if (texts.count >= MSSubtitleMaxOverlaps || lo > lastStarted || tree[node] <= time) return;
    if (lo == hi) { [texts addObject:cues[lo].text]; return; }
    NSUInteger mid = lo + (hi - lo) / 2;
    MSSubtitleCollect(cues, tree, node * 2, lo, mid, lastStarted, time, texts);
    MSSubtitleCollect(cues, tree, node * 2 + 1, mid + 1, hi, lastStarted, time, texts);
}

@interface MSSubtitleTrack ()
@property (nonatomic, copy) NSArray<MSSubtitleCue *> *cues;
@property (nonatomic, copy) NSData *maximumEndTree;
@end

@implementation MSSubtitleTrack
- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)error {
    if (error) *error = nil;
    if (data.length == 0) { MSSubtitleSetError(error, MSSubtitlesErrorEmpty, @"The subtitle file is empty."); return nil; }
    if (data.length > MSSubtitleMaxBytes) { MSSubtitleSetError(error, MSSubtitlesErrorLimitExceeded, @"Subtitle files must be 2 MiB or smaller."); return nil; }
    const unsigned char *bytes = data.bytes;
    if (data.length >= 2 && ((bytes[0] == 'P' && bytes[1] == 'K') || (bytes[0] == 0x1f && bytes[1] == 0x8b))) {
        MSSubtitleSetError(error, MSSubtitlesErrorUnsupportedFormat, @"Compressed subtitles are not supported. Choose SRT or WebVTT text."); return nil;
    }
    NSStringEncoding encoding = NSUTF8StringEncoding;
    NSUInteger bom = 0;
    if (data.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) { encoding = NSUTF16LittleEndianStringEncoding; bom = 2; }
    else if (data.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) { encoding = NSUTF16BigEndianStringEncoding; bom = 2; }
    else if (data.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) bom = 3;
    if (bom == 2 && (data.length - bom) % 2 != 0) {
        MSSubtitleSetError(error, MSSubtitlesErrorInvalidEncoding, @"The UTF-16 subtitle file has an incomplete character."); return nil;
    }
    NSData *textData = bom ? [data subdataWithRange:NSMakeRange(bom, data.length - bom)] : data;
    NSString *text = [[NSString alloc] initWithData:textData encoding:encoding];
    if (!text && bom == 0) text = MSSubtitleLegacySRT(textData);
    if (!text) { MSSubtitleSetError(error, MSSubtitlesErrorInvalidEncoding, @"Use UTF-8, BOM-marked UTF-16, or Windows-1252 SRT subtitles."); return nil; }
    unichar null = 0;
    if ([text rangeOfString:[NSString stringWithCharacters:&null length:1]].location != NSNotFound) {
        MSSubtitleSetError(error, MSSubtitlesErrorInvalidEncoding, @"The subtitle file contains binary data."); return nil;
    }
    NSString *trimmed = MSSubtitleTrim(text);
    if (trimmed.length == 0) { MSSubtitleSetError(error, MSSubtitlesErrorEmpty, @"The subtitle file is empty."); return nil; }
    NSString *prefix = [[trimmed substringToIndex:MIN(trimmed.length, (NSUInteger)128)] lowercaseString];
    if ([prefix hasPrefix:@"[script info]"] || [prefix hasPrefix:@"[v4+ styles]"] || [prefix hasPrefix:@"[v4 styles]"] ||
        [prefix hasPrefix:@"<!doctype"] || [prefix hasPrefix:@"<html"] || [prefix hasPrefix:@"<?xml"]) {
        MSSubtitleSetError(error, MSSubtitlesErrorUnsupportedFormat, @"This track is not SRT or WebVTT. ASS, SSA, and HTML are not supported."); return nil;
    }
    NSMutableArray<MSSubtitleCue *> *parsed = [NSMutableArray array];
    NSMutableArray<NSString *> *block = [NSMutableArray array];
    __block NSUInteger blockLength = 0;
    __block BOOL skippingDirective = NO;
    __block NSError *parseError = nil;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByLines
        usingBlock:^(NSString *line, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            (void)substringRange; (void)enclosingRange;
            NSString *trim = MSSubtitleTrim(line);
            if (trim.length == 0) {
                if (!skippingDirective && !MSSubtitleParseBlock(block, parsed, &parseError)) *stop = YES;
                [block removeAllObjects]; blockLength = 0; skippingDirective = NO;
                return;
            }
            if (skippingDirective) return;
            if (block.count == 0 && MSSubtitleBlockDirective(trim)) { skippingDirective = YES; return; }
            blockLength += line.length + 1;
            if (blockLength > MSSubtitleMaxBlock || block.count >= 512) {
                MSSubtitleSetError(&parseError, MSSubtitlesErrorLimitExceeded, @"A subtitle cue block is too large."); *stop = YES; return;
            }
            [block addObject:line];
        }];
    if (!parseError && !skippingDirective) MSSubtitleParseBlock(block, parsed, &parseError);
    if (parseError) { if (error) *error = parseError; return nil; }
    if (parsed.count == 0) { MSSubtitleSetError(error, MSSubtitlesErrorInvalidFormat, @"No valid SRT or WebVTT cues were found."); return nil; }
    [parsed sortUsingComparator:^NSComparisonResult(MSSubtitleCue *a, MSSubtitleCue *b) {
        if (a.startTime < b.startTime) return NSOrderedAscending;
        if (a.startTime > b.startTime) return NSOrderedDescending;
        if (a.ordinal < b.ordinal) return NSOrderedAscending;
        if (a.ordinal > b.ordinal) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    self = [super init];
    if (self) {
        _cues = [parsed copy];
        NSMutableData *tree = [NSMutableData dataWithLength:sizeof(double) * (parsed.count * 4 + 1)];
        MSSubtitleBuildTree(_cues, tree.mutableBytes, 1, 0, _cues.count - 1);
        _maximumEndTree = [tree copy];
    }
    return self;
}

- (NSString *)textAtTime:(NSTimeInterval)time {
    if (!isfinite(time) || time < 0 || self.cues.count == 0) return @"";
    NSUInteger lo = 0, hi = self.cues.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (self.cues[mid].startTime <= time) lo = mid + 1; else hi = mid;
    }
    if (lo == 0) return @"";
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:MSSubtitleMaxOverlaps];
    MSSubtitleCollect(self.cues, self.maximumEndTree.bytes, 1, 0, self.cues.count - 1, lo - 1, time, texts);
    return [texts componentsJoinedByString:@"\n"];
}
@end
