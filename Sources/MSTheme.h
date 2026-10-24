#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@class MSPlaybackPreferences;
UIColor *MSBackgroundColor(void);
UIColor *MSSurfaceColor(void);
UIColor *MSPrimaryColor(void);
UIColor *MSSecondaryColor(void);
UIColor *MSAccentColor(void);
NSArray<NSString *> *MSAccentNames(void);
NSString *MSSelectedAccentName(void);
UIColor *MSAccentColorForName(NSString *name);
void MSSelectAccent(NSString *name);
NSString *MSSelectedAccentHex(void);
void MSSelectCustomAccentHex(NSString *hex);
UIColor *MSColorFromHex(NSString *hex);
UIFont *MSSubtitleFont(MSPlaybackPreferences *preferences);
UIFont *MSFont(UIFontTextStyle style, UIFontWeight weight);
extern NSString *const MSThemeDidChangeNotification;
UILabel *MSLabel(UIFontTextStyle style, UIColor *color);
UIButton *MSButton(NSString *title, BOOL primary);
UIImage *MSTabImage(NSString *name);
UIImage *MSDemoArtwork(void);
void MSApplyNavigationStyle(UINavigationController *controller);
NSString *MSTimeDescription(NSTimeInterval seconds);
NS_ASSUME_NONNULL_END
