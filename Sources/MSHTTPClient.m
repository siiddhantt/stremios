#import "MSHTTPClient.h"
#import <arpa/inet.h>
BOOL MSIsSafeRemoteURL(NSURL *url) {
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || url.user || url.password || url.absoluteString.length > 16384) return NO;
    NSString *host = [url.host.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]];
    if ([host isEqualToString:@"localhost"] || [host hasSuffix:@".localhost"] || [host hasSuffix:@".local"]) return NO;
    // No LAN helper is configured in this slice. Reject literal local destinations.
    struct in_addr address;
    if (inet_aton(host.UTF8String, &address) == 1) {
        uint32_t ip = ntohl(address.s_addr);
        if ((ip >> 24) == 0 || (ip >> 24) == 10 || (ip >> 24) == 127 || (ip >> 16) == 0xa9fe || (ip >> 20) == 0xac1 || (ip >> 16) == 0xc0a8 || (ip >> 22) == 0x191 || (ip >> 28) >= 14) return NO;
    }
    if ([host containsString:@":"]) return NO; // literal IPv6 helpers unsupported for now
    return YES;
}
NSError *MSNetworkError(NSString *message) { return [NSError errorWithDomain:@"MiniStream.Network" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }

@interface MSHTTPRequest : NSObject <MSCancellable, NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,copy) void (^completion)(NSData *, NSError *);
@property(nonatomic) NSUInteger limit, redirects;
@property(nonatomic) BOOL cancelled, finished;
@property(nonatomic,strong) NSError *failure;
@end
@implementation MSHTTPRequest
- (void)cancel {
    @synchronized (self) { self.cancelled = YES; self.completion = nil; }
    [self.session invalidateAndCancel]; self.session = nil;
}
- (void)finish:(NSError *)error {
    @synchronized (self) { if (self.finished) return; self.finished = YES; }
    NSData *body = error ? nil : [self.body copy]; self.body = nil;
    [self.session finishTasksAndInvalidate]; self.session = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^callback)(NSData *, NSError *) = nil;
        @synchronized (self) { if (!self.cancelled) callback = self.completion; self.completion = nil; }
        if (callback) callback(body, error);
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    (void)session; (void)task;
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    if (status < 200 || status >= 300) self.failure = MSNetworkError([NSString stringWithFormat:@"The service returned HTTP %ld. Try again later.", (long)status]);
    else if (response.expectedContentLength > (int64_t)self.limit) self.failure = MSNetworkError(@"This response is larger than the iPad's safe loading limit.");
    handler(self.failure ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if (data.length > self.limit - self.body.length) { self.failure = MSNetworkError(@"This response is larger than the iPad's safe loading limit."); [task cancel]; }
    else [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    (void)session; (void)task; (void)response;
    if (++self.redirects > 5 || !MSIsSafeRemoteURL(request.URL)) { self.failure = MSNetworkError(@"The service redirected to an unsupported address."); handler(nil); return; }
    NSMutableURLRequest *clean = [NSMutableURLRequest requestWithURL:request.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [clean setValue:@"MiniStream/0.2" forHTTPHeaderField:@"User-Agent"]; handler(clean);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session; (void)task;
    NSString *message = error.code == NSURLErrorTimedOut ? @"The service took too long to respond. Try again." : @"Could not reach the service. Check Wi-Fi and try again.";
    [self finish:self.failure ?: (error ? MSNetworkError(message) : nil)];
}
@end

@interface MSJSONRequest : NSObject <MSCancellable>
@property(atomic) BOOL cancelled;
@property(atomic,strong) id<MSCancellable> request;
@end
@implementation MSJSONRequest
- (void)cancel { self.cancelled = YES; [self.request cancel]; self.request = nil; }
@end

@implementation MSHTTPClient
+ (instancetype)sharedClient { static MSHTTPClient *client; static dispatch_once_t once; dispatch_once(&once, ^{ client = [self new]; }); return client; }
- (id<MSCancellable>)fetchDataURL:(NSURL *)url maximumBytes:(NSUInteger)limit completion:(void (^)(NSData *, NSError *))completion {
    MSHTTPRequest *request = [MSHTTPRequest new]; request.completion = completion; request.limit = MIN(limit, 8 * 1024 * 1024); request.body = [NSMutableData data];
    if (!MSIsSafeRemoteURL(url)) { [request finish:MSNetworkError(@"Only public HTTPS addresses without embedded logins are supported.")]; return request; }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil; config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever; config.HTTPShouldSetCookies = NO;
    config.URLCredentialStorage = nil; config.URLCache = nil; config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30; config.HTTPMaximumConnectionsPerHost = 2;
    request.session = [NSURLSession sessionWithConfiguration:config delegate:request delegateQueue:nil];
    NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:url]; [http setValue:@"MiniStream/0.2" forHTTPHeaderField:@"User-Agent"];
    [[request.session dataTaskWithRequest:http] resume]; return request;
}
- (id<MSCancellable>)fetchJSONURL:(NSURL *)url completion:(void (^)(NSDictionary *, NSError *))completion {
    MSJSONRequest *token = [MSJSONRequest new];
    token.request = [self fetchDataURL:url maximumBytes:4 * 1024 * 1024 completion:^(NSData *data, NSError *error) {
        if (token.cancelled) return;
        token.request = nil;
        if (error) { completion(nil, error); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (token.cancelled) return;
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            BOOL valid = [object isKindOfClass:NSDictionary.class];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!token.cancelled) completion(valid ? object : nil, valid ? nil : MSNetworkError(@"The service did not return valid add-on data."));
            });
        });
    }];
    return token;
}
@end
