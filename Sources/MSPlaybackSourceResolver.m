#import "MSPlaybackSourceResolver.h"
#import "MSHTTPClient.h"
#import <errno.h>
#import <stdlib.h>
#import <string.h>

static const NSUInteger MSPlaybackPrefixLimit = 4096;

static NSError *MSPlaybackSourceError(NSString *message) {
    NSString *kind = @"unsupported-address";
    if ([message containsString:@"placeholder"]) kind=@"provider-placeholder";
    else if ([message containsString:@"instead of video"]) kind=@"provider-page";
    else if ([message containsString:@"HTTP "]) kind=@"provider-http";
    else if ([message containsString:@"byte range"]) kind=@"provider-range";
    else if ([message containsString:@"empty video"]) kind=@"provider-empty";
    else if ([message containsString:@"too long"]) kind=@"timeout";
    else if ([message containsString:@"Could not reach"]) kind=@"network";
    return [NSError errorWithDomain:@"MiniStream.PlaybackSource" code:1
        userInfo:@{NSLocalizedDescriptionKey:message,@"failureKind":kind}];
}

static void MSRecordPlaybackSourceFailure(NSError *error) {
    // App-local, fixed fields only. Never persist the address, headers, response
    // body, provider credentials, or arbitrary server/error descriptions.
    if (![NSBundle.mainBundle.bundleIdentifier hasPrefix:@"local.ministream."]) return;
    NSString *kind=error.userInfo[@"failureKind"];
    if (![@[@"provider-placeholder",@"provider-page",@"provider-http",@"provider-range",@"provider-empty",@"timeout",@"network",@"unsupported-address"] containsObject:kind]) return;
    NSURL *directory=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *file=[directory URLByAppendingPathComponent:@"MiniStreamLastSourceFailure.json"];
    NSDictionary *record=@{@"schemaVersion":@1,@"stage":@"selected-source",@"kind":kind,@"recordedAt":@(NSDate.date.timeIntervalSince1970)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (file && data.length<1024) {
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        [data writeToURL:file options:NSDataWritingAtomic error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionComplete,NSFilePosixPermissions:@0600} ofItemAtPath:file.path error:nil];
        [file setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}

static BOOL MSPlaybackPlaceholderURL(NSURL *URL) {
    NSString *host = [URL.host.lowercaseString stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"."]];
    return [host isEqualToString:@"slate.elfhosted.com"];
}

static NSString *MSPlaybackHeader(NSHTTPURLResponse *response, NSString *name) {
    for (id key in response.allHeaderFields) {
        if ([key isKindOfClass:NSString.class] && [key caseInsensitiveCompare:name] == NSOrderedSame) {
            id value = response.allHeaderFields[key];
            return [value isKindOfClass:NSString.class] ? value : [value description];
        }
    }
    return nil;
}

static BOOL MSPlaybackUnsigned(NSString *text, unsigned long long *value) {
    if (!text.length || text.length > 20) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(text.UTF8String, &end, 10);
    if (errno == ERANGE || !end || *end) return NO;
    *value = parsed;
    return YES;
}

// A 206 response must describe a subset of the exact requested initial range.
static NSUInteger MSPlaybackRangeLength(NSString *header) {
    if (!header.length || header.length > 100) return 0;
    static NSRegularExpression *expression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"^bytes[ ]+0-([0-9]+)/([0-9]+|\\*)$"
            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *value = [header stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSTextCheckingResult *match = [expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    if (!match) return 0;
    unsigned long long last = 0, total = 0;
    if (!MSPlaybackUnsigned([value substringWithRange:[match rangeAtIndex:1]], &last) || last >= MSPlaybackPrefixLimit) return 0;
    NSString *totalString = [value substringWithRange:[match rangeAtIndex:2]];
    if (![totalString isEqualToString:@"*"] && (!MSPlaybackUnsigned(totalString, &total) || total <= last)) return 0;
    return (NSUInteger)last + 1;
}

static NSString *MSPlaybackContainer(NSData *data, BOOL *errorDocument) {
    *errorDocument = NO;
    const unsigned char *bytes = data.bytes;
    NSUInteger count = data.length;
    if (count >= 4 && bytes[0] == 0x1a && bytes[1] == 0x45 && bytes[2] == 0xdf && bytes[3] == 0xa3)
        return @"matroska"; // EBML family also includes WebM; both use VLC here.

    NSUInteger offset = 0;
    while (count - offset >= 8) {
        const unsigned char *p = bytes + offset;
        uint64_t size = ((uint64_t)p[0] << 24) | ((uint64_t)p[1] << 16) | ((uint64_t)p[2] << 8) | p[3];
        NSUInteger headerLength = 8;
        if (size == 1) {
            if (count - offset < 16) break;
            size = 0;
            for (NSUInteger i = 8; i < 16; i++) size = (size << 8) | p[i];
            headerLength = 16;
        }
        if (size != 0 && size < headerLength) break;
        if ((!memcmp(p + 4, "ftyp", 4) && size >= headerLength + 8) ||
            !memcmp(p + 4, "moov", 4) || !memcmp(p + 4, "mdat", 4) || !memcmp(p + 4, "styp", 4)) return @"mp4";
        if (memcmp(p + 4, "free", 4) && memcmp(p + 4, "skip", 4) && memcmp(p + 4, "wide", 4)) break;
        if (size < headerLength || size > count - offset) break;
        offset += (NSUInteger)size;
    }

    // Only decode a bounded prefix. A truncated final UTF-8 character must not
    // prevent recognizing a playlist or an error page at the beginning.
    NSString *text = nil;
    for (NSUInteger trim = 0; trim <= 3 && trim < count; trim++) {
        text = [[NSString alloc] initWithBytes:bytes length:count - trim encoding:NSUTF8StringEncoding];
        if (text) break;
    }
    if (!text && count >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff)))
        text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    NSMutableCharacterSet *space = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
    [space addCharactersInString:@"\ufeff"];
    NSString *prefix = [text stringByTrimmingCharactersInSet:space];
    if ([prefix hasPrefix:@"#EXTM3U"] && (prefix.length == 7 ||
        [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[prefix characterAtIndex:7]])) return @"hls";
    if ([prefix hasPrefix:@"<"] || [prefix hasPrefix:@"{"] || [prefix hasPrefix:@"["]) *errorDocument = YES;
    return @"other";
}

@interface MSResolvedPlaybackSource ()
@property(nonatomic, readwrite, copy) NSURL *URL;
@property(nonatomic, readwrite, copy) NSString *container;
@property(nonatomic, readwrite) BOOL useVLC;
@end
@implementation MSResolvedPlaybackSource
@end

@interface MSPlaybackResolveRequest : NSObject <MSCancellable, NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, copy) NSURL *finalURL;
@property(nonatomic, copy) void (^completion)(MSResolvedPlaybackSource *, NSError *);
@property(nonatomic) NSUInteger redirects, partialLength;
@property(nonatomic) BOOL cancelled, finished, receivedResponse;
- (void)finish:(NSError *)error;
@end

