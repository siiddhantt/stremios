#import "MSLibraryStore.h"
#import "MSPlaybackPolicy.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

NSString * const MSLibraryDidChangeNotification = @"MSLibraryDidChange";
static NSString * const MSRecordsKey = @"library.records.v2";
static NSString * const MSFavoritesKey = @"library.favorites.v1";
static NSString * const MSProgressKey = @"library.progress.v1";
static NSUInteger const MSRecordLimit = 300;
static NSUInteger const MSRecordBytesLimit = 1024 * 1024;
static NSTimeInterval const MSMaximumDuration = 7 * 24 * 60 * 60;

static NSString *MSLibraryText(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > limit) return @"";
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([text rangeOfString:@"://"].location != NSNotFound || [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return @"";
    return text;
}
static NSString *MSLibraryID(id value) { return MSLibraryText(value, 1024); }
static double MSLibraryNumber(id value, double maximum) {
    if (![value isKindOfClass:NSNumber.class]) return 0;
    double number = [value doubleValue]; return isfinite(number) && number >= 0 && number <= maximum ? number : 0;
}
static NSString *MSLibraryPoster(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 2048) return @"";
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if (![parts.scheme.lowercaseString isEqualToString:@"https"] || !parts.host.length || parts.user || parts.password || parts.query || parts.fragment) return @"";
    // Persist only public Cinemeta artwork origins, never a provider address.
    NSString *host = parts.host.lowercaseString;
    if (![@[@"images.metahub.space", @"image.tmdb.org", @"poster-cdn.stremio.com", @"images.stremio.com", @"cinemeta-catalogs.strem.io"] containsObject:host]) return @"";
    return parts.URL.absoluteString ?: @"";
}
static BOOL MSLibraryFingerprint(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 71 || ![value hasPrefix:@"sha256:"]) return NO;
    return [[value substringFromIndex:7] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location == NSNotFound;
}
static NSDictionary *MSLibrarySelections(id raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *kind in @[@"audio", @"subtitle"]) {
        NSDictionary *selection = [raw[kind] isKindOfClass:NSDictionary.class] ? raw[kind] : nil;
        if (!selection) continue;
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        if ([kind isEqualToString:@"subtitle"]) {
            if (![@[@"off", @"embedded", @"external"] containsObject:selection[@"kind"]]) continue;
            clean[@"kind"] = selection[@"kind"];
        }
        for (NSString *key in @[@"language", @"displayName"]) {
            NSString *text = MSLibraryText(selection[key], [key isEqualToString:@"language"] ? 30 : 160);
            if (text.length) clean[key] = text;
        }
        if ([kind isEqualToString:@"subtitle"] && [clean[@"kind"] isEqualToString:@"external"]) {
            for (NSString *key in @[@"providerID", @"subtitleID"]) {
                NSString *text = MSLibraryText(selection[key], [key isEqualToString:@"providerID"] ? 256 : 512);
                if (text.length) clean[key] = text;
            }
        }
        if (clean.count) result[kind] = clean;
    }
    id delay = raw[@"subtitleDelay"];
    if ([delay isKindOfClass:NSNumber.class] && isfinite([delay doubleValue])) result[@"subtitleDelay"] = @(fmax(-60, fmin(60, [delay doubleValue])));
    return result;
}
static NSMutableDictionary *MSLibraryRecord(id raw, NSString *identifier) {
    if (![raw isKindOfClass:NSDictionary.class] || !MSLibraryID(identifier).length) return nil;
    NSString *parent = MSLibraryID(raw[@"metadataID"]);
    NSArray *components = [identifier componentsSeparatedByString:@":"];
    BOOL inferredEpisode = components.count >= 3 && [components.firstObject hasPrefix:@"tt"];
    if (!parent.length) parent = inferredEpisode ? components.firstObject : identifier;
    NSString *type = [@[@"movie", @"series"] containsObject:raw[@"type"]] ? raw[@"type"] : (inferredEpisode ? @"series" : @"movie");
    NSString *title = MSLibraryText(raw[@"title"], 400);
    NSMutableDictionary *record = [@{@"videoID":identifier, @"metadataID":parent, @"type":type,
        @"title":title.length ? title : @"Saved playback",
        @"position":@(MSLibraryNumber(raw[@"position"], MSMaximumDuration)), @"duration":@(MSLibraryNumber(raw[@"duration"], MSMaximumDuration)),
        @"lastPlayedAt":@(MSLibraryNumber(raw[@"lastPlayedAt"], 1e12)), @"updatedAt":@(MSLibraryNumber(raw[@"updatedAt"], 1e12)),
        @"favorite":@([raw[@"favorite"] isKindOfClass:NSNumber.class] && [raw[@"favorite"] boolValue])} mutableCopy];
    id origin = raw[@"originConnectionIdentifier"];
    if ([origin isKindOfClass:NSString.class] && [origin length] == 36 && [[NSUUID alloc] initWithUUIDString:origin]) record[@"originConnectionIdentifier"] = [origin uppercaseString];
    for (NSString *key in @[@"releaseInfo", @"episodeTitle"]) { NSString *text = MSLibraryText(raw[key], [key isEqualToString:@"releaseInfo"] ? 80 : 300); if (text.length) record[key] = text; }
    for (NSString *key in @[@"season", @"episode"]) if ([raw[key] isKindOfClass:NSNumber.class]) record[key] = @((NSInteger)MSLibraryNumber(raw[key], 100000));
    NSString *poster = MSLibraryPoster(raw[@"posterURL"]); if (poster.length) record[@"posterURL"] = poster;
    if (MSLibraryFingerprint(raw[@"sourceFingerprint"])) record[@"sourceFingerprint"] = raw[@"sourceFingerprint"];
    NSDictionary *selections = MSLibrarySelections(raw[@"selections"]); if (selections.count) record[@"selections"] = selections;
    return record;
}

