#import "MSTorBoxClient.h"
#import <CoreFoundation/CoreFoundation.h>

static NSError *MSTorBoxError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"MiniStream.TorBoxSetup" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

@interface MSTorBoxRequest : NSObject <MSCancellable, NSURLSessionDataDelegate>
@property(atomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
@property(nonatomic, strong) NSError *failure;
@property(nonatomic) NSUInteger limit;
@property(nonatomic) BOOL cancelled, finished;
- (void)finish:(NSError *)error;
@end

@implementation MSTorBoxRequest
- (void)cancel {
    @synchronized(self) { self.cancelled=YES; self.completion=nil; self.body=nil; }
    [self.session invalidateAndCancel]; self.session=nil;
}
- (void)finish:(NSError *)error {
    NSData *data=nil;
    @synchronized(self) {
        if (self.finished) return;
        self.finished=YES; data=error ? nil : [self.body copy]; self.body=nil;
    }
    [self.session finishTasksAndInvalidate]; self.session=nil;
    // Delegate callbacks run off-main. Keep parsing/account response data here.
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!error && ![value isKindOfClass:NSDictionary.class]) error=MSTorBoxError(5,@"The service returned an invalid response. Try again later.");
    NSDictionary *document=error ? nil : value;
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^callback)(NSDictionary *,NSError *)=nil;
        @synchronized(self) { if (!self.cancelled) callback=self.completion; self.completion=nil; }
        if (callback) callback(document,error);
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    (void)session; (void)task;
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    @synchronized(self) {
        if (self.cancelled || self.finished) { handler(NSURLSessionResponseCancel); return; }
        if (status==401 || status==403) self.failure=MSTorBoxError(2,@"The service rejected this key. Check it in your TorBox account and try again.");
        else if (status==429) self.failure=MSTorBoxError(3,@"The service is temporarily rate limited. Wait before trying again.");
        else if (status<200 || status>=300) self.failure=MSTorBoxError(4,@"The service is unavailable. Try again later.");
        else if (response.expectedContentLength>(int64_t)self.limit) self.failure=MSTorBoxError(5,@"The service response exceeds the setup loading limit.");
        handler(self.failure ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    @synchronized(self) {
        if (self.cancelled || self.finished || self.failure) return;
        if (self.body.length>self.limit || data.length>self.limit-self.body.length) {
            self.failure=MSTorBoxError(5,@"The service response exceeds the setup loading limit."); [task cancel];
        } else [self.body appendData:data];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    (void)session; (void)task; (void)response; (void)request;
    // Even a same-host redirect is unnecessary for these fixed endpoints.
    // Never forward the Bearer header or a configured URL to a new destination.
    @synchronized(self) { self.failure=MSTorBoxError(6,@"The service redirected setup. No credentials were forwarded. Try again later."); }
    handler(nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session; (void)task;
    NSError *safe=nil;
    @synchronized(self) { safe=self.failure; }
    if (!safe && error) safe=MSTorBoxError(7,@"Setup could not reach the service. Check your connection and try again.");
    [self finish:safe];
}
@end

@implementation MSTorBoxClient
+ (NSString *)normalizedAPIKey:(NSString *)input error:(NSError **)error {
    NSString *key=[input isKindOfClass:NSString.class] ? [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    if (key.length<8 || key.length>512 || [key rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) {
        if (error) *error=MSTorBoxError(1,@"Paste your TorBox API key only, without a link or spaces."); return nil;
    }
    return key;
}
+ (NSURL *)torrentioManifestURLForAPIKey:(NSString *)input error:(NSError **)error {
    NSString *key=[self normalizedAPIKey:input error:error]; if (!key) return nil;
    // Matches the official configure page's configMap/generateLink format:
    // https://torrentio.strem.fun/configure (verified 2026-10-25).
    // Hide uncached download links and the service's personal-download catalog.
    NSURLComponents *parts=[NSURLComponents componentsWithString:@"https://torrentio.strem.fun"];
    parts.path=[NSString stringWithFormat:@"/debridoptions=nodownloadlinks,nocatalog|torbox=%@/manifest.json",key];
    return parts.URL;
}
+ (id<MSCancellable>)requestURL:(NSURL *)URL bearer:(NSString *)key limit:(NSUInteger)limit completion:(void (^)(NSDictionary *,NSError *))completion {
    MSTorBoxRequest *operation=[MSTorBoxRequest new]; operation.body=[NSMutableData data]; operation.limit=limit; operation.completion=completion;
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPCookieStorage=nil; configuration.HTTPShouldSetCookies=NO; configuration.HTTPCookieAcceptPolicy=NSHTTPCookieAcceptPolicyNever;
    configuration.URLCredentialStorage=nil; configuration.URLCache=nil; configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest=12; configuration.timeoutIntervalForResource=20; configuration.HTTPMaximumConnectionsPerHost=1;
    operation.session=[NSURLSession sessionWithConfiguration:configuration delegate:operation delegateQueue:nil];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:URL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"MiniStream" forHTTPHeaderField:@"User-Agent"];
    if (key) [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [[operation.session dataTaskWithRequest:request] resume]; return operation;
}
+ (id<MSCancellable>)invalidOperation:(NSError *)error completion:(void (^)(NSDictionary *,NSError *))completion {
    MSTorBoxRequest *operation=[MSTorBoxRequest new]; operation.completion=completion;
    [operation finish:error]; return operation;
}
+ (id<MSCancellable>)validateAPIKey:(NSString *)input completion:(void (^)(NSError *))completion {
    NSError *error=nil; NSString *key=[self normalizedAPIKey:input error:&error];
    void (^parsed)(NSDictionary *,NSError *)=^(NSDictionary *document,NSError *failure) {
        if (!failure) {
            id success=document[@"success"];
            BOOL accepted=[success isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)success)==CFBooleanGetTypeID() && [success boolValue];
            if (!accepted || ![document[@"data"] isKindOfClass:NSDictionary.class]) failure=MSTorBoxError(2,@"TorBox did not validate this key. Check it in your account and try again.");
        }
        completion(failure);
    };
    if (!key) return [self invalidOperation:error completion:parsed];
    // Official TorBox API: https://api.torbox.app/docs#/user/get_user_v1_api_user_me_get
    return [self requestURL:[NSURL URLWithString:@"https://api.torbox.app/v1/api/user/me?settings=false"] bearer:key limit:64*1024 completion:parsed];
}
+ (id<MSCancellable>)fetchTorrentioManifestWithAPIKey:(NSString *)key completion:(void (^)(NSDictionary *,NSURL *,NSError *))completion {
    NSError *error=nil; NSURL *URL=[self torrentioManifestURLForAPIKey:key error:&error];
    void (^parsed)(NSDictionary *,NSError *)=^(NSDictionary *document,NSError *failure) { completion(document,failure ? nil : URL,failure); };
    if (!URL) return [self invalidOperation:error completion:parsed];
    return [self requestURL:URL bearer:nil limit:256*1024 completion:parsed];
}
@end
