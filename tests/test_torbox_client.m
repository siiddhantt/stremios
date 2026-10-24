#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "MSTorBoxClient.h"

static NSUInteger checks,failures,starts;
static NSString *mode;
static NSURLRequest *lastRequest;
static BOOL privateConfiguration;
static NSString * const syntheticKey=@"syntheticTorBoxKey123456789";
static void check(BOOL passed,const char *name) { checks++; if(!passed){failures++;fprintf(stderr,"FAIL %s\n",name);} }
static void pump(NSTimeInterval seconds) { NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]]; }

@interface MSTorBoxFixtureProtocol : NSURLProtocol
@property(nonatomic) BOOL stopped;
@end
@implementation MSTorBoxFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [@[@"api.torbox.app",@"torrentio.strem.fun",@"redirect.invalid"] containsObject:request.URL.host]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)response:(NSInteger)status headers:(NSDictionary *)headers {
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}
- (void)complete:(NSData *)data { if(self.stopped)return;[self.client URLProtocol:self didLoadData:data];[self.client URLProtocolDidFinishLoading:self]; }
- (void)startLoading {
    @synchronized(MSTorBoxFixtureProtocol.class){starts++;lastRequest=self.request;}
    NSString *scenario=[mode copy];
    if([scenario isEqual:@"network"]){[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey:syntheticKey,NSURLErrorFailingURLErrorKey:self.request.URL}]];return;}
    if([scenario isEqual:@"redirect"]){
        NSURL *target=[NSURL URLWithString:@"https://redirect.invalid/not-permitted"];
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:self.request.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Location":target.absoluteString}];
        [self.client URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:target] redirectResponse:response];
        __weak typeof(self) weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_main_queue(),^{typeof(self) self=weakSelf;if(self&&!self.stopped){[self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];[self.client URLProtocolDidFinishLoading:self];}});return;
    }
    NSInteger status=[scenario hasPrefix:@"http-"] ? [[scenario substringFromIndex:5] integerValue] : 200;
    [self response:status headers:[scenario isEqual:@"length"] ? @{@"Content-Length":@"9999999"} : @{}];
    if([scenario isEqual:@"chunked"]){[self complete:[NSMutableData dataWithLength:300*1024]];return;}
    NSString *payload=@"{\"success\":true,\"data\":{\"id\":123,\"email\":\"synthetic@example.invalid\"}}";
    if([self.request.URL.host isEqual:@"torrentio.strem.fun"])payload=@"{\"id\":\"synthetic.torrentio\",\"name\":\"Synthetic connector\",\"types\":[\"movie\"],\"resources\":[\"stream\"]}";
    if([scenario isEqual:@"malformed"])payload=@"<html>syntheticTorBoxKey123456789</html>";
    if([scenario isEqual:@"array"])payload=@"[]";
    if([scenario isEqual:@"false"])payload=@"{\"success\":false,\"data\":{}}";
    if([scenario isEqual:@"numeric"])payload=@"{\"success\":1,\"data\":{}}";
    if([scenario isEqual:@"missing-data"])payload=@"{\"success\":true}";
    NSData *body=[payload dataUsingEncoding:NSUTF8StringEncoding];
    if([scenario isEqual:@"delayed"]){__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[weakSelf complete:body];});}
    else [self complete:body];
}
- (void)stopLoading { self.stopped=YES; }
@end

