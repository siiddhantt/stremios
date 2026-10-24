#import <UIKit/UIKit.h>
#import "MSPlaybackRouting.h"
@class MSMedia;
NS_ASSUME_NONNULL_BEGIN
@interface MSPlaybackViewController : UIViewController <MSPlaybackControlling>
@property (nonatomic, copy, nullable) dispatch_block_t nextEpisodeHandler;
@property (nonatomic, copy, nullable) NSString *nextEpisodeTitle;
- (instancetype)initWithMedia:(MSMedia *)media resume:(BOOL)resume;
@end
NS_ASSUME_NONNULL_END
