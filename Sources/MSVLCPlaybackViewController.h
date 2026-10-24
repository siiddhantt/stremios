#import <UIKit/UIKit.h>
#import "MSPlaybackRouting.h"
@class MSMedia;
NS_ASSUME_NONNULL_BEGIN
/// Native controls around the bundled VideoLAN playback engine.
/// Construct only after the user has explicitly chosen Play for a source.
@interface MSVLCPlaybackViewController : UIViewController <MSPlaybackControlling>
@property(nonatomic,copy,nullable) dispatch_block_t nextEpisodeHandler;
@property(nonatomic,copy,nullable) NSString *nextEpisodeTitle;
- (instancetype)initWithMedia:(MSMedia *)media resume:(BOOL)resume;
@end
NS_ASSUME_NONNULL_END
