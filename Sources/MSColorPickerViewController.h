#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger,MSColorPickerPurpose) { MSColorPickerPurposeAccent, MSColorPickerPurposeSubtitle };
/// UIKit-only, local draft. Applies once; Back discards. No timer or network.
@interface MSColorPickerViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title initialHex:(NSString *)hex purpose:(MSColorPickerPurpose)purpose completion:(void (^)(NSString *hex))completion;
@property(nonatomic,copy,readonly) NSString *selectedHex;
@end
NS_ASSUME_NONNULL_END
