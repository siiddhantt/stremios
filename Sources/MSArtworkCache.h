#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Encoded artwork only. File names contain a SHA-256 digest, never a URL.
// All I/O runs on a serial utility queue; completions arrive on main.
@interface MSArtworkCache : NSObject
@property(nonatomic, readonly) NSUInteger generation;
+ (nullable NSString *)cacheKeyForURL:(NSURL *)URL;
- (instancetype)init;
// Injectable bounds/directory support isolated cache tests without touching app data.
- (instancetype)initWithDirectoryURL:(NSURL *)directory byteLimit:(NSUInteger)limit maximumAge:(NSTimeInterval)age maximumEntryBytes:(NSUInteger)entryLimit NS_DESIGNATED_INITIALIZER;
- (void)readDataForKey:(NSString *)key completion:(void (^)(NSData * _Nullable data))completion;
- (void)storeData:(NSData *)data forKey:(NSString *)key generation:(NSUInteger)generation completion:(nullable void (^)(BOOL stored))completion;
- (void)removeDataForKey:(NSString *)key generation:(NSUInteger)generation;
- (void)clearWithCompletion:(nullable void (^)(void))completion;
- (void)storageStatsWithCompletion:(void (^)(NSDictionary<NSString *, NSNumber *> *stats))completion;
@end
NS_ASSUME_NONNULL_END
