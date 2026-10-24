#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "MSHTTPClient.h"

// Host-only transport tests. Every request is intercepted; no socket or user
// account is used. The ephemeral configuration hook exists only in this binary.
static unsigned checks=0,failures=0;
static NSString *scenario;
static NSUInteger protocolStarts=0,protocolStops=0;
static dispatch_semaphore_t parseEntered,parseRelease;
static BOOL parserWasMain;
static void check(BOOL value,const char *name) {
    checks++; if(!value) { failures++; fprintf(stderr,"FAIL HTTP client: %s\n",name); }
}
static void pump(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
@interface MSFixtureURLProtocol : NSURLProtocol
@property(atomic) BOOL stopped;
@end
@implementation MSFixtureURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { (void)request; return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)responseStatus:(NSInteger)status length:(NSString *)length {
    NSMutableDictionary *headers=[@{@"Content-Type":@"application/json"} mutableCopy];
    if(length) headers[@"Content-Length"]=length;
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}
- (void)data:(NSData *)data { if(!self.stopped) [self.client URLProtocol:self didLoadData:data]; }
- (void)done { if(!self.stopped) [self.client URLProtocolDidFinishLoading:self]; }
- (void)startLoading {
    @synchronized(MSFixtureURLProtocol.class) {protocolStarts++;}
    NSString *mode=[scenario copy];
    if([mode isEqual:@"network-error"]) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
            userInfo:@{NSURLErrorFailingURLErrorKey:self.request.URL,NSLocalizedDescriptionKey:@"private-token-in-raw-error"}]]; return;
    }
    if([mode hasPrefix:@"redirect-"]) {
        NSUInteger hop=(NSUInteger)self.request.URL.lastPathComponent.integerValue;
        if([mode isEqual:@"redirect-allowed"] && hop>=1) {
            [self responseStatus:200 length:nil]; [self data:[@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding]]; [self done]; return;
        }
        NSString *target=[NSString stringWithFormat:@"https://fixture.invalid/%lu",(unsigned long)(hop+1)];
        if([mode isEqual:@"redirect-http"]) target=@"http://fixture.invalid/1";
        if([mode isEqual:@"redirect-local"]) target=@"https://127.0.0.1/1";
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Location":target}];
        [self.client URLProtocol:self wasRedirectedToRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:target]] redirectResponse:response];
        // If the delegate declines the redirect, a real server still completes
        // its original 302 response. Accepted redirects stop this protocol.
        __weak typeof(self) weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.02*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            typeof(self) self=weakSelf; if(!self || self.stopped) return;
            [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self done];
        });
        return;
    }
    if([mode isEqual:@"http-error"]) { [self responseStatus:403 length:nil]; [self data:[@"do-not-surface-this-body" dataUsingEncoding:NSUTF8StringEncoding]]; [self done]; return; }
    if([mode isEqual:@"large-header"]) { [self responseStatus:200 length:@"999999999"]; [self done]; return; }
    [self responseStatus:200 length:nil];
    if([mode isEqual:@"delayed"]) {
        __weak typeof(self) weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            typeof(self) self=weakSelf; if(!self || self.stopped) return;
            [self data:[@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding]]; [self done];
        }); return;
    }
    if([mode isEqual:@"chunk-overflow"]) {
        [self data:[NSMutableData dataWithLength:2048]]; [self data:[NSMutableData dataWithLength:2048]]; [self done]; return;
    }
    NSString *payload=@"{\"ok\":true}";
    if([mode isEqual:@"invalid-json"]) payload=@"<html>not JSON</html>";
    if([mode isEqual:@"array-json"]) payload=@"[1,2,3]";
    if([mode isEqual:@"empty"]) payload=@"";
    [self data:[payload dataUsingEncoding:NSUTF8StringEncoding]]; [self done];
}
- (void)stopLoading { self.stopped=YES; @synchronized(MSFixtureURLProtocol.class) {protocolStops++;} }
@end

