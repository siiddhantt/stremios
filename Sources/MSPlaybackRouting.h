#import <UIKit/UIKit.h>
@class MSMedia;
NS_ASSUME_NONNULL_BEGIN
@protocol MSPlaybackControlling <NSObject>
@property(nonatomic,copy,nullable) dispatch_block_t nextEpisodeHandler;
@property(nonatomic,copy,nullable) NSString *nextEpisodeTitle;
@end
/// One shared interface; HLS uses Apple streaming to avoid a VLC 3 cancellation
/// deadlock on iOS 12. Other supported containers use the pinned VideoLAN engine.
FOUNDATION_EXPORT UIViewController<MSPlaybackControlling> *MSMakePlaybackController(MSMedia *media, NSString *container, BOOL resume);
NS_ASSUME_NONNULL_END
