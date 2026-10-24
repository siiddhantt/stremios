#import "MSArtworkCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>

static const NSUInteger MSArtworkFileLimit = 512;
@interface MSArtworkCache ()
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic) NSUInteger byteLimit, entryLimit, revision;
@property(nonatomic) NSTimeInterval maximumAge;
@property(nonatomic, strong) dispatch_queue_t ioQueue;
@end
@implementation MSArtworkCache
+ (NSString *)cacheKeyForURL:(NSURL *)URL {
    NSString *address = URL.absoluteString;
    if (!address.length || address.length > 16384) return nil;
    NSData *bytes = [address dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *key = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [key appendFormat:@"%02x", digest[i]];
    return key;
}
- (instancetype)init {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [self initWithDirectoryURL:[base URLByAppendingPathComponent:@"MiniStreamArtwork-v1" isDirectory:YES] byteLimit:64*1024*1024 maximumAge:30*24*60*60 maximumEntryBytes:2*1024*1024];
}
- (instancetype)initWithDirectoryURL:(NSURL *)directory byteLimit:(NSUInteger)limit maximumAge:(NSTimeInterval)age maximumEntryBytes:(NSUInteger)entryLimit {
    if ((self = [super init])) {
        _directory = [directory copy]; _byteLimit = MAX((NSUInteger)1, limit); _entryLimit = MAX((NSUInteger)1, MIN(entryLimit, 2*1024*1024));
        _maximumAge = MAX(1, age); _revision = 1;
        _ioQueue = dispatch_queue_create("local.ministream.artwork-disk", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        dispatch_async(_ioQueue, ^{ [self prune]; });
    }
    return self;
}
- (NSUInteger)generation { @synchronized (self) { return self.revision; } }
- (BOOL)isCurrent:(NSUInteger)revision { @synchronized (self) { return self.revision == revision; } }
- (BOOL)validKey:(NSString *)key {
    return key.length == 64 && [key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location == NSNotFound;
}
- (NSURL *)URLForKey:(NSString *)key { return [self.directory URLByAppendingPathComponent:[key stringByAppendingString:@".art"]]; }
- (BOOL)prepareDirectory {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attributes = [fm attributesOfItemAtPath:self.directory.path error:nil];
    if (attributes && ![attributes[NSFileType] isEqual:NSFileTypeDirectory]) return NO;
    NSMutableDictionary *protection = [@{NSFilePosixPermissions:@0700} mutableCopy];
#if TARGET_OS_IPHONE
    protection[NSFileProtectionKey] = NSFileProtectionComplete;
#endif
    if (!attributes && ![fm createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:protection error:nil]) return NO;
    [fm setAttributes:protection ofItemAtPath:self.directory.path error:nil];
    NSURL *directory = self.directory; [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return YES;
}
// Only our regular hash-named entries count. Invalid own entries are removed;
// unrelated files are never followed or read.
- (NSMutableArray<NSDictionary *> *)entries {
    NSMutableArray *entries = [NSMutableArray array];
    if (![self prepareDirectory]) return entries;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDate *now = [NSDate date];
    for (NSURL *URL in [fm contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if (![URL.pathExtension isEqual:@"art"] || ![self validKey:URL.lastPathComponent.stringByDeletingPathExtension]) continue;
        NSDictionary *a = [fm attributesOfItemAtPath:URL.path error:nil];
        NSUInteger bytes = [a[NSFileSize] unsignedIntegerValue];
        NSDate *created = a[NSFileCreationDate];
        if (![a[NSFileType] isEqual:NSFileTypeRegular] || !bytes || bytes > self.entryLimit || !created || [now timeIntervalSinceDate:created] > self.maximumAge) {
            [fm removeItemAtURL:URL error:nil]; continue;
        }
        [entries addObject:@{@"url":URL, @"bytes":@(bytes), @"access":a[NSFileModificationDate] ?: created}];
    }
    return entries;
}
- (NSArray<NSDictionary *> *)prune {
    NSMutableArray *entries = [self entries];
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"access"] compare:b[@"access"]]; }];
    unsigned long long total = 0; for (NSDictionary *entry in entries) total += [entry[@"bytes"] unsignedLongLongValue];
    for (NSDictionary *entry in [entries copy]) {
        if (total <= self.byteLimit && entries.count <= MSArtworkFileLimit) break;
        if ([NSFileManager.defaultManager removeItemAtURL:entry[@"url"] error:nil]) {
            total -= [entry[@"bytes"] unsignedLongLongValue]; [entries removeObjectIdenticalTo:entry];
        }
    }
    return entries;
}
- (void)readDataForKey:(NSString *)key completion:(void (^)(NSData *))completion {
    NSUInteger revision = self.generation;
    dispatch_async(self.ioQueue, ^{
        NSData *data = nil;
        if ([self isCurrent:revision] && [self validKey:key] && [self prepareDirectory]) {
            NSURL *URL = [self URLForKey:key];
            NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:URL.path error:nil];
            NSDate *created = a[NSFileCreationDate];
            NSUInteger size = [a[NSFileSize] unsignedIntegerValue];
            if ([a[NSFileType] isEqual:NSFileTypeRegular] && size && size <= self.entryLimit && created && -created.timeIntervalSinceNow <= self.maximumAge) {
                data = [NSData dataWithContentsOfURL:URL options:0 error:nil];
                if (data.length > self.entryLimit) data = nil;
                if (data) [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate date]} ofItemAtPath:URL.path error:nil];
            } else if (a) [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion([self isCurrent:revision] ? data : nil); });
    });
}
- (void)storeData:(NSData *)data forKey:(NSString *)key generation:(NSUInteger)revision completion:(void (^)(BOOL))completion {
    NSData *bytes = [data copy];
    dispatch_async(self.ioQueue, ^{
        BOOL stored = NO;
        if ([self isCurrent:revision] && [self validKey:key] && bytes.length && bytes.length <= self.entryLimit && bytes.length <= self.byteLimit && [self prepareDirectory]) {
            NSURL *URL = [self URLForKey:key];
            NSUInteger options = NSDataWritingAtomic;
#if TARGET_OS_IPHONE
            options |= NSDataWritingFileProtectionComplete;
#endif
            stored = [bytes writeToURL:URL options:options error:nil];
            if (stored) {
                NSDate *now = [NSDate date];
                [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600, NSFileCreationDate:now, NSFileModificationDate:now} ofItemAtPath:URL.path error:nil];
                [self prune];
            }
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(stored && [self isCurrent:revision]); });
    });
}
- (void)removeDataForKey:(NSString *)key generation:(NSUInteger)revision {
    dispatch_async(self.ioQueue, ^{ if ([self isCurrent:revision] && [self validKey:key]) [NSFileManager.defaultManager removeItemAtURL:[self URLForKey:key] error:nil]; });
}
- (void)clearWithCompletion:(void (^)(void))completion {
    @synchronized (self) { self.revision++; }
    dispatch_async(self.ioQueue, ^{
        [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}
- (void)storageStatsWithCompletion:(void (^)(NSDictionary<NSString *, NSNumber *> *))completion {
    dispatch_async(self.ioQueue, ^{
        NSArray *entries = [self prune]; unsigned long long total = 0;
        for (NSDictionary *entry in entries) total += [entry[@"bytes"] unsignedLongLongValue];
        NSDictionary *stats = @{@"artworkDiskBytes":@(total), @"artworkDiskFiles":@(entries.count), @"artworkDiskLimitBytes":@(self.byteLimit)};
        dispatch_async(dispatch_get_main_queue(), ^{ completion(stats); });
    });
}
@end
