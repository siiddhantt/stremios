#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "MSCatalogClient.h"
#import "MSHTTPClient.h"
#import "MSStream.h"

// Host-only production parser/policy tests. Network transport is replaced by a
// synchronous fixture response while testing catalog paths; no requests occur.
static unsigned checks=0, failures=0;
static NSURL *capturedURL;
static NSDictionary *stubDocument;
static NSError *stubError;
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
    capturedURL=URL; completion(stubDocument,stubError); return [MSFixtureRequest new];
}
@end
static void swapTransport(void) {
    method_exchangeImplementations(class_getInstanceMethod(MSHTTPClient.class,@selector(fetchJSONURL:completion:)),
        class_getInstanceMethod(MSHTTPClient.class,@selector(test_fetchJSONURL:completion:)));
}
static MSStream *stream(NSDictionary *raw) { return [MSStream streamWithDictionary:raw addonName:@"Fixture add-on"]; }

int main(void) {
    @autoreleasepool {
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
        stubDocument=fixture(@"cinemeta_meta_series.json");
        __block MSMetadata *returned=nil;
        [[MSCatalogClient sharedClient] loadMetadataType:@"series" identifier:@"tt123:1:2/part?x=1" completion:^(MSMetadata *m,NSError *e) {returned=m;responseError=e;}];
        check(returned!=nil && responseError==nil && [capturedURL.absoluteString hasSuffix:@"/meta/series/tt123%3A1%3A2%2Fpart%3Fx%3D1.json"] && capturedURL.query==nil,"metadata identifier encoded without losing episode syntax");
        stubError=MSNetworkError(@"Fixture transport failure"); stubDocument=nil;
        [[MSCatalogClient sharedClient] loadCatalogType:@"movie" search:nil skip:0 completion:^(MSCatalogPage *p,NSError *e) {page=p;responseError=e;}];
        check(page==nil && responseError==stubError,"network error forwarded without parsing stale data");
        swapTransport();
        printf("%s %u catalog/stream checks; %u failures (offline fixture transport)\n",failures ? "FAIL" : "PASS",checks,failures);
        return failures ? 1 : 0;
    }
}
