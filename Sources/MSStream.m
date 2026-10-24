#import "MSStream.h"
#import "MSHTTPClient.h"
#import "MSLibraryStore.h"
static NSString *MSText(id value, NSUInteger limit) { if (![value isKindOfClass:NSString.class]) return @""; return [value length] > limit ? [value substringToIndex:limit] : value; }
static BOOL MSHasLabel(NSString *labels, NSString *pattern) {
    static NSCache<NSString *,NSRegularExpression *> *expressions; static dispatch_once_t once;
    dispatch_once(&once, ^{ expressions = [NSCache new]; expressions.countLimit = 40; });
    NSRegularExpression *expression = [expressions objectForKey:pattern];
    if (!expression) { expression = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil]; if (expression) [expressions setObject:expression forKey:pattern]; }
    return [expression firstMatchInString:labels options:0 range:NSMakeRange(0, labels.length)] != nil;
}
static NSString *MSRedactAddresses(NSString *text) {
    static NSRegularExpression *addresses; static dispatch_once_t once;
    dispatch_once(&once, ^{ addresses = [NSRegularExpression regularExpressionWithPattern:@"(?i)(?:https?://|stremio://)\\S+" options:0 error:nil]; });
    return [addresses stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"[private link]"];
}
@implementation MSStream
+ (instancetype)streamWithDictionary:(NSDictionary *)raw addonName:(NSString *)addon {
    return [self streamWithDictionary:raw addonName:addon addonIdentifier:addon];
}
+ (instancetype)streamWithDictionary:(NSDictionary *)raw addonName:(NSString *)addon addonIdentifier:(NSString *)identifier {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    MSStream *stream = [self new];
    NSString *sourceName = MSRedactAddresses(MSText(raw[@"name"], 200));
    stream->_providerName = MSRedactAddresses(MSText(addon, 160));
    stream->_providerIdentifier = MSText(identifier, 200);
    stream->_name = !sourceName.length ? stream.providerName : [sourceName rangeOfString:stream.providerName options:NSCaseInsensitiveSearch].location != NSNotFound ? sourceName : [NSString stringWithFormat:@"%@ · %@",stream.providerName,sourceName];
    stream->_detail = MSRedactAddresses(MSText(raw[@"description"] ?: raw[@"title"], 3000));
    NSDictionary *hints = [raw[@"behaviorHints"] isKindOfClass:NSDictionary.class] ? raw[@"behaviorHints"] : @{};
    NSMutableDictionary *extras = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"filename", @"videoHash", @"videoSize"]) {
        id value = hints[key]; if ([key isEqualToString:@"videoSize"] && [value isKindOfClass:NSNumber.class]) value = [value stringValue];
        if ([value isKindOfClass:NSString.class] && [value length] && [value length] <= 1024) extras[key] = value;
    }
    stream->_subtitleExtras = [extras copy];
    stream->_filename = MSRedactAddresses(extras[@"filename"] ?: @"");
    stream->_bingeGroup = MSText(hints[@"bingeGroup"], 400);
    stream->_sourceFingerprint = [MSLibraryStore sourceFingerprintForProvider:stream.providerIdentifier filename:stream.filename name:sourceName detail:stream.detail];
    NSMutableArray *subtitles = [NSMutableArray array];
    if ([raw[@"subtitles"] isKindOfClass:NSArray.class]) for (id subtitle in raw[@"subtitles"]) {
        if (subtitles.count >= 200) break;
        if (![subtitle isKindOfClass:NSDictionary.class]) continue;
        NSString *address = [subtitle[@"url"] isKindOfClass:NSString.class] && [subtitle[@"url"] length] <= 16384 ? subtitle[@"url"] : @"";
        if (!MSIsSafeRemoteURL([NSURL URLWithString:address])) continue;
        NSMutableDictionary *entry = [@{@"url":address} mutableCopy];
        for (NSString *key in @[@"id", @"lang", @"releaseName", @"filename"]) if ([subtitle[key] isKindOfClass:NSString.class]) entry[key] = MSText(subtitle[key],300);
        [subtitles addObject:entry];
    }
    stream->_providedSubtitles = [subtitles copy];
    NSString *URLText = [raw[@"url"] isKindOfClass:NSString.class] && [raw[@"url"] length] <= 16384 ? raw[@"url"] : @"";
    NSURL *url = [NSURL URLWithString:URLText]; stream->_URL = MSIsSafeRemoteURL(url) ? url : nil;
    NSString *labels = [NSString stringWithFormat:@"%@ %@ %@ %@", stream.name, stream.detail, stream.filename, url.pathExtension ?: @""];
    stream->_reportedResolution = @"";
    for (NSString *resolution in @[@"2160", @"1440", @"1080", @"720", @"576", @"480", @"360"]) {
        if (MSHasLabel(labels, [NSString stringWithFormat:@"\\b%@[pi]\\b",resolution])) { stream->_reportedResolution = [resolution stringByAppendingString:@"p"]; break; }
    }
    if (!stream.reportedResolution.length && MSHasLabel(labels,@"\\b4k\\b")) stream->_reportedResolution = @"2160p";
    NSMutableArray *formats = [NSMutableArray array];
    if (MSHasLabel(labels,@"\\b(?:hevc|h[ .]?265|x265)\\b")) [formats addObject:@"HEVC / H.265"];
    else if (MSHasLabel(labels,@"\\b(?:avc|h[ .]?264|x264)\\b")) [formats addObject:@"H.264"];
    else if (MSHasLabel(labels,@"\\bav1\\b")) [formats addObject:@"AV1"];
    for (NSString *format in @[@"AAC", @"AC-3", @"EAC3", @"DTS", @"TrueHD"]) {
        if (MSHasLabel(labels,[NSString stringWithFormat:@"\\b%@\\b",format])) [formats addObject:format];
    }
    NSString *extension = url.pathExtension.lowercaseString;
    if (![@[@"mp4", @"mkv", @"avi", @"webm", @"m3u8"] containsObject:extension]) extension = stream.filename.pathExtension.lowercaseString;
    if ([@[@"mp4", @"mkv", @"avi", @"webm", @"m3u8"] containsObject:extension]) [formats addObject:[extension isEqualToString:@"m3u8"] ? @"HLS" : extension.uppercaseString];
    stream->_codecLabel = formats.count ? [formats componentsJoinedByString:@" · "] : @"Format unreported";
    // Containers and common audio codecs are handled by VideoLAN; the A7
    // still needs conversion for newer/heavier video formats.
    stream->_prefersVLC = MSHasLabel(labels,@"\\b(?:dts|truehd|flac|pcm)\\b");
    BOOL needsConversion = MSHasLabel(labels,@"\\b(?:2160p|4k|hevc|h[ .]?265|x265|av1|vp9|hdr|10[ -]?bit)\\b");
    if ([hints[@"proxyHeaders"] isKindOfClass:NSDictionary.class] && [hints[@"proxyHeaders"] count]) stream->_compatibility = @"Needs a header-aware playback helper.";
    else if (raw[@"infoHash"] && !stream.URL) stream->_compatibility = @"Torrent source. Needs a streaming helper.";
    else if (!stream.URL) stream->_compatibility = @"No supported HTTPS video link.";
    else if (needsConversion) stream->_compatibility = @"Reported format needs conversion on this iPad. Choose a 720p or 1080p H.264 source.";
    else { stream->_canAttemptPlayback = YES; stream->_compatibility = @"The video format is checked when you press Play."; }
    return stream;
}
- (BOOL)matchesProvider:(NSString *)provider resolution:(NSString *)resolution compatibleOnly:(BOOL)compatibleOnly {
    return (!compatibleOnly || self.canAttemptPlayback) && (!provider.length || [provider isEqualToString:self.providerIdentifier]) && (!resolution.length || [resolution isEqualToString:(self.reportedResolution.length ? self.reportedResolution : @"unreported")]);
}
@end
