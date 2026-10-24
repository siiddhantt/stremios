#import <Foundation/Foundation.h>
#import "MSSubtitles.h"
#import <math.h>

static unsigned checks = 0, failures = 0;
static void check(BOOL condition, const char *name) {
    ++checks;
    if (!condition) { ++failures; fprintf(stderr, "FAIL subtitles: %s\n", name); }
}
static MSSubtitleTrack *track(NSString *text) {
    return [[MSSubtitleTrack alloc] initWithData:[text dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
}
static BOOL rejects(NSData *data, MSSubtitlesErrorCode code) {
    NSError *error = nil;
    MSSubtitleTrack *result = [[MSSubtitleTrack alloc] initWithData:data error:&error];
    return !result && [error.domain isEqualToString:MSSubtitlesErrorDomain] && error.code == code;
}
static NSData *utf16WithBOM(NSString *text, BOOL little) {
    const unsigned char le[] = {0xff, 0xfe}, be[] = {0xfe, 0xff};
    NSMutableData *data = [NSMutableData dataWithBytes:little ? le : be length:2];
    [data appendData:[text dataUsingEncoding:little ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding]];
    return data;
}
static NSString *oneCue(NSString *text) {
    return [NSString stringWithFormat:@"1\n00:00:00,000 --> 00:00:02,000\n%@\n", text];
}
static NSString *misdecoded(NSString *text, NSStringEncoding encoding) {
    return [[NSString alloc] initWithData:[text dataUsingEncoding:NSUTF8StringEncoding] encoding:encoding];
}

int main(void) {
    @autoreleasepool {
        NSString *srt = @"1\r\n00:00:01,250 --> 00:00:03,500\r\nHello\r\nworld\r\n\r\n2\r\n00:00:05,000 --> 00:00:06,000\r\nLater\r\n";
        MSSubtitleTrack *basic = track(srt);
        check(basic.cues.count == 2, "SRT CRLF cues parsed");
        check(fabs(basic.cues[0].startTime - 1.25) < 0.00001 && fabs(basic.cues[0].endTime - 3.5) < 0.00001, "millisecond timestamps");
        check([[basic textAtTime:0] isEqual:@""], "before first cue");
        check([[basic textAtTime:1.25] isEqual:@"Hello\nworld"], "start inclusive and multiline");
        check([[basic textAtTime:3.5] isEqual:@""], "end exclusive");
        check([[basic textAtTime:4] isEqual:@""], "gap has no stale cue");
        check([[basic textAtTime:5.5] isEqual:@"Later"], "forward seek");
        check([[basic textAtTime:1.5] isEqual:@"Hello\nworld"], "backward seek");
        check([[basic textAtTime:10000] isEqual:@""], "after last cue");
        check([[basic textAtTime:NAN] isEqual:@""] && [[basic textAtTime:INFINITY] isEqual:@""] && [[basic textAtTime:-1] isEqual:@""], "invalid query times");

        NSString *vtt = @"WEBVTT demo\nKind: captions\n\nNOTE ignored --> text\nnot a cue\n\nSTYLE\n::cue {color: red;}\n\nREGION\nid:bottom\n\ncaption-id\n00:01.000 --> 00:02.500 align:start position:20% line:90%\n<v Speaker><b>Hi</b> &amp; &lt;hello&gt;<br/>there</v>\n\n00:03.000 --> 00:04.000\n<c.yellow>次の字幕 😀</c>\n";
        MSSubtitleTrack *web = track(vtt);
        check(web.cues.count == 2, "WebVTT header directives cue IDs and settings");
        check([[web textAtTime:1.5] isEqual:@"Hi & <hello>\nthere"], "basic markup and entities become plain text");
        check([[web textAtTime:3.2] isEqual:@"次の字幕 😀"], "UTF-8 Unicode survives");
        MSSubtitleTrack *le = [[MSSubtitleTrack alloc] initWithData:utf16WithBOM(vtt, YES) error:NULL];
        MSSubtitleTrack *be = [[MSSubtitleTrack alloc] initWithData:utf16WithBOM(vtt, NO) error:NULL];
        check([[le textAtTime:3.2] isEqual:@"次の字幕 😀"], "UTF-16 little-endian BOM");
        check([[be textAtTime:3.2] isEqual:@"次の字幕 😀"], "UTF-16 big-endian BOM");
        NSMutableData *bom8 = [NSMutableData dataWithBytes:"\xef\xbb\xbf" length:3];
        [bom8 appendData:[srt dataUsingEncoding:NSUTF8StringEncoding]];
        check([[[[MSSubtitleTrack alloc] initWithData:bom8 error:NULL] textAtTime:5.5] isEqual:@"Later"], "UTF-8 BOM");

        NSString *music = @"♩ ♪ Lyrics ♫ ♬ 🎵 🎶";
        NSString *musicSRT = oneCue(music);
        check([[track(musicSRT) textAtTime:1] isEqual:music], "correct UTF-8 musical symbols unchanged");
        NSMutableData *musicBOM = [NSMutableData dataWithBytes:"\xef\xbb\xbf" length:3];
        [musicBOM appendData:[musicSRT dataUsingEncoding:NSUTF8StringEncoding]];
        check([[[[MSSubtitleTrack alloc] initWithData:musicBOM error:NULL] textAtTime:1] isEqual:music], "musical symbols with UTF-8 BOM");
        check([[[[MSSubtitleTrack alloc] initWithData:utf16WithBOM(musicSRT, YES) error:NULL] textAtTime:1] isEqual:music], "musical symbols with UTF-16 LE BOM");
        check([[[[MSSubtitleTrack alloc] initWithData:utf16WithBOM(musicSRT, NO) error:NULL] textAtTime:1] isEqual:music], "musical symbols with UTF-16 BE BOM");
        check([[track(oneCue(@"â™ª Lyrics â™«")) textAtTime:1] isEqual:@"♪ Lyrics ♫"], "known CP1252 musical-note mojibake repaired");
        NSString *latin1Music = [NSString stringWithFormat:@"â%Cª Lyrics â%C«", (unichar)0x99, (unichar)0x99];
        check([[track(oneCue(latin1Music)) textAtTime:1] isEqual:@"♪ Lyrics ♫"], "known Latin1 musical-note mojibake repaired");
        check([[track(oneCue(@"Ã¢â„¢Âª Lyrics Ã¢â„¢Â«")) textAtTime:1] isEqual:@"♪ Lyrics ♫"], "known double CP1252 musical-note mojibake repaired");
        check([[track(oneCue(misdecoded(music, NSWindowsCP1252StringEncoding))) textAtTime:1] isEqual:music], "all supported music symbols repair CP1252 misdecode");
        check([[track(oneCue(misdecoded(music, NSISOLatin1StringEncoding))) textAtTime:1] isEqual:music], "all supported music symbols repair Latin1 misdecode");
        for (NSNumber *firstEncoding in @[@(NSWindowsCP1252StringEncoding), @(NSISOLatin1StringEncoding)]) {
            for (NSNumber *secondEncoding in @[@(NSWindowsCP1252StringEncoding), @(NSISOLatin1StringEncoding)]) {
                NSString *damaged = misdecoded(misdecoded(music, firstEncoding.unsignedIntegerValue), secondEncoding.unsignedIntegerValue);
                check(damaged && [[track(oneCue(damaged)) textAtTime:1] isEqual:music], "bounded double mixed-encoding musical symbols repaired");
            }
        }
        NSString *foreign = @"café São Tomé français â Ã ™ ð — Ελληνικά Русский العربية हिन्दी 日本語 中文 한국어 😀";
        check([[track(oneCue(foreign)) textAtTime:1] isEqual:foreign], "legitimate accents and non-Latin scripts unchanged");
        NSString *nearMatch = @"â™x Ã¢ café; price 99ª, trademark ™, letter â";
        check([[track(oneCue(nearMatch)) textAtTime:1] isEqual:nearMatch], "near matches and isolated Western characters are not stripped");
        check([[track(oneCue(@"日本語 â™ª café â™« العربية")) textAtTime:1] isEqual:@"日本語 ♪ café ♫ العربية"], "repair leaves surrounding genuine foreign text intact");
        check([[track(oneCue(@"&#226;&#8482;&#170; &#9835;")) textAtTime:1] isEqual:@"♪ ♫"], "numeric entities repair after one entity-decoding pass");
        check([[track(@"WEBVTT\n\n00:00.000 --> 00:02.000\nâ™ª Lyrics â™«\n") textAtTime:1] isEqual:@"♪ Lyrics ♫"], "valid UTF-8 WebVTT musical mojibake repaired");
        NSString *legacyText = @"café — “São Tomé” déjà vu";
        NSData *legacyBytes = [oneCue(legacyText) dataUsingEncoding:NSWindowsCP1252StringEncoding];
        check([[[[MSSubtitleTrack alloc] initWithData:legacyBytes error:NULL] textAtTime:1] isEqual:legacyText], "recognizable Windows-1252 SRT preserves real accents and quotes");
        // CP1252 cannot encode a music note. A mixed legacy file may contain
        // its UTF-8 bytes alongside genuine CP1252 accents; both must survive.
        NSData *mixedLegacy = [oneCue(@"â™ª café — lyrics â™«") dataUsingEncoding:NSWindowsCP1252StringEncoding];
        check([[[[MSSubtitleTrack alloc] initWithData:mixedLegacy error:NULL] textAtTime:1] isEqual:@"♪ café — lyrics ♫"], "mixed legacy CP1252 and UTF-8 musical-note bytes repaired");
        NSMutableData *incorrectBOM = [NSMutableData dataWithBytes:"\xef\xbb\xbf" length:3];
        [incorrectBOM appendData:legacyBytes];
        check(rejects(incorrectBOM, MSSubtitlesErrorInvalidEncoding), "explicit UTF-8 BOM never falls back to legacy encoding");
        NSMutableData *brokenUTF16 = [utf16WithBOM(musicSRT, YES) mutableCopy];
        [brokenUTF16 appendBytes:"x" length:1];
        check(rejects(brokenUTF16, MSSubtitlesErrorInvalidEncoding), "malformed BOM-marked UTF-16 never falls back");
        NSMutableData *legacyBinary = [legacyBytes mutableCopy];
        [legacyBinary appendBytes:"\001" length:1];
        check(rejects(legacyBinary, MSSubtitlesErrorInvalidEncoding), "legacy detection rejects binary control bytes");
        check(rejects([@"café — no timing" dataUsingEncoding:NSWindowsCP1252StringEncoding], MSSubtitlesErrorInvalidEncoding), "legacy fallback requires recognizable SRT timing");
        check(rejects([@"WEBVTT\n\n00:00:00,000 --> 00:00:02,000\ncafé\n" dataUsingEncoding:NSWindowsCP1252StringEncoding], MSSubtitlesErrorInvalidEncoding), "legacy fallback does not silently reinterpret non-UTF8 WebVTT");

        MSSubtitleTrack *entities = track(@"1\n00:00:00,000 --> 00:00:02,000\n{\\an8}<font color=red>&#65; &#x1F600; &quot;x&quot; &apos;y&apos; &amp;lt; &#0; &#xD800;</font>\n");
        check([[entities textAtTime:1] isEqual:@"A 😀 \"x\" 'y' &lt; &#0; &#xD800;"], "numeric entities valid scalar and no double decoding");

        MSSubtitleTrack *unsorted = track(@"later\n00:01:00.000 --> 00:01:02.000\nB\n\nlong\n00:00:00.000 --> 10:00:00.000\nLong\n\nshort\n00:00:01.000 --> 00:00:02.000\nA\n\nfuture\n20:00:00.000 --> 20:00:01.000\nFuture\n");
        check(unsorted.cues.count == 4 && unsorted.cues[0].startTime == 0, "unsorted cues ordered");
        check([[unsorted textAtTime:1.5] isEqual:@"Long\nA"], "overlapping cues");
        check([[unsorted textAtTime:61] isEqual:@"Long\nB"], "long overlap survives later cue search");
        check([[unsorted textAtTime:200] isEqual:@"Long"], "long overlap survives expired intervening cues");
        check([[unsorted textAtTime:72000] isEqual:@"Future"], "future cue only at its time");
        check([[unsorted textAtTime:1.5] isEqual:@"Long\nA"], "backward search after distant future");

        NSMutableString *overlaps = [NSMutableString string];
        for (NSUInteger i = 0; i < 8; ++i) [overlaps appendFormat:@"%lu\n00:00:00,000 --> 00:00:10,000\n%lu\n\n", (unsigned long)i, (unsigned long)i];
        check([[track(overlaps) textAtTime:1] isEqual:@"0\n1\n2\n3"], "overlap output capped at four in stable order");

        MSSubtitleTrack *mixed = track(@"1\n00:99:00,000 --> 01:00:00,000\nBad minutes\n\n2\n00:00:01,000 --> 00:00:01,000\nZero duration\n\n3\n00:00:02,000 --> 00:00:01,000\nBackwards\n\n4\n00:00:04,000 --> 00:00:05,000\nGood\n\n5\n-00:00:00,000 --> 00:00:02,000\nNegative\n\n6\n00:00:00,000 --> 00:00:02,000\n<b></b>\n");
        check(mixed.cues.count == 1 && [[mixed textAtTime:4.5] isEqual:@"Good"], "malformed empty and reversed cues skipped");
        check(track(@"1\n00:00:60,000 --> 00:01:02,000\nNo\n") == nil, "invalid seconds rejected");
        check(track(@"1\n00:00:01,0 --> 00:00:02,000\nNo\n") == nil, "malformed millisecond syntax rejected");
        check(track(@"1\n00:00:01,000-->00:00:02,000\nNo\n") == nil, "malformed timing separator rejected");
        check(rejects([NSData data], MSSubtitlesErrorEmpty), "empty bytes error");
        check(rejects([@" \n\r\n" dataUsingEncoding:NSUTF8StringEncoding], MSSubtitlesErrorEmpty), "whitespace empty error");
        check(rejects([@"WEBVTT\n\nNOTE nothing\n" dataUsingEncoding:NSUTF8StringEncoding], MSSubtitlesErrorInvalidFormat), "no valid cues error");
        check(rejects([@"[Script Info]\nScriptType: v4.00+" dataUsingEncoding:NSUTF8StringEncoding], MSSubtitlesErrorUnsupportedFormat), "ASS rejected");
        check(rejects([@"<!doctype html><html><script>alert(1)</script></html>" dataUsingEncoding:NSUTF8StringEncoding], MSSubtitlesErrorUnsupportedFormat), "HTML response rejected");
        check(rejects([NSData dataWithBytes:"PK\003\004" length:4], MSSubtitlesErrorUnsupportedFormat), "ZIP rejected");
        check(rejects([NSData dataWithBytes:"\037\213\010" length:3], MSSubtitlesErrorUnsupportedFormat), "gzip payload rejected");
        check(rejects([NSData dataWithBytes:"\377\340\200" length:3], MSSubtitlesErrorInvalidEncoding), "invalid UTF-8 rejected");
        NSMutableData *binary = [[srt dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [binary appendBytes:"\0" length:1];
        check(rejects(binary, MSSubtitlesErrorInvalidEncoding), "binary null rejected");
        check(rejects([NSMutableData dataWithLength:2 * 1024 * 1024 + 1], MSSubtitlesErrorLimitExceeded), "input byte limit");
        NSString *longText = [@"x" stringByPaddingToLength:2001 withString:@"x" startingAtIndex:0];
        check(rejects([[NSString stringWithFormat:@"1\n00:00:01,000 --> 00:00:02,000\n%@\n", longText] dataUsingEncoding:NSUTF8StringEncoding], MSSubtitlesErrorLimitExceeded), "cue text limit");
        NSString *edgeText = [longText substringToIndex:2000];
        check([track([NSString stringWithFormat:@"1\n00:00:01,000 --> 00:00:02,000\n%@\n", edgeText]) textAtTime:1].length == 2000, "cue text boundary accepted");

        NSMutableString *many = [NSMutableString string];
        for (NSUInteger i = 0; i < 20000; ++i) [many appendFormat:@"%lu\n00:00:01,000 --> 00:00:02,000\nx\n\n", (unsigned long)i];
        MSSubtitleTrack *large = track(many);
        check(large.cues.count == 20000, "maximum cue count accepted");
        check([[large textAtTime:1.5] isEqual:@"x\nx\nx\nx"] && [[large textAtTime:3] isEqual:@""], "large interval index remains bounded");
        [many appendString:@"overflow\n00:00:01,000 --> 00:00:02,000\nx\n\n"];
        check(rejects([many dataUsingEncoding:NSUTF8StringEncoding], MSSubtitlesErrorLimitExceeded), "cue count overflow rejected");

        NSError *oldError = [NSError errorWithDomain:@"old" code:1 userInfo:nil];
        MSSubtitleTrack *clearsError = [[MSSubtitleTrack alloc] initWithData:[srt dataUsingEncoding:NSUTF8StringEncoding] error:&oldError];
        check(clearsError != nil && oldError == nil, "successful parse clears output error");
        fprintf(failures ? stderr : stdout, "%s %u subtitle parser and timeline checks\n", failures ? "FAIL" : "PASS", checks);
        return failures ? 1 : 0;
    }
}
