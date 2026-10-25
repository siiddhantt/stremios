#import "MSVLCSubtitleStyle.h"
#import "MSPlaybackPreferences.h"
#import <math.h>
@protocol MSVLCPinnedTextRenderer <NSObject>
- (void)setTextRendererFont:(NSString *)font;
- (void)setTextRendererFontSize:(NSNumber *)size;
- (void)setTextRendererFontColor:(NSNumber *)color;
- (void)setTextRendererFontForceBold:(NSNumber *)bold;
@end
static NSString *MSVLCFont(MSPlaybackPreferences *p) {
    return [p.fontFamily isEqual:@"serif"]?@"Georgia":[p.fontFamily isEqual:@"monospace"]?@"Menlo":[p.fontFamily isEqual:@"arial"]?@"Arial":@"Helvetica Neue";
}
static unsigned int MSVLCColor(MSPlaybackPreferences *p) { unsigned int rgb=0xFFFFFF;[[NSScanner scannerWithString:p.effectiveSubtitleColorHex] scanHexInt:&rgb];return rgb; }
static NSInteger MSVLCRelativeSize(MSPlaybackPreferences *p) { return MAX(6,MIN(32,(NSInteger)lround(16.0*24.0/p.subtitleFontSize))); }
static BOOL MSVLCBold(MSPlaybackPreferences *p) { return [p.subtitleFontWeight isEqual:@"bold"] || [p.subtitleFontWeight isEqual:@"semibold"]; }
NSArray<NSString *> *MSVLCSubtitleOptions(MSPlaybackPreferences *p) {
    // VLC expresses size as a reciprocal fraction of picture height. Match
    // the existing 24pt default at its normal 16 setting, bounded by our UI.
    return @[[NSString stringWithFormat:@"--freetype-font=%@",MSVLCFont(p)],@"--freetype-monofont=Menlo",
        [NSString stringWithFormat:@"--freetype-color=%u",MSVLCColor(p)],MSVLCBold(p)?@"--freetype-bold":@"--no-freetype-bold",
        [NSString stringWithFormat:@"--freetype-rel-fontsize=%ld",(long)MSVLCRelativeSize(p)],
        @"--freetype-outline-color=0",@"--freetype-outline-opacity=255",@"--freetype-outline-thickness=2",
        @"--freetype-background-color=0",[p.style isEqual:@"white-shadow"]?@"--freetype-background-opacity=0":@"--freetype-background-opacity=180",
        p.subtitleShadowEnabled?@"--freetype-shadow-opacity=128":@"--freetype-shadow-opacity=0",
        @"--freetype-shadow-color=0",@"--freetype-shadow-angle=-45",@"--freetype-shadow-distance=0.06"];
}
NSArray<NSString *> *MSVLCSubtitleOptionsForVideoHeight(MSPlaybackPreferences *p, double height) {
    // The pinned SPU's video grid is independent of UIKit/retina dimensions.
    // Use parsed source height for a requested offset, otherwise keep VLC's
    // native bottom position. Never guess a margin from the screen size.
    double offset=p.subtitleVerticalOffset;offset=isfinite(offset)?MAX(-.05,MIN(.50,offset)):0;
    NSInteger margin=0;
    if(isfinite(height)&&height>=16&&height<=8192&&fabs(offset)>=0.0001)
        margin=(NSInteger)lround(height*MAX(0,offset));
    return [MSVLCSubtitleOptions(p) arrayByAddingObject:[NSString stringWithFormat:@"--sub-margin=%ld",(long)margin]];
}
BOOL MSVLCApplySubtitleLiveStyle(id player, MSPlaybackPreferences *p) {
    if(!player || ![player respondsToSelector:@selector(setTextRendererFont:)] || ![player respondsToSelector:@selector(setTextRendererFontSize:)] || ![player respondsToSelector:@selector(setTextRendererFontColor:)] || ![player respondsToSelector:@selector(setTextRendererFontForceBold:)])return NO;
    id<MSVLCPinnedTextRenderer> renderer=player;
    [renderer setTextRendererFont:MSVLCFont(p)];[renderer setTextRendererFontSize:@(MSVLCRelativeSize(p))];
    [renderer setTextRendererFontColor:@(MSVLCColor(p))];[renderer setTextRendererFontForceBold:@(MSVLCBold(p))];
    return YES;
}
