#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
// Call off the main thread. Static WebP only; bounded input, dimensions and output.
FOUNDATION_EXPORT UIImage * _Nullable MSDecodeWebPThumbnail(NSData *data, NSUInteger maxPixels);
NS_ASSUME_NONNULL_END