@interface NSURLSessionConfiguration (TorBoxTests)
+ (NSURLSessionConfiguration *)ms_torboxEphemeral;
@end
@implementation NSURLSessionConfiguration (TorBoxTests)
+ (NSURLSessionConfiguration *)ms_torboxEphemeral { NSURLSessionConfiguration *configuration=[self ms_torboxEphemeral];configuration.protocolClasses=@[MSTorBoxFixtureProtocol.class];return configuration; }
@end
@interface NSURLSession (TorBoxTests)
+ (NSURLSession *)ms_torboxSession:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue;
@end
@implementation NSURLSession (TorBoxTests)
+ (NSURLSession *)ms_torboxSession:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    privateConfiguration=!configuration.URLCache&&!configuration.HTTPCookieStorage&&!configuration.URLCredentialStorage&&!configuration.HTTPShouldSetCookies&&configuration.timeoutIntervalForRequest==12&&configuration.timeoutIntervalForResource==20;
    return [self ms_torboxSession:configuration delegate:delegate delegateQueue:queue];
}
@end
static void swaps(void) {
    method_exchangeImplementations(class_getClassMethod(NSURLSessionConfiguration.class,@selector(ephemeralSessionConfiguration)),class_getClassMethod(NSURLSessionConfiguration.class,@selector(ms_torboxEphemeral)));
    method_exchangeImplementations(class_getClassMethod(NSURLSession.class,@selector(sessionWithConfiguration:delegate:delegateQueue:)),class_getClassMethod(NSURLSession.class,@selector(ms_torboxSession:delegate:delegateQueue:)));
}
static void validation(NSString *scenario,BOOL accepted) {
    mode=scenario;__block BOOL done=NO,onMain=NO;__block NSError *failure=nil;NSUInteger before=starts;
    [MSTorBoxClient validateAPIKey:syntheticKey completion:^(NSError *error){done=YES;onMain=NSThread.isMainThread;failure=error;}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(!done&&deadline.timeIntervalSinceNow>0)pump(0.01);
    check(done&&onMain,"TorBox completion is bounded and on main");
    check(accepted ? failure==nil : failure!=nil,"TorBox response validates strictly");
    check(starts==before+1,"validation contacts only the original endpoint including redirects");
    check(privateConfiguration,"session has no cookies credentials disk cache and bounded timeouts");
    check([lastRequest.URL.host isEqual:@"api.torbox.app"]&&[lastRequest.URL.path isEqual:@"/v1/api/user/me"]&&[lastRequest.URL.query isEqual:@"settings=false"]&&![lastRequest.URL.absoluteString containsString:syntheticKey],"TorBox key is absent from the URL");
    check([[lastRequest valueForHTTPHeaderField:@"Authorization"]isEqual:[@"Bearer " stringByAppendingString:syntheticKey]],"TorBox uses only the Bearer header");
    if(failure)check(![failure.description containsString:syntheticKey]&&![failure.description containsString:@"redirect.invalid"]&&![failure.description containsString:@"<html>"],"errors redact raw response and credential values");
}
int main(void) {
    @autoreleasepool {
        swaps();
        NSError *error=nil;check([[MSTorBoxClient normalizedAPIKey:[@" \n" stringByAppendingString:syntheticKey] error:&error]isEqual:syntheticKey]&&!error,"API-key normalization allows surrounding paste whitespace");
        for(id bad in @[@"",@"short",@"Bearer keygoeshere",@"abcdefgh\r\nX-Test: leak",@"abcdefgh|torbox=other",@"https://example.invalid/key",@"abcdefgh/other",@123,[@"a" stringByPaddingToLength:513 withString:@"a" startingAtIndex:0]])check(![MSTorBoxClient normalizedAPIKey:bad error:nil],"invalid API key rejected without transport");
        NSURL *URL=[MSTorBoxClient torrentioManifestURLForAPIKey:syntheticKey error:nil];
        check([URL.host isEqual:@"torrentio.strem.fun"]&&[URL.scheme isEqual:@"https"]&&!URL.user&&!URL.password&&!URL.query&&!URL.fragment,"connector destination is fixed public HTTPS");
        check([URL.path isEqual:[NSString stringWithFormat:@"/debridoptions=nodownloadlinks,nocatalog|torbox=%@/manifest.json",syntheticKey]],"configured path matches official Torrentio format with cached-link filter");
        check(![MSTorBoxClient torrentioManifestURLForAPIKey:@"bad|config" error:nil],"manifest construction cannot inject configuration options");
        for(NSString *scenario in @[@"valid",@"false",@"numeric",@"missing-data",@"malformed",@"array",@"http-403",@"http-429",@"http-503",@"network",@"length",@"chunked",@"redirect"])validation(scenario,[scenario isEqual:@"valid"]);
        mode=@"valid";__block BOOL done=NO;__block NSDictionary *manifest=nil;__block NSError *failure=nil;__block NSURL *configured=nil;
        [MSTorBoxClient fetchTorrentioManifestWithAPIKey:syntheticKey completion:^(NSDictionary *value,NSURL *address,NSError *error){done=YES;manifest=value;configured=address;failure=error;}];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(!done&&deadline.timeIntervalSinceNow>0)pump(0.01);
        check(done&&manifest&&!failure&&[configured isEqual:URL],"consented connector fetch returns its manifest and configured URL");
        check([lastRequest.URL.host isEqual:@"torrentio.strem.fun"]&&![lastRequest valueForHTTPHeaderField:@"Authorization"],"connector receives configured link without TorBox Authorization header");
        mode=@"redirect";done=NO;failure=nil;NSUInteger before=starts;
        [MSTorBoxClient fetchTorrentioManifestWithAPIKey:syntheticKey completion:^(NSDictionary *value,NSURL *address,NSError *error){done=YES;manifest=value;configured=address;failure=error;}];
        deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(!done&&deadline.timeIntervalSinceNow>0)pump(0.01);
        check(done&&failure&&!manifest&&!configured&&starts==before+1,"connector redirect cannot forward configured credential URL");
        mode=@"delayed";__block NSUInteger callbacks=0;
        id<MSCancellable> request=[MSTorBoxClient validateAPIKey:syntheticKey completion:^(__unused NSError *error){callbacks++;}];
        pump(0.02);[request cancel];[request cancel];pump(0.2);check(callbacks==0,"cancelled validation never delivers stale completion");
        before=starts;request=[MSTorBoxClient validateAPIKey:@"bad" completion:^(__unused NSError *error){callbacks++;}];[request cancel];pump(0.05);
        check(callbacks==0&&starts==before,"cancel suppresses queued invalid-key completion without networking");
        swaps();printf("%lu TorBox setup client checks; %lu failures (synthetic transport only)\n",(unsigned long)checks,(unsigned long)failures);return failures?1:0;
    }
}
