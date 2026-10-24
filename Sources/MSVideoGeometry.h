#import <UIKit/UIKit.h>

/// Fitted picture at zoom 1, cropped by its parent viewport as necessary.
CGRect MSVideoPictureRect(CGSize viewport, CGSize video, NSString *mode, CGFloat zoom);
CGFloat MSVideoBoundedZoom(CGFloat zoom);
