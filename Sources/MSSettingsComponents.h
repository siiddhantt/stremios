#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface MSSettingsCell : UITableViewCell
@property(nonatomic,readonly) UILabel *nameLabel;
@property(nonatomic,readonly) UILabel *valueLabel;
- (void)position:(NSInteger)row count:(NSInteger)count disclosure:(BOOL)disclosure;
@end
@interface MSSettingsSliderCell : UITableViewCell
@property(nonatomic,readonly) UILabel *nameLabel,*valueLabel;
@property(nonatomic,readonly) UISlider *slider;
@end
@interface MSSettingsTableController : UITableViewController
@end
NS_ASSUME_NONNULL_END
