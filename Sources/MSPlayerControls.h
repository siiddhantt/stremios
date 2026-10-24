#import <UIKit/UIKit.h>

/// Official 24-point Tabler template artwork, cached at the device scale.
/// Names: close, view, audio, cc, fullscreen, fullscreen-exit, play, pause, back, forward.
UIImage *MSPlayerIcon(NSString *name);
/// Compact UIKit popover; no animated effects or additional rendering engine.
@interface MSVideoOptionsViewController : UIViewController
- (instancetype)initWithMode:(NSString *)mode zoom:(CGFloat)zoom change:(void (^)(NSString *, CGFloat))change;
@end
