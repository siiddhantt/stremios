#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "MSPlaybackSourceResolver.h"

static unsigned checks, failures;
static NSString *scenario;
static NSUInteger starts, stops, delayedChunks, badRequestHeaders;
static BOOL privateConfiguration;
static void check(BOOL value, const char *name) {
    checks++; if (!value) { failures++; fprintf(stderr, "FAIL source resolver: %s\n", name); }
}
static void pump(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static NSData *mp4(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:MAX((NSUInteger)24, length)];
    unsigned char *b = data.mutableBytes; b[3] = 24; memcpy(b + 4, "ftypisom", 8);
    return data;
}
@interface MSPlaybackFixtureProtocol : NSURLProtocol
@property(atomic) BOOL stopped;
@end
@implementation MSPlaybackFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { (void)request; return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)response:(NSInteger)status headers:(NSDictionary *)headers {
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status
        HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}
- (void)data:(NSData *)data { if (!self.stopped) [self.client URLProtocol:self didLoadData:data]; }
- (void)done { if (!self.stopped) [self.client URLProtocolDidFinishLoading:self]; }
- (void)startLoading {
    @synchronized (MSPlaybackFixtureProtocol.class) {
        starts++;
        if (![self.request.HTTPMethod isEqual:@"GET"] ||
            ![[self.request valueForHTTPHeaderField:@"Range"] isEqual:@"bytes=0-4095"] ||
            ![[self.request valueForHTTPHeaderField:@"Accept-Encoding"] isEqual:@"identity"] ||
            [self.request valueForHTTPHeaderField:@"Authorization"] || [self.request valueForHTTPHeaderField:@"Cookie"])
            badRequestHeaders++;
    }
    NSString *mode = [scenario copy];
    if ([mode hasPrefix:@"redirect-"]) {
        NSUInteger hop = self.request.URL.lastPathComponent.integerValue;
        if ([mode isEqual:@"redirect-safe"] && hop >= 1) {
            [self response:200 headers:@{@"Content-Type":@"video/mp4"}]; [self data:mp4(24)]; [self done]; return;
        }
        NSString *target = [NSString stringWithFormat:@"https://other.fixture.invalid/%lu?token=synthetic-secret",(unsigned long)hop + 1];
        if ([mode isEqual:@"redirect-http"]) target = @"http://fixture.invalid/1";
        if ([mode isEqual:@"redirect-local"]) target = @"https://127.0.0.1/1";
        if ([mode isEqual:@"redirect-credentials"]) target = @"https://user:private-password@fixture.invalid/1";
        if ([mode isEqual:@"redirect-placeholder"]) target = @"https://slate.elfhosted.com/slate.mp4";
        NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:302
            HTTPVersion:@"HTTP/1.1" headerFields:@{@"Location":target}];
        [self.client URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:target]] redirectResponse:r];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20000000), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf; if (!self || self.stopped) return;
            [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed]; [self done];
        }); return;
    }
    if ([mode isEqual:@"timeout"]) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
            userInfo:@{NSLocalizedDescriptionKey:@"raw-private-token",NSURLErrorFailingURLErrorKey:self.request.URL}]]; return;
    }
    if ([mode isEqual:@"403"]) { [self response:403 headers:@{}]; [self data:[@"private-error-body" dataUsingEncoding:NSUTF8StringEncoding]]; [self done]; return; }
    NSMutableDictionary *headers = [@{@"Content-Type":@"application/octet-stream"} mutableCopy];
    NSInteger status = 200;
    NSData *body = mp4(24);
    if ([mode isEqual:@"mkv"]) { const unsigned char b[] = {0x1a,0x45,0xdf,0xa3,0x9f}; body = [NSData dataWithBytes:b length:sizeof(b)]; }
    if ([mode isEqual:@"hls"]) body = [@"\ufeff \n#EXTM3U\n#EXT-X-VERSION:3\n" dataUsingEncoding:NSUTF8StringEncoding];
    if ([mode isEqual:@"truncated-utf8-hls"]) {
        NSMutableData *d = [NSMutableData dataWithLength:4096]; memset(d.mutableBytes, ' ', d.length);
        memcpy(d.mutableBytes, "#EXTM3U\n", 8); ((unsigned char *)d.mutableBytes)[4095] = 0xf0; body = d;
    }
    if ([mode isEqual:@"other"]) { const unsigned char b[] = {0x47,0x40,0,0x10,0}; body = [NSData dataWithBytes:b length:sizeof(b)]; }
    if ([mode isEqual:@"empty"]) body = [NSData data];
    if ([mode isEqual:@"html-body"]) body = [@" \n<!DOCTYPE html><p>private-error-body</p>" dataUsingEncoding:NSUTF8StringEncoding];
    if ([mode isEqual:@"json-body"]) body = [@"\ufeff{\"error\":\"private-error-body\"}" dataUsingEncoding:NSUTF8StringEncoding];
    if ([mode isEqual:@"utf16-error"]) body = [@"<html>private-error-body</html>" dataUsingEncoding:NSUTF16StringEncoding];
    if ([mode isEqual:@"html-mime"]) headers[@"Content-Type"] = @"text/html";
    if ([mode isEqual:@"image-mime"]) headers[@"Content-Type"] = @"image/png";
    if ([mode isEqual:@"bad-atom"]) { NSMutableData *d = [mp4(24) mutableCopy]; ((unsigned char *)d.mutableBytes)[3] = 2; body = d; }
    if ([mode isEqual:@"free-before-ftyp"]) {
        NSMutableData *d = [NSMutableData dataWithLength:8]; ((unsigned char *)d.mutableBytes)[3] = 8;
        memcpy((unsigned char *)d.mutableBytes + 4, "free", 4); [d appendData:mp4(24)]; body = d;
    }
    if ([mode isEqual:@"extended-ftyp"]) {
        NSMutableData *d = [NSMutableData dataWithLength:24]; unsigned char *b = d.mutableBytes;
        b[3] = 1; memcpy(b + 4, "ftyp", 4); b[15] = 24; memcpy(b + 16, "isom", 4); body = d;
    }
    if ([mode hasPrefix:@"range-"]) {
        status = 206; body = mp4(4096); headers[@"Content-Range"] = @"bytes 0-4095/99999";
        if ([mode isEqual:@"range-offset"]) headers[@"Content-Range"] = @"bytes 1-4096/99999";
        if ([mode isEqual:@"range-overlong"]) headers[@"Content-Range"] = @"bytes 0-4096/99999";
        if ([mode isEqual:@"range-overflow"]) headers[@"Content-Range"] = @"bytes 0-18446744073709551616/99999";
        if ([mode isEqual:@"range-total"]) headers[@"Content-Range"] = @"bytes 0-4095/4095";
        if ([mode isEqual:@"range-missing"]) [headers removeObjectForKey:@"Content-Range"];
        if ([mode isEqual:@"range-length"]) headers[@"Content-Length"] = @"100";
        if ([mode isEqual:@"range-truncated"]) body = mp4(24);
        if ([mode isEqual:@"range-extra-body"]) { headers[@"Content-Range"] = @"bytes 0-23/99999"; body = mp4(30); }
        if ([mode isEqual:@"range-short-valid"]) { headers[@"Content-Range"] = @"bytes 0-23/24"; headers[@"Content-Length"] = @"24"; body = mp4(24); }
    }
    if ([mode isEqual:@"ignored-range-large"]) headers[@"Content-Length"] = @"999999999";
    [self response:status headers:headers];
    if ([mode isEqual:@"delayed"]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100000000), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf; if (!self || self.stopped) return;
            [self data:body]; [self done];
        }); return;
    }
    if ([mode isEqual:@"ignored-range-large"]) {
        [self data:mp4(8192)];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100000000), dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf; if (!self || self.stopped) return;
            delayedChunks++; [self data:[NSMutableData dataWithLength:1000000]]; [self done];
        }); return;
    }
    [self data:body]; [self done];
}
- (void)stopLoading { self.stopped = YES; @synchronized (MSPlaybackFixtureProtocol.class) { stops++; } }
@end

