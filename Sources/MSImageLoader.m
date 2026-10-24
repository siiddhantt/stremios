#import "MSImageLoader.h"
#import "MSArtworkCache.h"
#import "MSHTTPClient.h"
#import "MSWebPImageDecoder.h"
#import <ImageIO/ImageIO.h>

static const NSUInteger MSPosterByteLimit = 2 * 1024 * 1024;
static NSError *MSPosterError(NSInteger code) {
    return [NSError errorWithDomain:@"MiniStreamPoster" code:code userInfo:@{NSLocalizedDescriptionKey:@"The poster could not be loaded."}];
}
@class MSPosterJob;
@interface MSPosterSubscription : NSObject <MSCancellable>
@property(nonatomic, weak) MSImageLoader *loader;
@property(nonatomic, weak) MSPosterJob *job;
@property(atomic) BOOL cancelled;
@property(nonatomic, copy) void (^completion)(UIImage *, NSError *);
@end
@interface MSPosterJob : NSObject
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, copy) NSString *key, *diskKey;
@property(nonatomic) NSUInteger pixelSize, generation, diskGeneration;
@property(nonatomic, strong) NSMutableArray<MSPosterSubscription *> *subscribers;
@property(nonatomic, strong) id<MSCancellable> transport;
@property(atomic) BOOL cancelled;
@property(nonatomic) BOOL finished;
@end
@implementation MSPosterJob
@end
@interface MSImageLoader ()
@property(nonatomic, strong) NSCache *cache;
@property(nonatomic, strong) MSArtworkCache *diskCache;
@property(nonatomic, strong) NSMutableDictionary<NSString *, MSPosterJob *> *jobs;
@property(nonatomic, strong) NSMutableArray<MSPosterJob *> *pending, *active;
@property(nonatomic, strong) NSOperationQueue *decodeQueue;
@property(nonatomic) NSUInteger generation, memoryHits, diskHits, networkFetches, coalescedRequests, decodeCount, maxDecodedPixelCount;
@property(nonatomic) double decodeMilliseconds;
- (void)cancelSubscription:(MSPosterSubscription *)subscription;
- (void)finishJob:(MSPosterJob *)job image:(nullable UIImage *)image error:(nullable NSError *)error;
@end
@implementation MSPosterSubscription
- (void)cancel {
    self.cancelled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self.loader cancelSubscription:self]; });
}
@end

@implementation MSImageLoader
+ (instancetype)sharedLoader { static MSImageLoader *loader; static dispatch_once_t once; dispatch_once(&once, ^{ loader = [MSImageLoader new]; }); return loader; }
- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSCache new]; _cache.totalCostLimit = 12*1024*1024; _cache.countLimit = 60;
        _diskCache = [MSArtworkCache new]; _jobs = [NSMutableDictionary dictionary];
        _pending = [NSMutableArray array]; _active = [NSMutableArray array]; _generation = 1;
        _decodeQueue = [NSOperationQueue new]; _decodeQueue.maxConcurrentOperationCount = 2; _decodeQueue.qualityOfService = NSQualityOfServiceUtility;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(memoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}
