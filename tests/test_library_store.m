#import <Foundation/Foundation.h>
#import "MSLibraryStore.h"
#import <math.h>

/* All test values live in this dictionary. No suite, persistent domain, or
 * standardUserDefaults is used by the test. Copies model defaults snapshots. */
@interface MSMemoryDefaults : NSUserDefaults
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *memory;
@end

@implementation MSMemoryDefaults
- (instancetype)init {
    self = [super init];
    if (self) _memory = [NSMutableDictionary dictionary];
    return self;
}
- (id)objectForKey:(NSString *)key { return self.memory[key]; }
- (NSArray *)arrayForKey:(NSString *)key {
    id value = [self objectForKey:key];
    return [value isKindOfClass:NSArray.class] ? value : nil;
}
- (NSDictionary *)dictionaryForKey:(NSString *)key {
    id value = [self objectForKey:key];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
- (void)setObject:(id)value forKey:(NSString *)key {
    if (!value) { [self removeObjectForKey:key]; return; }
    NSError *error = nil;
    NSData *serialized = [NSPropertyListSerialization dataWithPropertyList:value
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!serialized) {
        [NSException raise:NSInvalidArgumentException format:@"Not property-list data: %@", error];
    }
    self.memory[key] = [NSPropertyListSerialization propertyListWithData:serialized
        options:NSPropertyListImmutable format:NULL error:NULL];
}
- (void)removeObjectForKey:(NSString *)key { [self.memory removeObjectForKey:key]; }
- (NSDictionary *)dictionaryRepresentation { return [self.memory copy]; }
- (BOOL)synchronize { return YES; }
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name {
    (void)domain;
    (void)name;
    [NSException raise:NSInternalInconsistencyException format:@"Persistent defaults are forbidden in this test"];
}
@end

static unsigned checks = 0;
static unsigned failures = 0;

static void check(BOOL condition, const char *name) {
    ++checks;
    if (!condition) { fprintf(stderr, "FAIL library store: %s\n", name); ++failures; }
}

static BOOL samePosition(NSTimeInterval actual, NSTimeInterval expected) {
    return isfinite(actual) && fabs(actual - expected) < 0.000001;
}

int main(void) {
    @autoreleasepool {
        MSMemoryDefaults *defaults = [MSMemoryDefaults new];
        MSLibraryStore *first = [[MSLibraryStore alloc] initWithDefaults:defaults];
        NSString *a = @"demo:test-a";
        NSString *b = @"demo:test-b";
        check(![first isFavorite:a], "new item is not a favorite");
        check(samePosition([first resumeFor:a duration:100], 0), "new item has no progress");

        [first toggleFavorite:a];
        check([first isFavorite:a], "toggle adds favorite");
        [first toggleFavorite:b];
        check([first isFavorite:a] && [first isFavorite:b], "favorites are independent");
        [first toggleFavorite:a];
        check(![first isFavorite:a] && [first isFavorite:b], "toggle removes only its favorite");
        [first toggleFavorite:a];
        for (unsigned i = 0; i < 20; ++i) [first toggleFavorite:a];
        check([first isFavorite:a], "repeated even toggles preserve selected state");
        NSUInteger occurrences = 0;
        for (NSDictionary *record in first.favoriteRecords) if ([record[@"videoID"] isEqual:a]) ++occurrences;
        check(occurrences == 1, "favorite persists exactly once after repeated toggles");

        MSLibraryStore *second = [[MSLibraryStore alloc] initWithDefaults:defaults];
        check([second isFavorite:a] && [second isFavorite:b], "new store observes shared saved favorites");
        [second toggleFavorite:a];
        check(![first isFavorite:a] && [first isFavorite:b], "first store observes second store's favorite change");

        [first savePosition:20 duration:100 for:a];
        check(samePosition([first resumeFor:a duration:100], 20), "valid progress resumes");
        check(samePosition([second resumeFor:a duration:100], 20), "new store observes shared progress");
        [second savePosition:40 duration:100 for:b];
        check(samePosition([first resumeFor:b duration:100], 40), "progress changes are visible across stores");
        check(samePosition([first resumeFor:a duration:100], 20), "saving another item preserves prior item");

        const struct { double position; double duration; const char *name; } invalid[] = {
            {NAN, 100, "NaN position preserves prior valid progress"},
            {INFINITY, 100, "infinite position preserves prior valid progress"},
            {-INFINITY, 100, "negative infinite position preserves prior valid progress"},
            {-5, 100, "negative position preserves prior valid progress"},
            {30, NAN, "NaN duration preserves prior valid progress"},
            {30, INFINITY, "infinite duration preserves prior valid progress"},
            {30, -INFINITY, "negative infinite duration preserves prior valid progress"},
            {30, 0, "zero duration preserves prior valid progress"},
            {30, -100, "negative duration preserves prior valid progress"},
            {0, 100, "startup zero does not overwrite prior valid progress"},
            {4.999, 100, "position below save threshold preserves prior valid progress"}
        };
        for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
            [first savePosition:invalid[i].position duration:invalid[i].duration for:a];
            check(samePosition([second resumeFor:a duration:100], 20), invalid[i].name);
        }
        check(samePosition([first resumeFor:a duration:NAN], 0), "unknown duration does not yield resume position");
        check(samePosition([first resumeFor:a duration:25], 0), "changed shorter media does not resume near end");
        check(samePosition([first resumeFor:a duration:100], 20), "read-time rejection does not delete saved position");

        [first savePosition:90 duration:100 for:a];
        check(samePosition([second resumeFor:a duration:100], 0), "final ten-second boundary clears progress");
        check(samePosition([second resumeFor:b duration:100], 40), "completion does not clear another item");
        [first savePosition:5 duration:100 for:a];
        check(samePosition([second resumeFor:a duration:100], 5), "minimum allowed save position persists");
        [first savePosition:100 duration:100 for:a];
        check(samePosition([second resumeFor:a duration:100], 0), "at duration clears prior progress");
        [first savePosition:20 duration:100 for:a];
        [first savePosition:101 duration:100 for:a];
        check(samePosition([second resumeFor:a duration:100], 0), "past duration clears stale progress");
        [first clearPositionFor:b];
        [first clearPositionFor:b];
        check(samePosition([second resumeFor:b duration:100], 0), "explicit clear is shared and idempotent");
        check([first isFavorite:b], "clearing progress preserves favorite state");

        MSMemoryDefaults *legacyDefaults = [MSMemoryDefaults new];
        [legacyDefaults setObject:@{@"tt100001":@4339, @"tt200002:2:3":@125, @"bad":@(-1)} forKey:@"library.progress.v1"];
        [legacyDefaults setObject:@[@"tt100001", @"tt200002", @"tt100001"] forKey:@"library.favorites.v1"];
        MSLibraryStore *migrated = [[MSLibraryStore alloc] initWithDefaults:legacyDefaults];
        check(samePosition([migrated resumeFor:@"tt100001" duration:6000], 4339), "migration preserves long in-progress film");
        check(migrated.continueWatchingRecords.count == 2 && migrated.recentRecords.count == 2, "legacy progress appears in Continue and History before metadata lookup");
        check(migrated.favoriteRecords.count == 2, "migration deduplicates favorites");
        check(![legacyDefaults objectForKey:@"library.progress.v1"] && ![legacyDefaults objectForKey:@"library.favorites.v1"], "migration removes superseded v1 keys");
        NSDictionary *episode = [migrated recordForIdentifier:@"tt200002:2:3"];
        check([episode[@"metadataID"] isEqual:@"tt200002"] && [episode[@"type"] isEqual:@"series"], "legacy episode retains exact ID and derives series parent");
        check([episode[@"title"] isEqual:@"Saved playback"], "legacy record has a visible neutral placeholder");
        NSDictionary *filmMetadata = @{@"metadataID":@"tt100001", @"type":@"movie", @"title":@"A Test Film", @"posterURL":@"https://images.metahub.space/poster/medium/tt100001/img", @"releaseInfo":@"2024", @"streamURL":@"https://private.invalid/token/stream.mp4", @"credentials":@"secret"};
        [migrated registerMetadata:filmMetadata forVideoIdentifier:@"tt100001"];
        NSString *origin = @"4FBAA1B5-2529-4B9D-9A83-8657B43D44A1";
        [migrated registerMetadata:@{@"originConnectionIdentifier":origin} forVideoIdentifier:@"tt100001"];
        check([[[migrated recordForIdentifier:@"tt100001"] objectForKey:@"originConnectionIdentifier"] isEqual:origin], "local catalog origin UUID persists without a configured URL");
        [migrated registerMetadata:@{@"originConnectionIdentifier":@"https://configured.invalid/private"} forVideoIdentifier:@"tt100001"];
        check(![migrated recordForIdentifier:@"tt100001"][@"originConnectionIdentifier"], "configured URLs cannot enter the origin UUID field");
        [migrated registerMetadata:@{@"originConnectionIdentifier":origin.lowercaseString} forVideoIdentifier:@"tt100001"];
        check([[[migrated recordForIdentifier:@"tt100001"] objectForKey:@"originConnectionIdentifier"] isEqual:origin], "valid local origin UUID is normalized consistently");
        check(samePosition([migrated resumeFor:@"tt100001" duration:6000], 4339), "metadata enrichment never resets migrated progress");
        check([[migrated recordForIdentifier:@"tt100001"][@"title"] isEqual:@"A Test Film"], "metadata enrichment replaces placeholder");
        check([[migrated recordForIdentifier:@"tt100001"][@"posterURL"] hasPrefix:@"https://images.metahub.space/"], "public catalog poster survives reload");
        [migrated registerMetadata:@{@"metadataID":@"tt200002", @"type":@"series", @"title":@"Series Title", @"episodeTitle":@"Episode Three", @"season":@2, @"episode":@3} forVideoIdentifier:@"tt200002:2:3"];
        episode = [migrated recordForIdentifier:@"tt200002:2:3"];
        check([episode[@"videoID"] isEqual:@"tt200002:2:3"] && [episode[@"episode"] integerValue] == 3 && [episode[@"season"] integerValue] == 2, "exact episode metadata remains navigable");
        MSLibraryStore *reloaded = [[MSLibraryStore alloc] initWithDefaults:legacyDefaults];
        check(samePosition([reloaded resumeFor:@"tt100001" duration:6000], 4339), "second launch does not rerun or lose migrated progress");

        NSString *fingerprint = [MSLibraryStore sourceFingerprintForProvider:@"org.test.source" filename:@"Film.2024.1080p.mkv" name:@"Source 1080p" detail:@"20 seeders"];
        NSString *rotated = [MSLibraryStore sourceFingerprintForProvider:@"ORG.TEST.SOURCE" filename:@"  film.2024.1080p.mkv " name:@"Source cached" detail:@"500 seeders https://private.invalid/rotated-token"];
        check([fingerprint isEqual:rotated], "filename fingerprint survives changing descriptions and playback addresses");
        check(fingerprint.length == 71 && [fingerprint hasPrefix:@"sha256:"], "source identity is an opaque SHA256 digest");
        check(![fingerprint isEqual:[MSLibraryStore sourceFingerprintForProvider:@"org.other" filename:@"Film.2024.1080p.mkv" name:nil detail:nil]], "source identity distinguishes providers");
        check(![fingerprint isEqual:[MSLibraryStore sourceFingerprintForProvider:@"org.test.source" filename:@"Film.2024.720p.mkv" name:nil detail:nil]], "source identity distinguishes files");
        NSString *fallback = [MSLibraryStore sourceFingerprintForProvider:@"org.test" filename:nil name:@"  Source   HD " detail:@"1080p https://private.invalid/token-a"];
        check([fallback isEqual:[MSLibraryStore sourceFingerprintForProvider:@"org.test" filename:@" " name:@"source hd" detail:@"1080p https://private.invalid/token-b"]], "fallback normalizes labels and excludes expiring addresses");
        [migrated saveSourceFingerprint:fingerprint forIdentifier:@"tt100001"];
        [migrated saveSourceFingerprint:@"https://private.invalid/not-a-fingerprint" forIdentifier:@"tt100001"];
        check([[reloaded recordForIdentifier:@"tt100001"][@"sourceFingerprint"] isEqual:fingerprint], "invalid source identity cannot replace valid digest");

        NSDictionary *selections = @{@"audio":@{@"language":@"eng", @"displayName":@"English", @"URL":@"https://private.invalid/audio"},
            @"subtitle":@{@"kind":@"external", @"language":@"spa", @"displayName":@"Spanish", @"providerID":@"org.public.subtitles", @"subtitleID":@"track-42", @"URL":@"https://private.invalid/subtitle"},
            @"subtitleDelay":@1.5, @"streamURL":@"https://private.invalid/play", @"addonURL":@"https://private.invalid/config/manifest.json"};
        [migrated savePlaybackSelections:selections forIdentifier:@"tt100001"];
        NSDictionary *restored = [reloaded playbackSelectionsForIdentifier:@"tt100001"];
        check([restored[@"audio"][@"language"] isEqual:@"eng"] && [restored[@"subtitle"][@"subtitleID"] isEqual:@"track-42"] && [restored[@"subtitleDelay"] doubleValue] == 1.5, "language, exact subtitle identity and sync delay survive store recreation");
        check(restored.count == 3 && [restored[@"audio"] count] == 2 && [restored[@"subtitle"] count] == 5, "playback preferences drop unknown address fields");
        check([reloaded playbackSelectionsForIdentifier:@"tt200002:2:3"].count == 0, "selections are isolated per exact video ID");
        NSData *savedBytes = [NSJSONSerialization dataWithJSONObject:legacyDefaults.dictionaryRepresentation options:0 error:NULL];
        NSString *savedText = [[NSString alloc] initWithData:savedBytes encoding:NSUTF8StringEncoding];
        check([savedText rangeOfString:@"private.invalid"].location == NSNotFound && [savedText rangeOfString:@"secret"].location == NSNotFound && [savedText rangeOfString:@"Film.2024.1080p"].location == NSNotFound, "stored state contains neither playback/config addresses, credentials nor raw source descriptions");
        [migrated savePlaybackSelections:@{@"audio":@{@"language":@"https://secret.invalid"}, @"subtitle":@{@"kind":@"embedded", @"language":@"eng", @"providerID":@"ignored", @"subtitleID":@"ignored"}, @"subtitleDelay":@1000} forIdentifier:@"tt200002:2:3"];
        restored = [migrated playbackSelectionsForIdentifier:@"tt200002:2:3"];
        check(!restored[@"audio"] && [restored[@"subtitle"] count] == 2 && [restored[@"subtitleDelay"] integerValue] == 60, "invalid labels are rejected and subtitle offsets are bounded");
        [migrated savePlaybackSelections:@{@"subtitle":@{@"kind":@"off"}, @"subtitleDelay":@(NAN)} forIdentifier:@"tt200002:2:3"];
        restored = [migrated playbackSelectionsForIdentifier:@"tt200002:2:3"];
        check([restored[@"subtitle"][@"kind"] isEqual:@"off"] && !restored[@"subtitleDelay"], "explicit subtitles Off persists and nonfinite offset is discarded");

        [migrated savePosition:5995 duration:6000 for:@"tt100001"];
        check(migrated.continueWatchingRecords.count == 1 && migrated.recentRecords.count == 2, "completion leaves History but exits Continue Watching");
        [migrated savePosition:4339 duration:6000 for:@"tt100001"];
        [migrated clearHistory];
        check(migrated.continueWatchingRecords.count == 0 && migrated.recentRecords.count == 0, "Clear History removes all recents and progress");
        check(migrated.favoriteRecords.count == 2 && [[migrated recordForIdentifier:@"tt100001"][@"title"] isEqual:@"A Test Film"], "Clear History retains saved-title metadata");
        check(![migrated recordForIdentifier:@"tt200002:2:3"], "Clear History removes unsaved episode records");
        check(![migrated recordForIdentifier:@"tt100001"][@"sourceFingerprint"] && [migrated playbackSelectionsForIdentifier:@"tt100001"].count == 0, "Clear History removes source and track selections from saved titles");
        [migrated clearHistory];
        check(migrated.favoriteRecords.count == 2, "Clear History is idempotent");
        [migrated savePosition:200 duration:6000 for:@"tt100001"];
        [migrated saveSourceFingerprint:fingerprint forIdentifier:@"tt100001"];
        [migrated removeHistoryForIdentifier:@"tt100001"];
        check([migrated isFavorite:@"tt100001"] && [migrated recentRecords].count == 0 && ![migrated recordForIdentifier:@"tt100001"][@"sourceFingerprint"], "per-title history removal retains favorite and clears playback choices");

        MSMemoryDefaults *limits = [MSMemoryDefaults new];
        NSMutableDictionary *many = [NSMutableDictionary dictionary];
        NSString *longTitle = [@"t" stringByPaddingToLength:400 withString:@"t" startingAtIndex:0];
        for (NSUInteger index = 0; index < 350; ++index) {
            NSString *key = [NSString stringWithFormat:@"tt%06lu", (unsigned long)index];
            many[key] = @{@"title":longTitle, @"position":@20, @"duration":@100, @"lastPlayedAt":@(index + 1), @"favorite":@(index == 0)};
        }
        [limits setObject:@{@"version":@2, @"records":many} forKey:@"library.records.v2"];
        MSLibraryStore *bounded = [[MSLibraryStore alloc] initWithDefaults:limits];
        [bounded registerMetadata:@{@"title":@"Fresh title"} forVideoIdentifier:@"tt999999"];
        NSDictionary *limitedDocument = [limits dictionaryForKey:@"library.records.v2"];
        check([limitedDocument[@"records"] count] <= 300, "writes cap the Library at 300 records");
        NSData *boundedBytes = [NSPropertyListSerialization dataWithPropertyList:limitedDocument format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        check(boundedBytes.length <= 1024 * 1024, "serialized Library remains within one MiB");
        check([bounded isFavorite:@"tt000000"] && [bounded recordForIdentifier:@"tt000349"] && ![bounded recordForIdentifier:@"tt000001"], "pruning keeps favorites and newest history before oldest unsaved records");
        [bounded registerMetadata:@{@"posterURL":@"https://images.metahub.space/poster.jpg?token=secret"} forVideoIdentifier:@"tt999999"];
        check(![bounded recordForIdentifier:@"tt999999"][@"posterURL"], "poster addresses with query credentials are not persisted");
        [bounded registerMetadata:@{@"posterURL":@"https://configured-provider.invalid/secret/poster.jpg"} forVideoIdentifier:@"tt999999"];
        check(![bounded recordForIdentifier:@"tt999999"][@"posterURL"], "provider addresses cannot be stored as artwork");
        [bounded registerMetadata:@{@"title":[@"a" stringByPaddingToLength:401 withString:@"a" startingAtIndex:0], @"season":@(-1)} forVideoIdentifier:@"tt999999"];
        check([[bounded recordForIdentifier:@"tt999999"][@"title"] isEqual:@"Saved playback"], "oversized metadata is discarded");
        [bounded savePosition:20 duration:604801 for:@"tt999999"];
        check([bounded recordForIdentifier:@"tt999999"][@"lastPlayedAt"] && [[bounded recordForIdentifier:@"tt999999"][@"lastPlayedAt"] doubleValue] == 0, "unbounded media duration is not recorded");
        [bounded toggleFavorite:@"https://private.invalid/video"];
        check(![bounded recordForIdentifier:@"https://private.invalid/video"], "addresses cannot be used as persisted video identifiers");

        MSMemoryDefaults *future = [MSMemoryDefaults new];
        NSDictionary *futureDocument = @{@"version":@3, @"records":@{@"tt123":@{@"future":@YES}}};
        [future setObject:futureDocument forKey:@"library.records.v2"];
        MSLibraryStore *futureStore = [[MSLibraryStore alloc] initWithDefaults:future];
        [futureStore registerMetadata:filmMetadata forVideoIdentifier:@"tt123"];
        [futureStore savePosition:20 duration:100 for:@"tt123"];
        [futureStore toggleFavorite:@"tt123"]; [futureStore clearHistory];
        [futureStore savePlaybackSelections:selections forIdentifier:@"tt123"];
        check([[future objectForKey:@"library.records.v2"] isEqual:futureDocument], "future schema is preserved without destructive downgrade");
        [future setObject:@{@"version":@2, @"records":@[@"damaged"]} forKey:@"library.records.v2"];
        [futureStore clearHistory];
        check([[future objectForKey:@"library.records.v2"][@"records"] isKindOfClass:NSArray.class], "corrupt outer schema is left untouched for recovery");
        [future setObject:@{@"version":@2, @"records":@{@"tt123":@"invalid", @"tt456":@{@"position":@25, @"duration":@100, @"lastPlayedAt":@2}}} forKey:@"library.records.v2"];
        check(futureStore.continueWatchingRecords.count == 1 && [futureStore recordForIdentifier:@"tt456"], "malformed record is ignored without losing valid neighbor");

        if (failures) return 1;
        printf("PASS %u Foundation library-store checks against production code (in-memory defaults only)\n", checks);
    }
    return 0;
}
