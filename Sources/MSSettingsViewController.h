#import "MSSettingsComponents.h"
@class MSMedia;
NS_ASSUME_NONNULL_BEGIN
@interface MSSettingsViewController : MSSettingsTableController
- (instancetype)initWithCatalog:(NSArray<MSMedia *> *)catalog;
@end
NS_ASSUME_NONNULL_END