- (BOOL)isCurrent:(MSPosterJob *)job { return !job.cancelled && !job.finished && job.generation == self.generation && self.jobs[job.key] == job; }
- (id<MSCancellable>)loadURL:(NSURL *)URL maxPixelSize:(NSUInteger)size completion:(void (^)(UIImage *, NSError *))completion {
    NSAssert(NSThread.isMainThread, @"Artwork requests must start on main.");
    MSPosterSubscription *subscription = [MSPosterSubscription new]; subscription.loader = self; subscription.completion = completion;
    NSUInteger revision = self.generation;
    if (!MSIsSafeRemoteURL(URL)) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (!subscription.cancelled && revision == self.generation) completion(nil, MSPosterError(1)); subscription.completion = nil; });
        return subscription;
    }
    NSUInteger pixels = MIN(MAX(size, 80), 1024);
    NSString *diskKey = [MSArtworkCache cacheKeyForURL:URL];
    NSString *key = [NSString stringWithFormat:@"%@|%lu", diskKey, (unsigned long)pixels];
    UIImage *cached = [self.cache objectForKey:key];
    if (cached) {
        self.memoryHits++;
        dispatch_async(dispatch_get_main_queue(), ^{ if (!subscription.cancelled && revision == self.generation) completion(cached, nil); subscription.completion = nil; });
        return subscription;
    }
    MSPosterJob *job = self.jobs[key];
    if (job) self.coalescedRequests++;
    else {
        job = [MSPosterJob new]; job.URL = URL; job.key = key; job.diskKey = diskKey; job.pixelSize = pixels;
        job.generation = revision; job.diskGeneration = self.diskCache.generation;
        job.subscribers = [NSMutableArray array]; self.jobs[key] = job; [self.pending addObject:job];
    }
    subscription.job = job; [job.subscribers addObject:subscription]; [self startPending];
    return subscription;
}
- (void)startPending {
    while (self.active.count < 2 && self.pending.count) {
        MSPosterJob *job = self.pending.firstObject; [self.pending removeObjectAtIndex:0];
        if (![self isCurrent:job]) continue;
        [self.active addObject:job];
        [self.diskCache readDataForKey:job.diskKey completion:^(NSData *data) {
            if (![self isCurrent:job]) return;
            if (data.length) { self.diskHits++; [self decodeData:data job:job fromDisk:YES]; }
            else [self fetchJob:job];
        }];
    }
}
- (void)fetchJob:(MSPosterJob *)job {
    if (![self isCurrent:job]) return;
    self.networkFetches++;
    job.transport = [MSHTTPClient.sharedClient fetchDataURL:job.URL maximumBytes:MSPosterByteLimit completion:^(NSData *bytes, NSError *error) {
        if (![self isCurrent:job]) return;
        job.transport = nil;
        if (error || !bytes.length || bytes.length > MSPosterByteLimit) { [self finishJob:job image:nil error:MSPosterError(2)]; return; }
        [self decodeData:bytes job:job fromDisk:NO];
    }];
}
- (void)decodeData:(NSData *)bytes job:(MSPosterJob *)job fromDisk:(BOOL)fromDisk {
    [self.decodeQueue addOperationWithBlock:^{
        @autoreleasepool {
            UIImage *image = nil; double began = NSProcessInfo.processInfo.systemUptime;
            if (!job.cancelled) {
                CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
                if (source) {
                    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
                    double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
                    double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
                    if (width > 0 && height > 0 && width <= 16000000.0/height) {
                        NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
                            (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES,
                            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@(job.pixelSize)};
                        CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
                        if (thumbnail) { image = [UIImage imageWithCGImage:thumbnail]; CGImageRelease(thumbnail); }
                    }
                    CFRelease(source);
                }
                if (!image && bytes.length >= 12 && memcmp(bytes.bytes, "RIFF", 4) == 0 && memcmp((const char *)bytes.bytes+8, "WEBP", 4) == 0) image = MSDecodeWebPThumbnail(bytes, job.pixelSize);
            }
            if (image && (CGImageGetWidth(image.CGImage) > job.pixelSize || CGImageGetHeight(image.CGImage) > job.pixelSize)) image = nil;
            double elapsed = (NSProcessInfo.processInfo.systemUptime-began)*1000;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self isCurrent:job]) return;
                self.decodeCount++; self.decodeMilliseconds += elapsed;
                if (image) {
                    NSUInteger count = CGImageGetWidth(image.CGImage)*CGImageGetHeight(image.CGImage);
                    self.maxDecodedPixelCount = MAX(self.maxDecodedPixelCount, count);
                    if (!fromDisk) [self.diskCache storeData:bytes forKey:job.diskKey generation:job.diskGeneration completion:nil];
                    [self finishJob:job image:image error:nil];
                } else if (fromDisk) {
                    [self.diskCache removeDataForKey:job.diskKey generation:job.diskGeneration]; [self fetchJob:job];
                } else [self finishJob:job image:nil error:MSPosterError(3)];
            });
        }
    }];
}
- (void)finishJob:(MSPosterJob *)job image:(UIImage *)image error:(NSError *)error {
    if (job.finished) return;
    BOOL deliver = [self isCurrent:job]; job.finished = YES;
    [job.transport cancel]; job.transport = nil;
    [self.pending removeObjectIdenticalTo:job]; [self.active removeObjectIdenticalTo:job];
    if (self.jobs[job.key] == job) [self.jobs removeObjectForKey:job.key];
    if (image && deliver) [self.cache setObject:image forKey:job.key cost:CGImageGetBytesPerRow(image.CGImage)*CGImageGetHeight(image.CGImage)];
    NSArray *subscribers = [job.subscribers copy]; [job.subscribers removeAllObjects];
    for (MSPosterSubscription *subscription in subscribers) {
        void (^callback)(UIImage *, NSError *) = subscription.completion; subscription.completion = nil; subscription.job = nil;
        if (deliver && job.generation == self.generation && !subscription.cancelled && callback) callback(image, error);
    }
    [self startPending];
}
- (void)cancelSubscription:(MSPosterSubscription *)subscription {
    subscription.completion = nil; MSPosterJob *job = subscription.job; subscription.job = nil;
    if (!job || job.finished) return;
    [job.subscribers removeObjectIdenticalTo:subscription];
    BOOL needed = NO; for (MSPosterSubscription *other in job.subscribers) if (!other.cancelled) { needed = YES; break; }
    if (!needed) { job.cancelled = YES; [self finishJob:job image:nil error:nil]; }
}
- (void)cancelAll {
    self.generation++;
    NSArray *jobs = self.jobs.allValues;
    for (MSPosterJob *job in jobs) { job.cancelled = YES; for (MSPosterSubscription *subscription in job.subscribers) subscription.cancelled = YES; }
    for (MSPosterJob *job in jobs) [self finishJob:job image:nil error:nil];
    [self.cache removeAllObjects];
}
- (void)clearCacheWithCompletion:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"Artwork cache changes must start on main.");
    [self cancelAll]; [self.diskCache clearWithCompletion:completion];
}
- (void)storageStatsWithCompletion:(void (^)(NSDictionary<NSString *, NSNumber *> *))completion {
    NSAssert(NSThread.isMainThread, @"Artwork stats must start on main.");
    [self.diskCache storageStatsWithCompletion:^(NSDictionary *disk) {
        NSMutableDictionary *stats = [disk mutableCopy];
        [stats addEntriesFromDictionary:@{@"memoryHits":@(self.memoryHits), @"diskHits":@(self.diskHits), @"networkFetches":@(self.networkFetches), @"coalescedRequests":@(self.coalescedRequests), @"decodeCount":@(self.decodeCount), @"decodeMilliseconds":@(self.decodeMilliseconds), @"maxDecodedPixelCount":@(self.maxDecodedPixelCount), @"decodedMemoryLimitBytes":@(12*1024*1024), @"maximumThumbnailDimension":@1024, @"activeRequests":@(self.active.count), @"pendingRequests":@(self.pending.count)}];
        completion(stats);
    }];
}
- (void)memoryWarning:(NSNotification *)notification { (void)notification; [self.cache removeAllObjects]; }
- (void)background:(NSNotification *)notification { (void)notification; [self cancelAll]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
