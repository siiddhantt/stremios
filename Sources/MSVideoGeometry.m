#import "MSVideoGeometry.h"
#import <math.h>

CGFloat MSVideoBoundedZoom(CGFloat zoom) { return isfinite(zoom) ? MIN(3, MAX(1, zoom)) : 1; }
CGRect MSVideoPictureRect(CGSize viewport, CGSize video, NSString *mode, CGFloat zoom) {
    if (!isfinite(viewport.width) || !isfinite(viewport.height) || viewport.width <= 0 || viewport.height <= 0) return CGRectZero;
    CGFloat ratio = video.width > 0 && video.height > 0 ? video.width / video.height : 16.0/9.0;
    if (!isfinite(ratio) || ratio <= 0) ratio = 16.0/9.0;
    if ([mode isEqual:@"16:9"]) ratio = 16.0/9.0;
    else if ([mode isEqual:@"4:3"]) ratio = 4.0/3.0;
    else if ([mode isEqual:@"1:1"]) ratio = 1;
    else if ([mode isEqual:@"2.35:1"]) ratio = 2.35;
    CGSize size = CGSizeMake(viewport.width, viewport.width / ratio);
    if ([mode isEqual:@"stretch"]) size = viewport;
    else if ([mode isEqual:@"fill"] ? size.height < viewport.height : size.height > viewport.height)
        size = CGSizeMake(viewport.height * ratio, viewport.height);
    CGFloat bounded = MSVideoBoundedZoom(zoom); size.width *= bounded; size.height *= bounded;
    return CGRectMake((viewport.width-size.width)/2, (viewport.height-size.height)/2, size.width, size.height);
}