@interface MSLibraryStore ()
@property(nonatomic, strong) NSUserDefaults *defaults;
@end
@implementation MSLibraryStore
+ (instancetype)sharedStore {
    static MSLibraryStore *store; static dispatch_once_t token;
    dispatch_once(&token, ^{ store = [[MSLibraryStore alloc] initWithDefaults:NSUserDefaults.standardUserDefaults]; }); return store;
}
- (instancetype)init { return [self initWithDefaults:NSUserDefaults.standardUserDefaults]; }
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) { _defaults = defaults; [self migrateIfNeeded]; } return self;
}
- (NSArray<NSString *> *)orderedKeys:(NSDictionary *)records {
    return [[records allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDictionary *left = records[a], *right = records[b];
        BOOL lf = [left[@"favorite"] boolValue], rf = [right[@"favorite"] boolValue];
        if (lf != rf) return lf ? NSOrderedAscending : NSOrderedDescending;
        double lt = fmax([left[@"lastPlayedAt"] doubleValue], [left[@"updatedAt"] doubleValue]);
        double rt = fmax([right[@"lastPlayedAt"] doubleValue], [right[@"updatedAt"] doubleValue]);
        return lt > rt ? NSOrderedAscending : lt < rt ? NSOrderedDescending : [a compare:b];
    }];
}
- (void)writeRecords:(NSDictionary *)records notify:(BOOL)notify {
    NSMutableDictionary *bounded = [NSMutableDictionary dictionary];
    for (NSString *key in [self orderedKeys:records]) { if (bounded.count >= MSRecordLimit) break; bounded[key] = records[key]; }
    NSArray *oldestFirst = [[[self orderedKeys:bounded] reverseObjectEnumerator] allObjects];
    NSMutableDictionary *document = [@{@"version":@2, @"records":bounded} mutableCopy]; NSUInteger index = 0;
    while (bounded.count) {
        NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:document format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        if (bytes && bytes.length <= MSRecordBytesLimit) break;
        [bounded removeObjectForKey:oldestFirst[index++]];
    }
    [self.defaults setObject:document forKey:MSRecordsKey];
    if (notify) [NSNotificationCenter.defaultCenter postNotificationName:MSLibraryDidChangeNotification object:self];
}
- (void)migrateIfNeeded {
    if ([self.defaults objectForKey:MSRecordsKey]) return;
    NSMutableDictionary *records = [NSMutableDictionary dictionary];
    NSDictionary *progress = [self.defaults dictionaryForKey:MSProgressKey] ?: @{};
    NSUInteger inspected = 0;
    for (id key in progress) {
        if (++inspected > MSRecordLimit * 4) break;
        if (!MSLibraryID(key).length) continue;
        double position = MSLibraryNumber(progress[key], MSMaximumDuration); if (position < 5) continue;
        records[key] = MSLibraryRecord(@{@"position":@(position), @"lastPlayedAt":@1}, key);
    }
    inspected = 0;
    for (id key in [self.defaults arrayForKey:MSFavoritesKey] ?: @[]) {
        if (++inspected > MSRecordLimit * 4) break;
        if (!MSLibraryID(key).length) continue;
        NSMutableDictionary *record = records[key] ?: MSLibraryRecord(@{}, key); record[@"favorite"] = @YES; records[key] = record;
    }
    [self writeRecords:records notify:NO];
    [self.defaults removeObjectForKey:MSFavoritesKey]; [self.defaults removeObjectForKey:MSProgressKey];
}
- (NSMutableDictionary *)records {
    id document = [self.defaults objectForKey:MSRecordsKey];
    // Future schemas or damaged outer documents remain untouched by writes.
    if (![document isKindOfClass:NSDictionary.class] || ![document[@"version"] isEqual:@2] || ![document[@"records"] isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *records = [NSMutableDictionary dictionary]; NSUInteger inspected = 0;
    for (id key in document[@"records"]) {
        if (++inspected > MSRecordLimit * 4) break;
        NSMutableDictionary *record = MSLibraryRecord(document[@"records"][key], key); if (record) records[key] = record;
    }
    return records;
}
- (NSDictionary *)recordForIdentifier:(NSString *)identifier { return MSLibraryID(identifier).length ? [[self records][identifier] copy] : nil; }
- (void)registerMetadata:(NSDictionary *)metadata forVideoIdentifier:(NSString *)identifier {
    if (!MSLibraryID(identifier).length || ![metadata isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *records = [self records]; if (!records) return;
    NSMutableDictionary *record = [records[identifier] mutableCopy] ?: MSLibraryRecord(@{}, identifier);
    for (NSString *key in @[@"metadataID", @"type", @"title", @"posterURL", @"releaseInfo", @"episodeTitle", @"season", @"episode", @"originConnectionIdentifier"]) if (metadata[key]) record[key] = metadata[key];
    NSMutableDictionary *clean = MSLibraryRecord(record, identifier);
    if ([records[identifier] isEqual:clean]) return;
    clean[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970); records[identifier] = clean; [self writeRecords:records notify:YES];
}
- (BOOL)isFavorite:(NSString *)identifier { return [[self recordForIdentifier:identifier][@"favorite"] boolValue]; }
- (void)toggleFavorite:(NSString *)identifier {
    if (!MSLibraryID(identifier).length) return;
    NSMutableDictionary *records = [self records]; if (!records) return;
    NSMutableDictionary *record = [records[identifier] mutableCopy] ?: MSLibraryRecord(@{}, identifier);
    record[@"favorite"] = @(![record[@"favorite"] boolValue]); record[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
    records[identifier] = record; [self writeRecords:records notify:YES];
}
- (NSTimeInterval)resumeFor:(NSString *)identifier duration:(NSTimeInterval)duration {
    return MSResumePosition([[self recordForIdentifier:identifier][@"position"] doubleValue], duration);
}
- (void)savePosition:(NSTimeInterval)seconds duration:(NSTimeInterval)duration for:(NSString *)identifier {
    if (!MSLibraryID(identifier).length || !isfinite(seconds) || !isfinite(duration) || duration <= 0 || duration > MSMaximumDuration || seconds < 0) return;
    BOOL completed = seconds >= duration - 10 && duration > 10;
    if (!MSShouldPersistProgress(seconds, duration) && !completed) return;
    NSMutableDictionary *records = [self records]; if (!records) return;
    NSMutableDictionary *record = [records[identifier] mutableCopy] ?: MSLibraryRecord(@{}, identifier);
    double position = completed ? 0 : seconds;
    if (fabs([record[@"position"] doubleValue] - position) < 1 && fabs([record[@"duration"] doubleValue] - duration) < 1 && [record[@"lastPlayedAt"] doubleValue] > 1) return;
    record[@"position"] = @(position); record[@"duration"] = @(duration); record[@"lastPlayedAt"] = @(NSDate.date.timeIntervalSince1970);
    record[@"updatedAt"] = record[@"lastPlayedAt"]; records[identifier] = record; [self writeRecords:records notify:YES];
}
- (void)clearPositionFor:(NSString *)identifier {
    if (!MSLibraryID(identifier).length) return;
    NSMutableDictionary *records = [self records]; NSMutableDictionary *record = [records[identifier] mutableCopy];
    if (!record || [record[@"position"] doubleValue] == 0) return;
    record[@"position"] = @0; records[identifier] = record; [self writeRecords:records notify:YES];
}
- (NSArray<NSDictionary *> *)filteredRecords:(NSUInteger)mode {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *record in [self records].allValues) {
        double time = [record[@"position"] doubleValue], duration = [record[@"duration"] doubleValue];
        BOOL include = mode == 2 ? [record[@"favorite"] boolValue] : mode == 1 ? [record[@"lastPlayedAt"] doubleValue] > 0 : (time >= 5 && (duration == 0 || MSResumePosition(time, duration) > 0));
        if (include) [result addObject:[record copy]];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *key = mode == 2 ? @"updatedAt" : @"lastPlayedAt";
        double at = [a[key] doubleValue], bt = [b[key] doubleValue];
        return at > bt ? NSOrderedAscending : at < bt ? NSOrderedDescending : [a[@"videoID"] compare:b[@"videoID"]];
    }]; return result;
}
- (NSArray<NSDictionary *> *)continueWatchingRecords { return [self filteredRecords:0]; }
- (NSArray<NSDictionary *> *)recentRecords { return [self filteredRecords:1]; }
- (NSArray<NSDictionary *> *)favoriteRecords { return [self filteredRecords:2]; }
- (NSDictionary *)playbackSelectionsForIdentifier:(NSString *)identifier { return [self recordForIdentifier:identifier][@"selections"] ?: @{}; }
- (void)savePlaybackSelections:(NSDictionary *)selections forIdentifier:(NSString *)identifier {
    if (!MSLibraryID(identifier).length) return;
    NSMutableDictionary *records = [self records]; if (!records) return;
    NSMutableDictionary *record = [records[identifier] mutableCopy] ?: MSLibraryRecord(@{}, identifier);
    NSDictionary *clean = MSLibrarySelections(selections); if ([record[@"selections"] isEqual:clean]) return;
    record[@"selections"] = clean; records[identifier] = record; [self writeRecords:records notify:NO];
}
- (void)saveSourceFingerprint:(NSString *)fingerprint forIdentifier:(NSString *)identifier {
    if (!MSLibraryID(identifier).length || !MSLibraryFingerprint(fingerprint)) return;
    NSMutableDictionary *records = [self records]; if (!records) return;
    NSMutableDictionary *record = [records[identifier] mutableCopy] ?: MSLibraryRecord(@{}, identifier);
    if ([record[@"sourceFingerprint"] isEqual:fingerprint]) return;
    record[@"sourceFingerprint"] = fingerprint; records[identifier] = record; [self writeRecords:records notify:NO];
}
+ (NSString *)sourceFingerprintForProvider:(NSString *)provider filename:(NSString *)filename name:(NSString *)name detail:(NSString *)detail {
    NSMutableArray *components = [NSMutableArray array];
    // A filename survives expiring links and changing seed/cache descriptions.
    // Without one, retain the provider's human-readable name/detail as fallback.
    BOOL hasFilename = [filename isKindOfClass:NSString.class] && [filename stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length;
    for (id value in @[provider ?: @"", hasFilename ? filename : @"", hasFilename ? @"" : (name ?: @""), hasFilename ? @"" : (detail ?: @"")]) {
        NSString *text = [value isKindOfClass:NSString.class] ? value : @"";
        if (text.length > 2048) text = [text substringToIndex:2048];
        NSRegularExpression *URLs = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s]+" options:NSRegularExpressionCaseInsensitive error:NULL];
        text = [URLs stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
        NSArray *words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSMutableArray *nonempty = [NSMutableArray array]; for (NSString *word in words) if (word.length) [nonempty addObject:word];
        [components addObject:[[nonempty componentsJoinedByString:@" "] lowercaseString]];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:components options:0 error:NULL];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithString:@"sha256:"]; for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
- (void)removeHistoryForIdentifier:(NSString *)identifier {
    if (!MSLibraryID(identifier).length) return;
    NSMutableDictionary *records = [self records]; NSMutableDictionary *record = [records[identifier] mutableCopy]; if (!record) return;
    if ([record[@"favorite"] boolValue]) { record[@"position"] = @0; record[@"lastPlayedAt"] = @0; [record removeObjectForKey:@"sourceFingerprint"]; [record removeObjectForKey:@"selections"]; records[identifier] = record; }
    else [records removeObjectForKey:identifier];
    [self writeRecords:records notify:YES];
}
- (void)clearHistory {
    NSMutableDictionary *records = [self records]; if (!records) return;
    for (NSString *key in [records.allKeys copy]) {
        NSMutableDictionary *record = [records[key] mutableCopy];
        if ([record[@"favorite"] boolValue]) { record[@"position"] = @0; record[@"lastPlayedAt"] = @0; [record removeObjectForKey:@"sourceFingerprint"]; [record removeObjectForKey:@"selections"]; records[key] = record; }
        else [records removeObjectForKey:key];
    }
    [self writeRecords:records notify:YES];
}
@end
