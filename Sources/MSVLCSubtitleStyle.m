#import "MSVLCSubtitleStyle.h"
#import "MSPlaybackPreferences.h"
#import <math.h>
NSArray<NSString *> *MSVLCSubtitleOptions(MSPlaybackPreferences *p) {
    NSString *font=[p.fontFamily isEqual:@"serif"]?@"Georgia":[p.fontFamily isEqual:@"monospace"]?@"Menlo":@"Helvetica Neue";
    unsigned int rgb=0xFFFFFF;[[NSScanner scannerWithString:p.effectiveSubtitleColorHex] scanHexInt:&rgb];
    BOOL bold=[p.subtitleFontWeight isEqual:@"bold"] || [p.subtitleFontWeight isEqual:@"semibold"];
    // VLC expresses size as a reciprocal fraction of picture height. Match
    // the existing 24pt default at its normal 16 setting, bounded by our UI.
    NSInteger relative=(NSInteger)lround(16.0*24.0/p.subtitleFontSize);
    return @[[NSString stringWithFormat:@"--freetype-font=%@",font],@"--freetype-monofont=Menlo",
        [NSString stringWithFormat:@"--freetype-color=%u",rgb],bold?@"--freetype-bold":@"--no-freetype-bold",
        [NSString stringWithFormat:@"--freetype-rel-fontsize=%ld",(long)MAX(6,MIN(32,relative))],
        @"--freetype-outline-color=0",@"--freetype-outline-opacity=255",@"--freetype-outline-thickness=2",
        @"--freetype-background-color=0",[p.style isEqual:@"white-shadow"]?@"--freetype-background-opacity=0":@"--freetype-background-opacity=180"];
}
