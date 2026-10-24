#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const MSLibraryDidChangeNotification;
@interface MSLibraryStore : NSObject
+ (instancetype)sharedStore;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (BOOL)isFavorite:(NSString *)identifier;
- (void)toggleFavorite:(NSString *)identifier;
- (NSTimeInterval)resumeFor:(NSString *)identifier duration:(NSTimeInterval)duration;
- (void)savePosition:(NSTimeInterval)seconds duration:(NSTimeInterval)duration for:(NSString *)identifier;
- (void)clearPositionFor:(NSString *)identifier;
/// Public catalog metadata only; unknown keys and playback addresses are discarded.
- (void)registerMetadata:(NSDictionary *)metadata forVideoIdentifier:(NSString *)identifier;
- (nullable NSDictionary *)recordForIdentifier:(NSString *)identifier;
- (NSArray<NSDictionary *> *)continueWatchingRecords;
- (NSArray<NSDictionary *> *)recentRecords;
- (NSArray<NSDictionary *> *)favoriteRecords;
- (NSDictionary *)playbackSelectionsForIdentifier:(NSString *)identifier;
- (void)savePlaybackSelections:(NSDictionary *)selections forIdentifier:(NSString *)identifier;
- (void)saveSourceFingerprint:(NSString *)fingerprint forIdentifier:(NSString *)identifier;
+ (NSString *)sourceFingerprintForProvider:(NSString *)provider filename:(nullable NSString *)filename name:(nullable NSString *)name detail:(nullable NSString *)detail;
- (void)removeHistoryForIdentifier:(NSString *)identifier;
- (void)clearHistory;
@end
NS_ASSUME_NONNULL_END
