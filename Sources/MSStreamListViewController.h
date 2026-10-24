#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@class MSMetadata, MSEpisode;
@interface MSStreamListViewController : UITableViewController
- (instancetype)initWithMetadata:(MSMetadata *)metadata episode:(MSEpisode * _Nullable)episode;
// Preserves a saved movie video ID when a provider changes its metadata hint.
- (instancetype)initWithMetadata:(MSMetadata *)metadata episode:(MSEpisode * _Nullable)episode videoIdentifier:(NSString * _Nullable)videoIdentifier;
/// One explicit Resume intent. Call before pushing this controller, or while it
/// is visible. Fetches fresh sources and opens only an unambiguous saved file.
/// Ordinary browsing, refresh, background return and missing matches never play.
- (void)requestResumeFromLastSource;
@end

NS_ASSUME_NONNULL_END
