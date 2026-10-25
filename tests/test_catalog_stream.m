#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "MSCatalogClient.h"
#import "MSHTTPClient.h"
#import "MSStream.h"
#import "MSAddons.h"

static NSURL *TestAddonRoot;
NSURL *MSAddonTestStorageDirectory(void) { return TestAddonRoot; }
BOOL MSAddonTestFailCommit(void) { return NO; }

// Host-only production parser/policy tests. Network transport is replaced by a
// synchronous fixture response while testing catalog paths; no requests occur.
static unsigned checks=0, failures=0;
static NSURL *capturedURL;
static NSDictionary *stubDocument;
static NSError *stubError;
static NSMutableArray<NSURL *> *requestedURLs;
static NSDictionary<NSString *,NSDictionary *> *hostDocuments;
static BOOL deferFixture;
static void (^deferredFixtureCompletion)(NSDictionary *,NSError *);
static void check(BOOL condition,const char *name) {
    checks++; if (!condition) { failures++; fprintf(stderr,"FAIL catalog/stream: %s\n",name); }
}
static NSDictionary *fixture(NSString *name) {
    NSString *directory=[[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fixtures"];
    NSData *bytes=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
    id value=bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL] : nil;
    check([value isKindOfClass:NSDictionary.class],"fixture is a JSON object");
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static NSString *repeat(NSString *text,NSUInteger count) {
    return [@"" stringByPaddingToLength:count withString:text startingAtIndex:0];
}
@interface MSFixtureRequest : NSObject <MSCancellable>
@end
@implementation MSFixtureRequest
- (void)cancel {}
@end
@interface MSHTTPClient (FixtureTransport)
- (id<MSCancellable>)test_fetchJSONURL:(NSURL *)URL completion:(void (^)(NSDictionary *,NSError *))completion;
@end
@implementation MSHTTPClient (FixtureTransport)
- (id<MSCancellable>)test_fetchJSONURL:(NSURL *)URL completion:(void (^)(NSDictionary *,NSError *))completion {
    capturedURL=URL; [requestedURLs addObject:URL];
    if (deferFixture) deferredFixtureCompletion = [completion copy];
    else completion(hostDocuments ? hostDocuments[URL.host] : stubDocument,stubError);
    return [MSFixtureRequest new];
}
@end
static void swapTransport(void) {
    method_exchangeImplementations(class_getInstanceMethod(MSHTTPClient.class,@selector(fetchJSONURL:completion:)),
        class_getInstanceMethod(MSHTTPClient.class,@selector(test_fetchJSONURL:completion:)));
}
static MSStream *stream(NSDictionary *raw) { return [MSStream streamWithDictionary:raw addonName:@"Fixture add-on"]; }

int main(void) {
    @autoreleasepool {
        TestAddonRoot = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"MiniStreamCatalogTests-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        for (NSString *text in @[@"https://example.invalid/movie.mp4",@"https://example.invalid/a?token=opaque",@"https://8.8.8.8/video"]) {
            check(MSIsSafeRemoteURL([NSURL URLWithString:text]),"public HTTPS-shaped URL accepted without network resolution");
        }
        NSArray *unsafe=@[@"http://example.invalid/video",@"file:///etc/hosts",@"data:text/plain,x",@"javascript:alert(1)",
            @"https://name:password@example.invalid/a",@"https://name@example.invalid/a",@"https://localhost/a",
            @"https://localhost./a",@"https://sub.localhost/a",@"https://printer.local/a",@"https://printer.local./a",
            @"https://127.0.0.1/a",@"https://10.2.3.4/a",@"https://172.16.1.1/a",@"https://172.31.255.255/a",
            @"https://192.168.1.1/a",@"https://169.254.10.20/a",@"https://0.0.0.0/a",@"https://224.0.0.1/a",
            @"https://100.64.0.1/a",@"https://[::1]/a",@"https://[fe80::1]/a",@"https://127.1/a",
            @"https://2130706433/a",@"https://0x7f000001/a",@"https://0177.0.0.1/a"];
        for (NSString *text in unsafe) {
            NSString *label=[@"unsafe destination rejected: " stringByAppendingString:text];
            check(!MSIsSafeRemoteURL([NSURL URLWithString:text]),label.UTF8String);
        }
        check(!MSIsSafeRemoteURL(nil),"nil URL rejected");
        check(!MSIsSafeRemoteURL([NSURL URLWithString:[@"https://example.invalid/" stringByAppendingString:repeat(@"x",17000)]]),"overlong remote URL rejected");

        NSDictionary *movie=fixture(@"cinemeta_meta_movie.json")[@"meta"];
        MSMetadata *metadata=[MSMetadata metadataWithDictionary:movie fallbackType:@"movie"];
        check([metadata.identifier isEqualToString:@"tt1254207"] && [metadata.title isEqualToString:@"Big Buck Bunny"],"movie fixture retains identifier and title");
        check([metadata.type isEqualToString:@"movie"] && metadata.posterURL!=nil,"movie type and safe poster mapped");
        NSMutableDictionary *originInput = [movie mutableCopy]; originInput[@"originConnectionIdentifier"] = @"4FBAA1B5-2529-4B9D-9A83-8657B43D44A1";
        check(![MSMetadata metadataWithDictionary:originInput fallbackType:@"movie"].originConnectionIdentifier, "remote metadata cannot forge its catalog origin");
        MSMetadata *localMetadata = [MSMetadata metadataWithDictionary:originInput fallbackType:@"movie" originConnectionIdentifier:originInput[@"originConnectionIdentifier"]];
        check([localMetadata.originConnectionIdentifier isEqual:originInput[@"originConnectionIdentifier"]], "explicit local reconstruction retains validated origin UUID");
        check(![MSMetadata metadataWithDictionary:movie fallbackType:@"movie" originConnectionIdentifier:@"https://private.invalid/key"].originConnectionIdentifier, "origin rejects URLs and arbitrary strings");
        originInput[@"id"] = @"tmdb:42"; originInput[@"behaviorHints"] = @{@"defaultVideoId":@"tt1234567"};
        MSMetadata *mappedMovie = [MSMetadata metadataWithDictionary:originInput fallbackType:@"movie"];
        check([mappedMovie.identifier isEqual:@"tmdb:42"] && [mappedMovie.defaultVideoIdentifier isEqual:@"tt1234567"], "provider metadata ID and resolved movie stream ID stay separate");
        originInput[@"behaviorHints"] = @{@"defaultVideoId":@"https://private.invalid/key"};
        check([[MSMetadata metadataWithDictionary:originInput fallbackType:@"movie"].defaultVideoIdentifier isEqual:@"tmdb:42"], "invalid default stream ID falls back without rewriting catalog ID");
        check([metadata.imdbRating isEqualToString:@""],"missing IMDb rating stays absent rather than inventing a score");
        NSMutableDictionary *rated=[movie mutableCopy];
        for (NSArray *pair in @[@[@"6.8",@"6.8"],@[@" 7.0 ",@"7.0"],@[@"0",@"0.0"],@[@"10.0",@"10.0"],@[@8.25,@"8.2"]]) {
            rated[@"imdbRating"]=pair[0];
            check([[MSMetadata metadataWithDictionary:rated fallbackType:@"movie"].imdbRating isEqualToString:pair[1]],"valid IMDb rating normalized from existing metadata");
        }
        for (id bad in @[[NSNull null],@YES,@NO,@[],@{},@"",@"N/A",@"NaN",@"Infinity",@"-1",@"10.1",@"7.5 / 10",@"1e1",@"7,5",@"0x8",repeat(@"0",17)]) {
            rated[@"imdbRating"]=bad;
            check([MSMetadata metadataWithDictionary:rated fallbackType:@"movie"].imdbRating.length==0,"malformed or out-of-range IMDb rating omitted without coercion");
        }
        MSMetadata *series=[MSMetadata metadataWithDictionary:fixture(@"cinemeta_meta_series.json")[@"meta"] fallbackType:@"series"];
        check(series.episodes.count==2 && [series.episodes[0].identifier isEqualToString:@"tt0096697:0:1"],"episode IDs retain season-zero special syntax exactly");
        check(series.episodes[0].season==0 && series.episodes[1].episode==2,"episode numeric fields mapped");
        for (id bad in @[[NSNull null],@[],@"text",@42,@{},@{@"id":@7,@"name":@"Name"},@{@"id":@"tt1",@"name":[NSNull null]}]) {
            check([MSMetadata metadataWithDictionary:bad fallbackType:@"movie"]==nil,"invalid metadata row safely rejected");
        }
        NSMutableDictionary *bounded=[movie mutableCopy];
        bounded[@"name"]=repeat(@"t",600); bounded[@"description"]=repeat(@"d",15000);
        bounded[@"poster"]=@"https://127.0.0.1/private"; bounded[@"genres"]=@[@"Drama",@4,[NSNull null],@"Comedy"];
        metadata=[MSMetadata metadataWithDictionary:bounded fallbackType:@"movie"];
        check(metadata.title.length<=400 && metadata.summary.length<=12000,"display metadata bounded");
        check(metadata.posterURL==nil && metadata.genres.count==2,"unsafe poster and malformed genres excluded");
        bounded[@"id"]=repeat(@"i",1025);
        check([MSMetadata metadataWithDictionary:bounded fallbackType:@"movie"]==nil,"overlong semantic ID rejected rather than rewritten");
        bounded=[movie mutableCopy]; bounded[@"type"]=@"series";
        bounded[@"videos"]=@[@{@"id":@"tt1:2:4",@"season":@2,@"episode":@4},
            [NSNull null],@{@"id":repeat(@"v",1025),@"season":@0,@"episode":@0},
            @{@"id":@"tt1:0:2",@"season":@0,@"episode":@2},@{@"name":@"Missing id"},
            @{@"id":@"tt1:1:1",@"season":@1,@"episode":@1}];
        metadata=[MSMetadata metadataWithDictionary:bounded fallbackType:@"series"];
        check(metadata.episodes.count==3,"invalid and overlong episode IDs excluded");
        if (metadata.episodes.count==3) check([metadata.episodes[0].identifier isEqualToString:@"tt1:0:2"] && [metadata.episodes[2].identifier isEqualToString:@"tt1:2:4"],"episodes ordered season then episode");
        bounded[@"videos"]=@"wrong array type"; bounded[@"genres"]=[NSNull null];
        metadata=[MSMetadata metadataWithDictionary:bounded fallbackType:@"series"];
        check(metadata.episodes.count==0 && metadata.genres.count==0,"malformed list fields do not crash");

        MSStream *source=stream(fixture(@"stream_demo.json")[@"streams"][0]);
        check(source.canAttemptPlayback && [source.URL.scheme isEqualToString:@"https"],"ordinary public H264 MP4 fixture eligible for attempt");
        NSString *repairSecret=[@"D-" stringByAppendingString:repeat(@"a",64)];
        NSString *repairReference=[NSString stringWithFormat:@"T-%@.%@",repeat(@"8",64),repeat(@"9",43)];
        NSURL *repairManifest=[NSURL URLWithString:[NSString stringWithFormat:@"https://mediafusion.elfhosted.com/%@/manifest.json",repairSecret]];
        MSAddon *repairAddon=[MSAddon addonWithManifest:@{@"id":@"stremio.addons.mediafusion|elfhostedtrb",@"name":@"MediaFusion",@"types":@[@"movie"],@"resources":@[@"stream"],@"catalogs":@[]} URL:repairManifest error:nil];
        NSDictionary *repairRaw=@{@"url":[NSString stringWithFormat:@"https://mediafusion.elfhosted.com/streaming_provider/D-[redacted]/playback/torbox/%@",repairReference],@"name":@"1080p H.264",@"behaviorHints":@{@"filename":@"Synthetic.fixture.mp4"}};
        source=[MSStream streamWithDictionary:repairRaw addon:repairAddon];
        check(source.canAttemptPlayback && [source.URL.path containsString:repairSecret] && [source.URL.lastPathComponent isEqual:repairReference],"exact add-on ingestion restores known config and retains reference");
        check([repairRaw[@"url"] containsString:@"[redacted]"] && [repairAddon.manifestURL isEqual:repairManifest],"repair never mutates source document or saved configuration");
        MSStream *withoutContext=[MSStream streamWithDictionary:repairRaw addonName:repairAddon.name addonIdentifier:repairAddon.identifier];
        check([withoutContext.URL.path containsString:@"[redacted]"] && [source.sourceFingerprint isEqual:withoutContext.sourceFingerprint],"context-free parsing leaves URL untouched and source fingerprint unchanged");
        for (NSString *name in @[@"stream_unsupported_torrent.json",@"stream_unsupported_external.json",@"stream_unsupported_proxy_headers.json"]) {
            source=stream(fixture(name)[@"streams"][0]); check(!source.canAttemptPlayback,"unsupported transport fixture cannot play natively");
        }
        for (id bad in @[[NSNull null],@[],@"text",@12]) check(stream(bad)==nil,"nonobject stream safely rejected");
        check(!stream(@{@"url":[NSNull null],@"behaviorHints":@[]}).canAttemptPlayback,"malformed URL and hints cannot play");
        for (NSString *suffix in @[@"mkv",@"MKV",@"webm",@"avi"]) {
            source=stream(@{@"url":[@"https://example.invalid/movie." stringByAppendingString:suffix]});
            check(source.canAttemptPlayback,"alternate containers eligible for selected-source VideoLAN attempt");
        }
        for (NSString *label in @[@"2160p",@"4K HEVC",@"H.265",@"x265 10-bit HDR",@"AV1",@"VP9",@"HDR"]) {
            source=stream(@{@"url":@"https://example.invalid/video.mp4",@"name":label});
            check(!source.canAttemptPlayback,"unsupported source labels require explicit helper/conversion");
        }
        for (NSString *audio in @[@"DTS",@"TrueHD",@"FLAC",@"PCM"]) {
            source=stream(@{@"url":@"https://example.invalid/movie.mp4",@"name":[@"1080p H.264 " stringByAppendingString:audio]});
            check(source.canAttemptPlayback && source.prefersVLC,"alternate audio uses VideoLAN even inside a native container");
        }
        source=stream(@{@"url":@"https://example.invalid/file",@"behaviorHints":@{@"filename":@"Film.1080p.x264.mkv"}});
        check(source.canAttemptPlayback && [source.codecLabel containsString:@"MKV"],"container filename hint displayed without excluding H264");
        source=stream(@{@"url":@"https://example.invalid/file",@"behaviorHints":@{@"filename":@"Film.HEVC.mkv"}});
        check(!source.canAttemptPlayback,"filename hints participate in conservative classification");
        source=stream(@{@"url":[@"https://example.invalid/" stringByAppendingString:repeat(@"x",17000)]});
        check(!source.canAttemptPlayback && source.URL==nil,"overlong stream URL rejected without truncation");
        source=stream(@{@"url":@"https://example.invalid/file.mp4",@"behaviorHints":@{
            @"filename":@"Film & name.mp4",@"videoHash":@"0123456789abcdef",@"videoSize":@12345678,@"ignored":@"not an extra"}});
        check([source.subtitleExtras[@"filename"] isEqualToString:@"Film & name.mp4"] && [source.subtitleExtras[@"videoHash"] isEqualToString:@"0123456789abcdef"] && [source.subtitleExtras[@"videoSize"] isEqualToString:@"12345678"] && source.subtitleExtras.count==3,"subtitle extras preserve exact allowed values and normalize numeric byte size");
        source=stream(@{@"url":@"https://example.invalid/file.mp4",@"behaviorHints":@{
            @"filename":@[],@"videoHash":[NSNull null],@"videoSize":@{},@"proxyHeaders":@{}}});
        check(source.subtitleExtras.count==0,"malformed subtitle extras excluded");
        source=stream(@{@"url":@"https://example.invalid/file.mp4",@"description":@"Watch https://secret.invalid/path?token=not-real now"});
        check(![source.detail containsString:@"secret.invalid"] && ![source.detail containsString:@"token="],"provider description redacts embedded links");

        NSDictionary *native1080 = @{@"url":@"https://example.invalid/watch?token=first", @"name":@"1080p H.264", @"description":@"AAC · 12 peers", @"behaviorHints":@{@"filename":@"Episode.S01E02.1080p.x264.mp4",@"bingeGroup":@"fixture-1080"}};
        source = [MSStream streamWithDictionary:native1080 addonName:@"Provider" addonIdentifier:@"org.fixture"];
        check(source.canAttemptPlayback && [source.reportedResolution isEqualToString:@"1080p"] && [source.codecLabel containsString:@"H.264"],"1080p H264 remains eligible and reports visible format");
        check([source.providerIdentifier isEqualToString:@"org.fixture"] && [source.bingeGroup isEqualToString:@"fixture-1080"],"provider and optional binge group retained for explicit next selection");
        check([source matchesProvider:@"org.fixture" resolution:@"1080p" compatibleOnly:YES],"matching combined filters include eligible source");
        check(![source matchesProvider:@"other.provider" resolution:nil compatibleOnly:NO],"provider filter excludes other provider");
        check(![source matchesProvider:nil resolution:@"720p" compatibleOnly:NO],"resolution filter excludes other quality");
        check([source matchesProvider:nil resolution:nil compatibleOnly:YES],"empty filters include compatible source");
        NSMutableDictionary *rotated = [native1080 mutableCopy]; rotated[@"url"] = @"https://example.invalid/watch?token=second"; rotated[@"description"] = @"AAC · 28 peers";
        MSStream *sameSource = [MSStream streamWithDictionary:rotated addonName:@"Provider" addonIdentifier:@"org.fixture"];
        check([source.sourceFingerprint isEqualToString:sameSource.sourceFingerprint],"stable filename identity ignores rotated URL and volatile description");
        check([source.sourceFingerprint hasPrefix:@"sha256:"] && source.sourceFingerprint.length==71 && ![source.sourceFingerprint containsString:@"token"],"persistable source identity is opaque digest only");
        source=stream(@{@"url":@"https://example.invalid/video.mp4",@"name":@"1080p HEVC x265"});
        check(!source.canAttemptPlayback && [source.codecLabel containsString:@"HEVC"],"HEVC incompatibility is visible separately from 1080p resolution");
        check(![source matchesProvider:nil resolution:@"1080p" compatibleOnly:YES] && [source matchesProvider:nil resolution:@"1080p" compatibleOnly:NO],"compatible-only hides unsupported rows but show-all retains them");
        source=stream(@{@"url":@"https://example.invalid/video.mp4"});
        check(!source.reportedResolution.length && [source matchesProvider:nil resolution:@"unreported" compatibleOnly:YES],"unreported resolution is explicit filter value rather than guessed quality");
        source=stream(@{@"url":@"https://example.invalid/video.mp4",@"behaviorHints":@{@"bingeGroup":@[],@"filename":@42}});
        check(!source.bingeGroup.length && !source.filename.length,"malformed matching hints safely omitted");

        source=stream(@{@"url":@"https://example.invalid/video.mp4", @"subtitles":@[@{@"url":@"https://example.invalid/english.srt", @"lang":@"eng"}, @{@"url":@"http://example.invalid/unsafe.srt"}, [NSNull null]]});
        check(source.providedSubtitles.count==1 && [source.providedSubtitles[0][@"lang"] isEqualToString:@"eng"],"stream-provided captions retain safe HTTPS option only");
        // Fixture transport tests endpoint escaping and response mapping. They
        // deliberately do not claim to test NSURLSession cancellation/redirects.
        swapTransport();
        stubDocument=fixture(@"cinemeta_catalog.json"); stubError=nil;
        __block MSCatalogPage *page=nil; __block NSError *responseError=nil;
        [[MSCatalogClient sharedClient] loadCatalogType:@"series" search:@"one & two/三?skip=9" skip:100 completion:^(MSCatalogPage *p,NSError *e) {page=p;responseError=e;}];
        check(responseError==nil && page.items.count==2 && page.receivedCount==2 && page.nextSkip==102 && page.hasMore,"catalog page maps bounded results and source offsets");
        NSString *endpoint=capturedURL.absoluteString;
        check([endpoint containsString:@"/catalog/series/top/search=one%20%26%20two%2F%E4%B8%89%3Fskip%3D9&skip=100.json"] && capturedURL.query==nil,"search extras are encoded inside one path segment");
        stubDocument=@{@"metas":@[[NSNull null],@{@"id":@"ttx",@"name":@"Title"},@"bad"]};
        [[MSCatalogClient sharedClient] loadCatalogType:@"movie" search:nil skip:20 completion:^(MSCatalogPage *p,NSError *e) {page=p;responseError=e;}];
        check(page.items.count==1 && page.receivedCount==3 && page.nextSkip==23,"invalid rows skipped without corrupting provider offset");
        stubDocument=@{@"metas":@[]};
        [[MSCatalogClient sharedClient] loadCatalogType:@"movie" search:nil skip:23 completion:^(MSCatalogPage *p,NSError *e) {page=p;responseError=e;}];
        check(page.receivedCount==0 && page.nextSkip==23 && !page.hasMore,"empty page ends pagination without changing offset");
        stubDocument=@{@"metas":@"bad"};
        [[MSCatalogClient sharedClient] loadCatalogType:@"movie" search:nil skip:0 completion:^(MSCatalogPage *p,NSError *e) {page=p;responseError=e;}];
        check(!page && responseError!=nil,"malformed catalog array produces error");
        NSMutableDictionary *escapedMeta = [fixture(@"cinemeta_meta_series.json")[@"meta"] mutableCopy]; escapedMeta[@"id"] = @"tt123:1:2/part?x=1"; stubDocument = @{@"meta":escapedMeta};
        __block MSMetadata *returned=nil;
        [[MSCatalogClient sharedClient] loadMetadataType:@"series" identifier:@"tt123:1:2/part?x=1" completion:^(MSMetadata *m,NSError *e) {returned=m;responseError=e;}];
        check(returned!=nil && responseError==nil && [capturedURL.absoluteString hasSuffix:@"/meta/series/tt123%3A1%3A2%2Fpart%3Fx%3D1.json"] && capturedURL.query==nil,"metadata identifier encoded without losing episode syntax");
        stubError=MSNetworkError(@"Fixture transport failure"); stubDocument=nil;
        [[MSCatalogClient sharedClient] loadCatalogType:@"movie" search:nil skip:0 completion:^(MSCatalogPage *p,NSError *e) {page=p;responseError=e;}];
        check(page==nil && responseError==stubError,"network error forwarded without parsing stale data");
        stubError = nil; requestedURLs = [NSMutableArray array];
        NSDictionary *generic = @{@"id":@"test.catalog",@"name":@"Language fixture",@"types":@[@"movie",@"series"],@"resources":@[@"catalog",@"meta"],@"catalogs":@[@{@"id":@"language/list",@"type":@"movie",@"name":@"Language",@"extra":@[@{@"name":@"genre",@"isRequired":@YES,@"options":@[@"Hindi",@"English"]},@{@"name":@"search"},@{@"name":@"skip"}]}]};
        MSAddonStore *store = MSAddonStore.sharedStore;
        check([store addManifest:generic URL:[NSURL URLWithString:@"https://catalog.example/config%2Fopaque/manifest.json?opaque=example"] error:nil], "isolated fixture connection installed");
        MSAddon *catalogAddon = store.addons.lastObject; MSAddonCatalog *catalog = catalogAddon.catalogs.firstObject;
        stubDocument = @{@"metas":@[@{@"id":@"tmdb:42",@"name":@"Hindi film"}]};
        [[MSCatalogClient sharedClient] loadCatalog:catalog extras:@{@"genre":@"Hindi",@"search":@"a/b & c"} skip:24 completion:^(MSCatalogPage *p,NSError *e){ page=p; responseError=e; }];
        check(page.items.count == 1 && page.nextSkip == 25 && page.hasMore && [page.items.firstObject.originConnectionIdentifier isEqual:catalogAddon.connectionIdentifier], "generic catalog page preserves connection and raw cursor");
        check([capturedURL.absoluteString containsString:@"/config%2Fopaque/catalog/movie/language%2Flist/genre=Hindi&search=a%2Fb%20%26%20c&skip=24.json?opaque=example"], "generic catalog keeps configured base and escapes declared extras");
        NSUInteger beforeInvalid = requestedURLs.count; __block BOOL invalidFinished = NO;
        [[MSCatalogClient sharedClient] loadCatalog:catalog extras:nil skip:0 completion:^(MSCatalogPage *p,NSError *e){ invalidFinished = !p && e != nil; }];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        check(invalidFinished && requestedURLs.count == beforeInvalid, "missing required extras fail before network access");
        __block BOOL cancelledCallback = NO;
        id<MSCancellable> invalidRequest = [[MSCatalogClient sharedClient] loadCatalog:catalog extras:@{@"genre":@"Not offered"} skip:0 completion:^(MSCatalogPage *p,NSError *e){ (void)p; (void)e; cancelledCallback = YES; }];
        [invalidRequest cancel]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        check(!cancelledCallback, "cancel suppresses queued validation completion");
        stubDocument = @{@"meta":@{@"id":@"tmdb:42",@"name":@"Resolved film",@"behaviorHints":@{@"defaultVideoId":@"tt1234567"}}};
        [requestedURLs removeAllObjects];
        [[MSCatalogClient sharedClient] loadMetadataType:@"movie" identifier:@"tmdb:42" preferredConnectionIdentifier:catalogAddon.connectionIdentifier completion:^(MSMetadata *m,NSError *e){ returned=m; responseError=e; }];
        check(returned && !responseError && [returned.originConnectionIdentifier isEqual:catalogAddon.connectionIdentifier] && requestedURLs.count == 1 && [capturedURL.host isEqual:@"catalog.example"], "origin provider resolves non-IMDb metadata before other providers");
        check([returned.defaultVideoIdentifier isEqual:@"tt1234567"], "resolved default movie stream ID reaches client result");
        hostDocuments = @{@"catalog.example":@{@"meta":@{@"id":@"ttWrong",@"name":@"Wrong title"}},@"v3-cinemeta.strem.io":@{@"meta":@{@"id":@"tt42",@"name":@"Correct title"}}};
        [requestedURLs removeAllObjects];
        [[MSCatalogClient sharedClient] loadMetadataType:@"movie" identifier:@"tt42" preferredConnectionIdentifier:catalogAddon.connectionIdentifier completion:^(MSMetadata *m,NSError *e){ returned=m; responseError=e; }];
        check([returned.identifier isEqual:@"tt42"] && requestedURLs.count == 2 && [requestedURLs.firstObject.host isEqual:@"catalog.example"] && [requestedURLs.lastObject.host isEqual:@"v3-cinemeta.strem.io"], "wrong-ID provider response falls back to matching compatible metadata");
        check(![returned.originConnectionIdentifier isEqual:catalogAddon.connectionIdentifier], "fallback result records the responding provider rather than failed origin");
        hostDocuments = nil; deferFixture = YES; [requestedURLs removeAllObjects];
        __block BOOL metadataCompletionCalled = NO;
        id<MSCancellable> pending = [[MSCatalogClient sharedClient] loadMetadataType:@"movie" identifier:@"tmdb:42" preferredConnectionIdentifier:catalogAddon.connectionIdentifier completion:^(MSMetadata *m,NSError *e){ (void)m; (void)e; metadataCompletionCalled = YES; }];
        void (^lateCompletion)(NSDictionary *,NSError *) = deferredFixtureCompletion; deferredFixtureCompletion = nil; [pending cancel]; lateCompletion(nil,MSNetworkError(@"Cancelled fixture"));
        check(!metadataCompletionCalled && requestedURLs.count == 1, "cancelled metadata request cannot deliver or start fallback");
        deferFixture = NO;
        NSMutableDictionary *single = [generic mutableCopy]; single[@"id"] = @"test.single"; single[@"resources"] = @[@"catalog"]; single[@"catalogs"] = @[@{@"id":@"list",@"name":@"List",@"type":@"movie"}];
        check([store addManifest:single URL:[NSURL URLWithString:@"https://single.example/manifest.json"] error:nil], "catalog-only provider installed without a metadata resource");
        MSAddon *singleAddon = store.addons.lastObject; stubDocument = @{@"metas":@[@{@"id":@"tt42",@"name":@"Film"}]};
        [[MSCatalogClient sharedClient] loadCatalog:singleAddon.catalogs.firstObject extras:nil skip:0 completion:^(MSCatalogPage *p,NSError *e){ page=p; responseError=e; }];
        check(page.items.count == 1 && !page.hasMore && [capturedURL.path hasSuffix:@"/catalog/movie/list.json"], "unpaginated catalog omits undeclared skip and stops after first page");
        stubDocument = @{@"meta":@{@"id":@"tt42",@"name":@"Film"}}; [requestedURLs removeAllObjects];
        [[MSCatalogClient sharedClient] loadMetadataType:@"movie" identifier:@"tt42" preferredConnectionIdentifier:singleAddon.connectionIdentifier completion:^(MSMetadata *m,NSError *e){ returned=m; responseError=e; }];
        check(returned && requestedURLs.count == 1 && [capturedURL.host isEqual:@"v3-cinemeta.strem.io"], "catalog-only origin uses compatible Cinemeta metadata without querying unsupported resource");
        NSMutableDictionary *stepped = [single mutableCopy]; stepped[@"id"] = @"test.stepped";
        stepped[@"catalogs"] = @[@{@"id":@"steps",@"name":@"Stepped list",@"type":@"movie",@"extra":@[@{@"name":@"skip",@"options":@[@"0",@"100",@"200"]}]}];
        check([store addManifest:stepped URL:[NSURL URLWithString:@"https://steps.example/manifest.json"] error:nil], "declared pagination offsets accepted");
        MSAddonCatalog *stepCatalog = store.addons.lastObject.catalogs.firstObject;
        stubDocument = @{@"metas":@[@{@"id":@"tt42",@"name":@"Film"}]};
        [[MSCatalogClient sharedClient] loadCatalog:stepCatalog extras:nil skip:0 completion:^(MSCatalogPage *p,NSError *e){ page=p; responseError=e; }];
        check(page.receivedCount == 1 && page.nextSkip == 100 && page.hasMore, "declared next page offset overrides raw-count cursor when provider specifies steps");
        [[MSCatalogClient sharedClient] loadCatalog:stepCatalog extras:nil skip:200 completion:^(MSCatalogPage *p,NSError *e){ page=p; responseError=e; }];
        check(page.receivedCount == 1 && !page.hasMore, "last declared pagination offset ends paging");
        check(![stepCatalog requestExtrasForValues:nil skip:50 error:nil], "undeclared pagination offset cannot be requested");
        swapTransport();
        [NSFileManager.defaultManager removeItemAtURL:TestAddonRoot error:nil];
        printf("%s %u catalog/stream checks; %u failures (offline fixture transport)\n",failures ? "FAIL" : "PASS",checks,failures);
        return failures ? 1 : 0;
    }
}