@interface NSURLSessionConfiguration (MSPlaybackResolverTests)
+ (NSURLSessionConfiguration *)ms_resolverTestConfiguration;
@end
@implementation NSURLSessionConfiguration (MSPlaybackResolverTests)
+ (NSURLSessionConfiguration *)ms_resolverTestConfiguration {
    NSURLSessionConfiguration *config = [self ms_resolverTestConfiguration];
    config.protocolClasses = @[MSPlaybackFixtureProtocol.class]; return config;
}
@end
@interface NSURLSession (MSPlaybackResolverTests)
+ (NSURLSession *)ms_resolverTestSessionWithConfiguration:(NSURLSessionConfiguration *)config delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue;
@end
@implementation NSURLSession (MSPlaybackResolverTests)
+ (NSURLSession *)ms_resolverTestSessionWithConfiguration:(NSURLSessionConfiguration *)config delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    privateConfiguration = !config.URLCache && !config.HTTPCookieStorage && !config.URLCredentialStorage &&
        !config.HTTPShouldSetCookies && config.HTTPCookieAcceptPolicy == NSHTTPCookieAcceptPolicyNever &&
        config.timeoutIntervalForRequest == 15 && config.timeoutIntervalForResource == 30;
    return [self ms_resolverTestSessionWithConfiguration:config delegate:delegate delegateQueue:queue];
}
@end
static void swaps(void) {
    method_exchangeImplementations(class_getClassMethod(NSURLSessionConfiguration.class,@selector(ephemeralSessionConfiguration)),
        class_getClassMethod(NSURLSessionConfiguration.class,@selector(ms_resolverTestConfiguration)));
    method_exchangeImplementations(class_getClassMethod(NSURLSession.class,@selector(sessionWithConfiguration:delegate:delegateQueue:)),
        class_getClassMethod(NSURLSession.class,@selector(ms_resolverTestSessionWithConfiguration:delegate:delegateQueue:)));
}
static MSResolvedPlaybackSource *run(NSString *mode, NSString *container, const char *name) {
    scenario = mode;
    __block NSUInteger callbacks = 0; __block BOOL onMain = NO;
    __block MSResolvedPlaybackSource *result = nil; __block NSError *failure = nil;
    [[MSPlaybackSourceResolver sharedResolver] resolveURL:[NSURL URLWithString:@"https://fixture.invalid/0?token=synthetic-secret"]
        completion:^(MSResolvedPlaybackSource *source, NSError *error) { callbacks++; onMain = NSThread.isMainThread; result = source; failure = error; }];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!callbacks && end.timeIntervalSinceNow > 0) pump(0.005);
    pump(0.02);
    check(callbacks == 1 && onMain, "exactly one main-queue callback");
    check(container ? ([result.container isEqual:container] && !failure) : (!result && failure), name);
    if (result) check(result.useVLC == ([container isEqual:@"matroska"] || [container isEqual:@"other"]), "container selects matching engine");
    if (failure) {
        NSString *all = failure.userInfo.description;
        check(![all containsString:@"synthetic-secret"] && ![all containsString:@"private-"] &&
            ![all containsString:@"fixture.invalid"] && ![all containsString:@"://"], "failure contains no URL raw body or raw error");
        NSArray *kinds=@[@"provider-placeholder",@"provider-page",@"provider-http",@"provider-range",@"provider-empty",@"timeout",@"network",@"unsupported-address"];
        check(failure.userInfo.count==2 && [kinds containsObject:failure.userInfo[@"failureKind"]], "failure diagnostics contain only fixed classification and sanitized description");
    }
    return result;
}
int main(void) {
    @autoreleasepool {
        swaps();
        run(@"mp4", @"mp4", "MP4 signature without relying on extension");
        run(@"mkv", @"matroska", "EBML uses VLC");
        run(@"hls", @"hls", "BOM and whitespace HLS prefix");
        run(@"truncated-utf8-hls", @"hls", "partial UTF8 tail does not hide HLS");
        run(@"other", @"other", "other binary container uses VLC");
        run(@"bad-atom", @"other", "impossible atom size is not MP4");
        run(@"free-before-ftyp", @"mp4", "leading free atom accepted");
        run(@"extended-ftyp", @"mp4", "64-bit MP4 atom size accepted");
        run(@"range-valid", @"mp4", "valid initial206 range");
        run(@"range-short-valid", @"mp4", "short complete206 range");
        for (NSString *s in @[@"range-offset",@"range-overlong",@"range-overflow",@"range-total",@"range-missing",@"range-length",@"range-truncated",@"range-extra-body"])
            run(s,nil,"invalid partial response rejected");
        for (NSString *s in @[@"empty",@"html-body",@"json-body",@"utf16-error",@"html-mime",@"image-mime",@"403",@"timeout"])
            run(s,nil,"error document or transport failure rejected");
        MSResolvedPlaybackSource *source = run(@"redirect-safe",@"mp4","safe redirect accepted");
        check([source.URL.host isEqual:@"other.fixture.invalid"] && [source.URL.query isEqual:@"token=synthetic-secret"], "final validated URL retained intact for playback");
        for (NSString *s in @[@"redirect-http",@"redirect-local",@"redirect-credentials",@"redirect-placeholder"])
            run(s,nil,"unsafe or placeholder redirect rejected");
        NSUInteger before = starts; run(@"redirect-loop",nil,"redirect loop capped");
        check(starts - before <= 6, "at most five followed redirects");
        before = stops; run(@"ignored-range-large",@"mp4","200 ignoring Range resolved from prefix"); pump(0.15);
        check(stops > before && delayedChunks == 0, "full large200 response cancelled before subsequent chunks");
        check(badRequestHeaders == 0, "every hop preserves GET Range identity and omits credentials and cookies");
        check(privateConfiguration, "ephemeral storage and15/30second bounded timeouts");

        scenario = @"delayed"; __block NSUInteger cancelledCallbacks = 0;
        __weak id weakRequest;
        @autoreleasepool {
        id<MSCancellable> request = [[MSPlaybackSourceResolver sharedResolver] resolveURL:[NSURL URLWithString:@"https://fixture.invalid/delay"]
            completion:^(MSResolvedPlaybackSource *s,NSError *e) { (void)s;(void)e;cancelledCallbacks++; }];
        before = stops; pump(0.02); [request cancel]; [request cancel]; pump(0.15);
        check(cancelledCallbacks == 0 && stops > before, "cancel stops transport and suppresses late completion");
        weakRequest = request; request = nil;
        }
        pump(0.1);
        check(weakRequest == nil, "cancelled request delegate/session cycle released after autorelease drain");
        before = starts;
        id<MSCancellable> request = [[MSPlaybackSourceResolver sharedResolver] resolveURL:[NSURL URLWithString:@"file:///private"]
            completion:^(MSResolvedPlaybackSource *s,NSError *e) { (void)s;(void)e;cancelledCallbacks++; }];
        [request cancel]; pump(0.03);
        check(cancelledCallbacks == 0 && starts == before, "late cancellation suppresses already queued rejection");
        __block BOOL placeholderRejected = NO;
        [[MSPlaybackSourceResolver sharedResolver] resolveURL:[NSURL URLWithString:@"https://slate.elfhosted.com/slate.mp4"]
            completion:^(MSResolvedPlaybackSource *s,NSError *e) { placeholderRejected = !s && [e.localizedDescription containsString:@"placeholder"]; }];
        pump(0.03); check(placeholderRejected && starts == before, "known placeholder rejected before transport");
        swaps();
        printf("%s %u playback source resolver checks; %u failures (in-memory transport only)\n", failures ? "FAIL" : "PASS",checks,failures);
        return failures ? 1 : 0;
    }
}