@interface NSURLSessionConfiguration (HTTPTests)
+ (NSURLSessionConfiguration *)ms_testEphemeralConfiguration;
@end
@implementation NSURLSessionConfiguration (HTTPTests)
+ (NSURLSessionConfiguration *)ms_testEphemeralConfiguration {
    NSURLSessionConfiguration *config=[self ms_testEphemeralConfiguration];
    config.protocolClasses=@[MSFixtureURLProtocol.class]; return config;
}
@end
static void swapConfiguration(void) {
    method_exchangeImplementations(class_getClassMethod(NSURLSessionConfiguration.class,@selector(ephemeralSessionConfiguration)),
        class_getClassMethod(NSURLSessionConfiguration.class,@selector(ms_testEphemeralConfiguration)));
}
@interface NSJSONSerialization (HTTPTests)
+ (id)ms_testJSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)options error:(NSError **)error;
@end
@implementation NSJSONSerialization (HTTPTests)
+ (id)ms_testJSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)options error:(NSError **)error {
    parserWasMain=NSThread.isMainThread;
    dispatch_semaphore_signal(parseEntered);
    // Bounded even if a broken implementation invokes JSON parsing on main.
    dispatch_semaphore_wait(parseRelease,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC));
    return [self ms_testJSONObjectWithData:data options:options error:error];
}
@end
static void swapJSONParser(void) {
    method_exchangeImplementations(class_getClassMethod(NSJSONSerialization.class,@selector(JSONObjectWithData:options:error:)),
        class_getClassMethod(NSJSONSerialization.class,@selector(ms_testJSONObjectWithData:options:error:)));
}
static void testJSON(NSString *mode,BOOL expectSuccess,const char *name) {
    scenario=mode;
    __block BOOL completed=NO,onMain=NO; __block NSDictionary *value=nil; __block NSError *failure=nil;
    [[MSHTTPClient sharedClient] fetchJSONURL:[NSURL URLWithString:@"https://fixture.invalid/0?token=synthetic-secret"] completion:^(NSDictionary *document,NSError *error) {
        completed=YES; onMain=NSThread.isMainThread; value=document; failure=error;
    }];
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!completed && limit.timeIntervalSinceNow>0) pump(0.01);
    check(completed && onMain,name);
    check(expectSuccess ? (value!=nil && failure==nil) : (value==nil && failure!=nil),"JSON success/error shape");
    if(failure) check(![failure.localizedDescription containsString:@"synthetic-secret"] && ![failure.localizedDescription containsString:@"private-token"] && ![failure.localizedDescription containsString:@"fixture.invalid"] && ![failure.localizedDescription containsString:@"do-not-surface"],"transport errors do not expose URL raw body or raw error");
}
int main(void) {
    @autoreleasepool {
        swapConfiguration();
        testJSON(@"valid",YES,"valid JSON arrives on main queue");
        testJSON(@"invalid-json",NO,"malformed JSON handled on main queue");
        testJSON(@"array-json",NO,"nonobject JSON rejected");
        testJSON(@"empty",NO,"empty response rejected");
        testJSON(@"http-error",NO,"HTTP failure handled without body exposure");
        testJSON(@"network-error",NO,"network timeout sanitized");
        testJSON(@"large-header",NO,"oversized Content-Length rejected");
        testJSON(@"redirect-allowed",YES,"public HTTPS redirect succeeds");
        testJSON(@"redirect-http",NO,"redirect cannot downgrade HTTPS");
        testJSON(@"redirect-local",NO,"redirect cannot reach literal local destination");
        testJSON(@"redirect-loop",NO,"redirect loop bounded");

        scenario=@"chunk-overflow";
        __block BOOL completed=NO; __block NSData *body=nil; __block NSError *failure=nil;
        [[MSHTTPClient sharedClient] fetchDataURL:[NSURL URLWithString:@"https://fixture.invalid/chunks"] maximumBytes:3000 completion:^(NSData *data,NSError *error) {completed=YES;body=data;failure=error;}];
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2]; while(!completed && end.timeIntervalSinceNow>0) pump(0.01);
        check(completed && !body && failure!=nil,"unknown-size chunked body cannot exceed byte limit");

        scenario=@"delayed";
        __block NSUInteger cancelledCallbacks=0;
        NSUInteger stopsBefore=protocolStops;
        id<MSCancellable> request=[[MSHTTPClient sharedClient] fetchJSONURL:[NSURL URLWithString:@"https://fixture.invalid/delay"] completion:^(NSDictionary *data,NSError *error) {(void)data;(void)error;cancelledCallbacks++;}];
        pump(0.03); [request cancel]; pump(0.3);
        check(cancelledCallbacks==0,"active cancellation suppresses delayed completion");
        check(protocolStops>stopsBefore,"active cancellation stops transport");
        [request cancel]; pump(0.02); check(cancelledCallbacks==0,"repeated cancellation remains harmless");

        __block BOOL rejectedCallback=NO;
        NSUInteger startsBefore=protocolStarts;
        request=[[MSHTTPClient sharedClient] fetchJSONURL:[NSURL URLWithString:@"file:///do-not-read"] completion:^(NSDictionary *data,NSError *error) {(void)data;(void)error;rejectedCallback=YES;}];
        [request cancel]; pump(0.05);
        check(!rejectedCallback && protocolStarts==startsBefore,"cancellation suppresses queued unsafe-URL rejection without transport");

        scenario=@"valid"; parseEntered=dispatch_semaphore_create(0); parseRelease=dispatch_semaphore_create(0);
        parserWasMain=YES; swapJSONParser();
        __block NSUInteger parseCallbacks=0;
        request=[[MSHTTPClient sharedClient] fetchJSONURL:[NSURL URLWithString:@"https://fixture.invalid/parse"] completion:^(NSDictionary *data,NSError *error) {(void)data;(void)error;parseCallbacks++;}];
        BOOL entered=NO; end=[NSDate dateWithTimeIntervalSinceNow:2];
        while(!entered && end.timeIntervalSinceNow>0) {
            pump(0.01); entered=dispatch_semaphore_wait(parseEntered,DISPATCH_TIME_NOW)==0;
        }
        check(entered && !parserWasMain,"JSON parsing runs away from the main queue");
        [request cancel]; dispatch_semaphore_signal(parseRelease); pump(0.15);
        check(parseCallbacks==0,"cancellation during JSON parsing suppresses later completion");
        swapJSONParser();
        swapConfiguration();
        printf("%s %u HTTP transport checks; %u failures (in-memory URLProtocol only)\n",failures ? "FAIL" : "PASS",checks,failures);
        return failures ? 1 : 0;
    }
}
