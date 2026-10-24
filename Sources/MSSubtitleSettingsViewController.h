#import "MSSettingsComponents.h"
@class MSPlaybackPreferences;
NS_ASSUME_NONNULL_BEGIN
@interface MSSubtitleSettingsViewController : MSSettingsTableController
- (instancetype)init;
- (instancetype)initWithPreferences:(MSPlaybackPreferences *)preferences;
@end
NS_ASSUME_NONNULL_END
