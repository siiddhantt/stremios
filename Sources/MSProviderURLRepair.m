#import "MSProviderURLRepair.h"

// Pinned upstream behavior: MediaFusion 6.2.0 / commit f01aba8bfbfe0c31ead9463e05f0a361ddc651fc.
// routes/stream.rs keeps the configured path secret when encoded_user_data is
// absent. torrent_privacy_middleware.rs private_url() seals the reference using
// that secret, then redact_private() accidentally scrubs hash-like runs in it.
// This reproduces ONLY hash_ranges()/redact(), never decrypts a reference, and
// leaves the signed reference, selected file, origin, and configuration intact.
static NSString *MSMediaFusionRedactedComponent(NSString *text) {
    static NSArray<NSRegularExpression *> *patterns; static dispatch_once_t once;
    dispatch_once(&once, ^{
        patterns = @[
            [NSRegularExpression regularExpressionWithPattern:@"[a-f0-9]{40,}" options:NSRegularExpressionCaseInsensitive error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"[a-z2-7]{32,}" options:NSRegularExpressionCaseInsensitive error:nil]
        ];
    });
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    for (NSRegularExpression *pattern in patterns)
        for (NSTextCheckingResult *match in [pattern matchesInString:text options:0 range:NSMakeRange(0,text.length)])
            [ranges addObject:[NSValue valueWithRange:match.range]];
    [ranges sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        if (a.rangeValue.location != b.rangeValue.location) return a.rangeValue.location < b.rangeValue.location ? NSOrderedAscending : NSOrderedDescending;
        return a.rangeValue.length < b.rangeValue.length ? NSOrderedAscending : a.rangeValue.length > b.rangeValue.length ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *merged = [NSMutableArray array];
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue, last = merged.lastObject.rangeValue;
        if (merged.count && range.location <= NSMaxRange(last)) {
            merged[merged.count-1] = [NSValue valueWithRange:NSMakeRange(last.location,MAX(NSMaxRange(last),NSMaxRange(range))-last.location)];
        } else [merged addObject:value];
    }
    NSMutableString *result = [NSMutableString string]; NSUInteger cursor = 0;
    for (NSValue *value in merged) {
        NSRange range = value.rangeValue;
        [result appendString:[text substringWithRange:NSMakeRange(cursor,range.location-cursor)]];
        [result appendString:@"[redacted]"]; cursor = NSMaxRange(range);
    }
    [result appendString:[text substringFromIndex:cursor]]; return result;
}

static BOOL MSRepairMatches(NSString *text, NSString *pattern) {
    NSRange range = [text rangeOfString:pattern options:NSRegularExpressionSearch];
    return range.location == 0 && range.length == text.length;
}
static BOOL MSRepairOrigin(NSURLComponents *components) {
    return [components.scheme.lowercaseString isEqual:@"https"] &&
        [components.host.lowercaseString isEqual:@"mediafusion.elfhosted.com"] &&
        (!components.port || components.port.integerValue == 443) &&
        !components.user && !components.password && !components.query && !components.fragment;
}
static NSString *MSRepairCanonicalPath(NSURLComponents *components) {
    // Only the literal placeholder brackets may be percent-encoded. Reject
    // encoded slashes/dots/letters, double encoding, traversal and ambiguity.
    NSString *encoded = components.percentEncodedPath;
    encoded = [encoded stringByReplacingOccurrencesOfString:@"%5B" withString:@"[" options:NSCaseInsensitiveSearch range:NSMakeRange(0,encoded.length)];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"%5D" withString:@"]" options:NSCaseInsensitiveSearch range:NSMakeRange(0,encoded.length)];
    return [encoded isEqual:components.path] ? encoded : nil;
}

NSURL *MSRestoreMediaFusionPlaybackURL(NSURL *URL, NSURL *manifestURL, NSString *addonIdentifier) {
    if (![addonIdentifier isEqual:@"stremio.addons.mediafusion|elfhostedtrb"] ||
        !URL || !manifestURL || URL.absoluteString.length > 16384 || manifestURL.absoluteString.length > 8192) return URL;
    NSURLComponents *source = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSURLComponents *manifest = [NSURLComponents componentsWithURL:manifestURL resolvingAgainstBaseURL:NO];
    if (!MSRepairOrigin(source) || !MSRepairOrigin(manifest)) return URL;
    NSString *path = MSRepairCanonicalPath(source), *manifestPath = MSRepairCanonicalPath(manifest);
    if (!path || !manifestPath) return URL;
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSArray<NSString *> *configParts = [manifestPath componentsSeparatedByString:@"/"];
    if (parts.count != 6 || configParts.count != 3 || parts[0].length || configParts[0].length ||
        ![parts[1] isEqual:@"streaming_provider"] || ![parts[3] isEqual:@"playback"] ||
        ![parts[4] isEqual:@"torbox"] || ![configParts[2] isEqual:@"manifest.json"]) return URL;
    NSString *known = configParts[1], *returned = parts[2], *reference = parts[5];
    if (known.length > 4096 || !MSRepairMatches(known,@"D-[A-Za-z0-9_-]{32,4094}") ||
        ![returned containsString:@"[redacted]"] ||
        !MSRepairMatches(reference,@"T-[A-Za-z0-9_-]{22,4096}\\.[A-Za-z0-9_-]{43}") ||
        ![MSMediaFusionRedactedComponent(known) isEqual:returned]) return URL;
    NSMutableArray<NSString *> *restoredParts = [parts mutableCopy]; restoredParts[2] = known;
    // All accepted components are ASCII URL-safe; only the known component is
    // replaced. No query, redirect, token, filename or account data is invented.
    source.percentEncodedPath = [restoredParts componentsJoinedByString:@"/"];
    return source.URL ?: URL;
}
