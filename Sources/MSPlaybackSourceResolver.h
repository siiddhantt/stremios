#import <Foundation/Foundation.h>
#import "MSCatalogClient.h"

NS_ASSUME_NONNULL_BEGIN
@interface MSResolvedPlaybackSource : NSObject
@property(nonatomic, readonly, copy) NSURL *URL;
/// One of: mp4, hls, matroska, other. Based on bounded response bytes, not the filename.
@property(nonatomic, readonly, copy) NSString *container;
@property(nonatomic, readonly) BOOL useVLC;
@end

@interface MSPlaybackSourceResolver : NSObject
+ (instancetype)sharedResolver;
/// Invoke only after an explicit playback selection. Retains at most 4096 body bytes
/// and cancels transport after the prefix; network delivery may coalesce a larger chunk.
/// Completion is delivered once on the main queue; cancellation suppresses it.
- (id<MSCancellable>)resolveURL:(NSURL *)URL completion:(void (^)(MSResolvedPlaybackSource * _Nullable source, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
