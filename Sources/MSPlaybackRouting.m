#import "MSPlaybackRouting.h"
#import "MSPlaybackViewController.h"
#import "MSVLCPlaybackViewController.h"
UIViewController<MSPlaybackControlling> *MSMakePlaybackController(MSMedia *media, NSString *container, BOOL resume) {
    if ([container isEqualToString:@"hls"]) return [[MSPlaybackViewController alloc] initWithMedia:media resume:resume];
    return [[MSVLCPlaybackViewController alloc] initWithMedia:media resume:resume];
}