@implementation MSPlaybackResolveRequest
- (void)cancel {
    NSURLSession *session;
    @synchronized (self) {
        self.cancelled = YES; self.finished = YES; self.completion = nil; self.body = nil;
        session = self.session; self.session = nil;
    }
    [session invalidateAndCancel];
}
- (void)finish:(NSError *)error {
    NSURLSession *session;
    MSResolvedPlaybackSource *source = nil;
    @synchronized (self) {
        if (self.finished || self.cancelled) return;
        self.finished = YES;
        if (!error && (!self.receivedResponse || !self.body.length))
            error = MSPlaybackSourceError(@"The provider returned an empty video response. Choose another source.");
        if (!error) {
            BOOL errorDocument = NO;
            NSString *container = MSPlaybackContainer(self.body, &errorDocument);
            if (errorDocument) error = MSPlaybackSourceError(@"The provider returned a status page instead of video. Try again shortly or choose another source.");
            else {
                source = [MSResolvedPlaybackSource new]; source.URL = self.finalURL; source.container = container;
                source.useVLC = [container isEqualToString:@"matroska"] || [container isEqualToString:@"other"];
            }
        }
        self.body = nil; session = self.session; self.session = nil;
    }
    // Always cancel rather than draining a 200 response that ignored Range.
    [session invalidateAndCancel];
    if (error) MSRecordPlaybackSourceFailure(error);
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^callback)(MSResolvedPlaybackSource *, NSError *) = nil;
        @synchronized (self) {
            if (!self.cancelled) callback = self.completion;
            self.completion = nil;
        }
        if (callback) callback(source, error);
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    (void)session; (void)task;
    NSError *failure = nil;
    @synchronized (self) {
        if (self.finished || self.cancelled) { handler(NSURLSessionResponseCancel); return; }
        if (![response isKindOfClass:NSHTTPURLResponse.class] || !MSIsSafeRemoteURL(response.URL))
            failure = MSPlaybackSourceError(@"The provider returned an unsupported video address.");
        else if (MSPlaybackPlaceholderURL(response.URL))
            failure = MSPlaybackSourceError(@"The provider returned a placeholder clip, not this title. Try again shortly or choose another source.");
        else {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSInteger status = http.statusCode;
            if (status != 200 && status != 206)
                failure = MSPlaybackSourceError([NSString stringWithFormat:@"The provider returned HTTP %ld. Choose another source or try again later.", (long)status]);
            else if (status == 206) {
                self.partialLength = MSPlaybackRangeLength(MSPlaybackHeader(http, @"Content-Range"));
                if (!self.partialLength || (response.expectedContentLength >= 0 && response.expectedContentLength != (int64_t)self.partialLength))
                    failure = MSPlaybackSourceError(@"The provider returned an invalid video byte range. Choose another source.");
            }
            NSString *mime = response.MIMEType.lowercaseString;
            if (!failure && ([mime containsString:@"html"] || [mime containsString:@"json"] ||
                [mime containsString:@"xml"] || [mime hasPrefix:@"image/"]))
                failure = MSPlaybackSourceError(@"The provider returned a status page instead of video. Try again shortly or choose another source.");
            if (!failure) { self.finalURL = response.URL; self.receivedResponse = YES; }
        }
    }
    handler(failure ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
    if (failure) [self finish:failure];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session; (void)task;
    BOOL enough = NO, inconsistent = NO;
    @synchronized (self) {
        if (self.finished || self.cancelled) return;
        NSUInteger remaining = MSPlaybackPrefixLimit - self.body.length;
        if (self.partialLength && data.length > self.partialLength - self.body.length) inconsistent = YES;
        else {
            NSUInteger amount = MIN(remaining, data.length);
            if (amount) [self.body appendBytes:data.bytes length:amount];
            enough = self.body.length == MSPlaybackPrefixLimit ||
                (self.partialLength && self.body.length == self.partialLength);
        }
    }
    if (inconsistent) [self finish:MSPlaybackSourceError(@"The provider returned an inconsistent video byte range. Choose another source.")];
    else if (enough) [self finish:nil];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    (void)session; (void)task; (void)response;
    NSError *failure = nil;
    @synchronized (self) {
        if (self.finished || self.cancelled) { handler(nil); return; }
        if (++self.redirects > 5 || !MSIsSafeRemoteURL(request.URL))
            failure = MSPlaybackSourceError(@"The provider redirected to an unsupported video address.");
        else if (MSPlaybackPlaceholderURL(request.URL))
            failure = MSPlaybackSourceError(@"The provider returned a placeholder clip, not this title. Try again shortly or choose another source.");
    }
    if (failure) { handler(nil); [self finish:failure]; return; }
    NSMutableURLRequest *next = [NSMutableURLRequest requestWithURL:request.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    next.HTTPMethod = @"GET"; next.HTTPShouldHandleCookies = NO;
    [next setValue:@"bytes=0-4095" forHTTPHeaderField:@"Range"];
    [next setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [next setValue:@"MiniStream/0.6" forHTTPHeaderField:@"User-Agent"];
    handler(next);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session; (void)task;
    NSError *failure = nil;
    @synchronized (self) {
        if (self.finished || self.cancelled) return;
        if (error) failure = MSPlaybackSourceError(error.code == NSURLErrorTimedOut ?
            @"The video source took too long to respond. Try again or choose another source." :
            @"Could not reach the video source. Check Wi-Fi or choose another source.");
        else if (self.partialLength && self.body.length != self.partialLength)
            failure = MSPlaybackSourceError(@"The provider returned an incomplete video byte range. Choose another source.");
    }
    [self finish:failure];
}
@end

@implementation MSPlaybackSourceResolver
+ (instancetype)sharedResolver {
    static MSPlaybackSourceResolver *resolver;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ resolver = [self new]; });
    return resolver;
}
- (id<MSCancellable>)resolveURL:(NSURL *)URL completion:(void (^)(MSResolvedPlaybackSource *, NSError *))completion {
    MSPlaybackResolveRequest *request = [MSPlaybackResolveRequest new];
    request.body = [NSMutableData dataWithCapacity:MSPlaybackPrefixLimit]; request.completion = completion;
    if (!MSIsSafeRemoteURL(URL)) {
        [request finish:MSPlaybackSourceError(@"Only public HTTPS video addresses without embedded logins are supported.")]; return request;
    }
    if (MSPlaybackPlaceholderURL(URL)) {
        [request finish:MSPlaybackSourceError(@"The provider returned a placeholder clip, not this title. Try again shortly or choose another source.")]; return request;
    }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil; config.HTTPShouldSetCookies = NO;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    config.URLCredentialStorage = nil; config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30;
    config.HTTPMaximumConnectionsPerHost = 1;
    request.session = [NSURLSession sessionWithConfiguration:config delegate:request delegateQueue:nil];
    NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    http.HTTPMethod = @"GET"; http.HTTPShouldHandleCookies = NO;
    [http setValue:@"bytes=0-4095" forHTTPHeaderField:@"Range"];
    [http setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [http setValue:@"MiniStream/0.6" forHTTPHeaderField:@"User-Agent"];
    [[request.session dataTaskWithRequest:http] resume];
    return request;
}
@end
