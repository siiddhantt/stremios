#import <UIKit/UIKit.h>
#import "MSCatalogClient.h"
NS_ASSUME_NONNULL_BEGIN
@interface MSImageLoader : NSObject
+ (instancetype)sharedLoader;
// Call on main. Main-queue completion; cancellation suppresses delivery.
// Same URL/pixel-size requests share work. Encoded artwork is cached on disk.
- (id<MSCancellable>)loadURL:(NSURL *)URL maxPixelSize:(NSUInteger)size completion:(void (^)(UIImage * _Nullable image, NSError * _Nullable error))completion;
// Main-queue API/completion. Cancels existing requests and invalidates their
// pending disk writes before clearing memory and disk artwork. No video data.
- (void)clearCacheWithCompletion:(nullable void (^)(void))completion;
// Disk scan is off-main; completion on main. Metrics are numeric, session-only,
// contain no URLs, and measure work rather than claiming scrolling performance.
- (void)storageStatsWithCompletion:(void (^)(NSDictionary<NSString *, NSNumber *> *stats))completion;
@end
NS_ASSUME_NONNULL_END
