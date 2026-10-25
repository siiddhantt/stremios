#import <Foundation/Foundation.h>
#import "MSPlaybackPreferences.h"
#import "MSColorPolicy.h"
#import "MSVLCSubtitleStyle.h"
#import <math.h>
static unsigned checks, failures;
static void check(BOOL value, const char *name) { checks++; if (!value) { failures++; fprintf(stderr,"FAIL playback preferences: %s\n",name); } }
@interface MSTextRendererProbe : NSObject
@property(nonatomic,copy) NSString *font;
@property(nonatomic,strong) NSNumber *size,*color,*bold;
@property(nonatomic) NSUInteger writes;
@end
@implementation MSTextRendererProbe
- (void)setTextRendererFont:(NSString *)font {self.font=font;self.writes++;}
- (void)setTextRendererFontSize:(NSNumber *)size {self.size=size;self.writes++;}
- (void)setTextRendererFontColor:(NSNumber *)color {self.color=color;self.writes++;}
- (void)setTextRendererFontForceBold:(NSNumber *)bold {self.bold=bold;self.writes++;}
@end
static void testOffsetShadowAndArial(void) {
    NSString *suite=[@"local.ministream.subtitle-position-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults=[[NSUserDefaults alloc]initWithSuiteName:suite];[defaults removePersistentDomainForName:suite];
    NSString *key=@"MiniStream.PlaybackPreferences.v1";
    MSPlaybackPreferences *p=[[MSPlaybackPreferences alloc]initWithDefaults:defaults];
    __block NSUInteger notices=0;id observer=[NSNotificationCenter.defaultCenter addObserverForName:MSPlaybackPreferencesDidChangeNotification object:p queue:nil usingBlock:^(NSNotification *note){(void)note;notices++;}];
    check(p.subtitleVerticalOffset==0&&!p.subtitleShadowEnabled,"new offset and shadow defaults");
    p.subtitleVerticalOffset=0;p.subtitleShadowEnabled=NO;check(notices==0,"unchanged offset and explicit shadow do not notify");
    check([defaults dictionaryForKey:key][@"shadowEnabled"]!=nil,"explicit shadow intent stored even when matching fallback");
    p.style=@"white-shadow";check(!p.subtitleShadowEnabled,"explicit shadow off survives clear-background preset");
    [defaults setObject:@{@"style":@"white-shadow",@"position":@"top"} forKey:key];
    check(p.subtitleShadowEnabled&&p.subtitleVerticalOffset==0&&[p.position isEqual:@"top"],"legacy white-shadow migrates without reinterpreting location");
    NSUInteger before=notices;p.subtitleShadowEnabled=YES;check(notices==before,"pinning unchanged legacy shadow is silent");
    p.style=@"white-dark";check(p.subtitleShadowEnabled,"shadow stays enabled independently of dark background");
    p.subtitleVerticalOffset=0.25;p.fontFamily=@"arial";p.subtitleFontWeight=@"bold";
    MSPlaybackPreferences *reload=[[MSPlaybackPreferences alloc]initWithDefaults:defaults];
    check(reload.subtitleVerticalOffset==0.25&&reload.subtitleShadowEnabled&&[reload.fontFamily isEqual:@"arial"]&&[reload.subtitleFontWeight isEqual:@"bold"],"offset shadow and Arial persist across instances");
    check([reload.position isEqual:@"top"],"new appearance setters preserve legacy location field");
    before=notices;p.subtitleVerticalOffset=0.25;p.subtitleShadowEnabled=YES;check(notices==before,"repeated normalized new values do not notify");
    p.subtitleVerticalOffset=2;check(p.subtitleVerticalOffset==0.5,"offset upper clamp");
    before=notices;p.subtitleVerticalOffset=8;check(notices==before,"same upper clamp does not notify");
    p.subtitleVerticalOffset=-2;check(p.subtitleVerticalOffset==-0.05,"offset lower clamp");
    p.subtitleVerticalOffset=NAN;check(p.subtitleVerticalOffset==0,"offset NaN resets to default");
    before=notices;p.subtitleVerticalOffset=INFINITY;p.subtitleVerticalOffset=-INFINITY;check(p.subtitleVerticalOffset==0&&notices==before,"infinite offset safely defaults without duplicate notification");
    p.subtitleVerticalOffset=-0.05;check(p.subtitleVerticalOffset==-0.05,"offset lower inclusive");
    p.subtitleVerticalOffset=0.5;check(p.subtitleVerticalOffset==0.5,"offset upper inclusive");
    for(id bad in @[@"0.25",@[],@{},@YES,@(NAN),@(INFINITY)]){
        [defaults setObject:@{@"verticalOffset":bad} forKey:key];check(p.subtitleVerticalOffset==0,"malformed saved offset safely defaults");
    }
    [defaults setObject:@{@"verticalOffset":@8} forKey:key];check(p.subtitleVerticalOffset==0.5,"stored offset upper clamp");
    [defaults setObject:@{@"verticalOffset":@(-8)} forKey:key];check(p.subtitleVerticalOffset==-0.05,"stored offset lower clamp");
    for(id bad in @[@"YES",@[],@{},@2,@(-1),@0.25,@(NAN),@(INFINITY)]){
        [defaults setObject:@{@"shadowEnabled":bad,@"style":@"white-shadow"} forKey:key];check(p.subtitleShadowEnabled,"invalid saved shadow uses legacy fallback");
        [defaults setObject:@{@"shadowEnabled":bad,@"style":@"yellow-dark"} forKey:key];check(!p.subtitleShadowEnabled,"invalid saved shadow does not enable on dark presets");
    }
    [defaults setObject:@{@"shadowEnabled":@0,@"style":@"white-shadow"} forKey:key];check(!p.subtitleShadowEnabled,"numeric false explicitly overrides legacy shadow");
    [defaults setObject:@{@"shadowEnabled":@1,@"style":@"white-dark"} forKey:key];check(p.subtitleShadowEnabled,"numeric true enables shadow with dark background");
    [defaults setObject:@{@"fontFamily":@"arial"} forKey:key];check([p.fontFamily isEqual:@"arial"]&&[p.subtitleFontWeight isEqual:@"regular"],"Arial defaults to available regular weight");
    [defaults setObject:@{@"verticalOffset":@0.4,@"shadowEnabled":@YES,@"fontFamily":@"arial",@"position":@"middle",@"quality":@"1080p",@"audioLanguage":@"hin",@"subtitleLanguage":@"eng",@"extension-field":@"keep"} forKey:key];
    [defaults setObject:@"keep" forKey:@"unrelated"];before=notices;[p resetSubtitleAppearance];
    check(notices==before+1&&p.subtitleVerticalOffset==0&&!p.subtitleShadowEnabled&&[p.fontFamily isEqual:@"system"],"reset restores new appearance defaults with one notice");
    NSDictionary *remaining=[defaults dictionaryForKey:key];check(!remaining[@"verticalOffset"]&&!remaining[@"shadowEnabled"]&&!remaining[@"fontFamily"],"reset removes new appearance keys");
    check([remaining[@"quality"] isEqual:@"1080p"]&&[remaining[@"audioLanguage"] isEqual:@"hin"]&&[remaining[@"subtitleLanguage"] isEqual:@"eng"]&&[remaining[@"extension-field"] isEqual:@"keep"]&&[[defaults objectForKey:@"unrelated"] isEqual:@"keep"],"reset preserves playback and unrelated defaults");
    before=notices;[p resetSubtitleAppearance];check(notices==before,"repeat reset stays silent");
    [defaults setObject:@[@1] forKey:key];check(p.subtitleVerticalOffset==0&&!p.subtitleShadowEnabled,"malformed root uses safe new defaults");
    p.subtitleShadowEnabled=YES;p.subtitleVerticalOffset=0.12;check(p.subtitleShadowEnabled&&p.subtitleVerticalOffset==0.12,"new setters repair malformed root");
    [NSNotificationCenter.defaultCenter removeObserver:observer];[defaults removePersistentDomainForName:suite];
}
int main(void) { @autoreleasepool {
    testOffsetShadowAndArial();
    NSString *suite = [@"local.ministream.preferences-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    [defaults setObject:@"keep" forKey:@"unrelated"];
    MSPlaybackPreferences *p = [[MSPlaybackPreferences alloc] initWithDefaults:defaults];
    __block NSUInteger notices = 0;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:MSPlaybackPreferencesDidChangeNotification object:p queue:nil usingBlock:^(NSNotification *note) { (void)note; notices++; }];
    check(p.subtitleFontSize == 24, "default font size");
    check([p.fontFamily isEqual:@"system"] && [p.style isEqual:@"white-dark"] && [p.position isEqual:@"bottom"], "default presentation");
    check([p.playbackQuality isEqual:@"auto"] && [p.preferredAudioLanguage isEqual:@"system"] && [p.preferredSubtitleLanguage isEqual:@"system"], "default playback preferences");
    check([p.subtitleFontWeight isEqual:@"semibold"] && p.subtitleColorHex.length==0 && [p.effectiveSubtitleColorHex isEqual:@"FFFFFF"], "new defaults retain system semibold and white");
    check([MSNormalizedColorHex(@" #a1b2c3 ") isEqual:@"A1B2C3"], "hex canonicalization");
    for(id invalid in @[@"fff",@"11223344",@"12345G",@"ＦＦＦＦＦＦ",@"#12 3456",@"#123456;",@42,@[],@{}])check(!MSNormalizedColorHex(invalid).length,"invalid colour rejected");
    check(!MSNormalizedColorHex(nil).length,"nil colour rejected");
    check(fabs(MSColorContrastRatio(0,0xFFFFFF)-21)<0.001,"contrast black white reference");
    check([MSReadableAccentHex(@"B6AFFF") isEqual:@"B6AFFF"],"safe palette preserved exactly");
    check([MSReadableSubtitleHex(@"FFE859") isEqual:@"FFE859"],"safe legacy yellow preserved");
    BOOL allAccentSafe=YES,allSubtitleSafe=YES,idempotent=YES;
    for(unsigned r=0;r<=255;r+=51)for(unsigned g=0;g<=255;g+=51)for(unsigned b=0;b<=255;b+=51){NSString *hex=[NSString stringWithFormat:@"%02X%02X%02X",r,g,b];NSString *accent=MSReadableAccentHex(hex),*subtitle=MSReadableSubtitleHex(hex);allAccentSafe=allAccentSafe&&MSColorContrastRatio(MSColorRGB(accent),0x1A1C24)>=4.5&&MSColorContrastRatio(MSColorRGB(accent),0x111217)>=4.5;allSubtitleSafe=allSubtitleSafe&&MSColorContrastRatio(MSColorRGB(subtitle),0)>=4.5;idempotent=idempotent&&[MSReadableAccentHex(accent) isEqual:accent]&&[MSReadableSubtitleHex(subtitle) isEqual:subtitle];}
    check(allAccentSafe,"216 colour grid preserves accent and button contrast");check(allSubtitleSafe,"216 colour grid preserves dark caption contrast");check(idempotent,"contrast adjustment idempotent");
    p.subtitleFontSize = 24; p.fontFamily = @"system"; p.style = @"white-dark";
    check(notices == 0, "unchanged values do not notify");
    p.subtitleFontSize = 30; check(notices == 1 && p.subtitleFontSize == 30, "font size saved and notified once");
    p.subtitleFontSize = 500; check(p.subtitleFontSize == 40, "upper bound");
    p.subtitleFontSize = -50; check(p.subtitleFontSize == 14, "lower bound");
    p.subtitleFontSize = NAN; check(p.subtitleFontSize == 24, "NaN resets safely");
    p.subtitleFontSize = INFINITY; check(p.subtitleFontSize == 24, "infinity resets safely");
    p.subtitleFontSize = 14; check(p.subtitleFontSize == 14, "lower inclusive");
    p.subtitleFontSize = 40; check(p.subtitleFontSize == 40, "upper inclusive");
    p.fontFamily = @"serif"; p.style = @"yellow-dark"; p.position = @"top";
    check([p.fontFamily isEqual:@"serif"] && [p.style isEqual:@"yellow-dark"] && [p.position isEqual:@"top"], "valid presentation values");
    p.fontFamily = @"monospace"; p.style = @"white-shadow"; p.position = @"middle";
    check([p.fontFamily isEqual:@"monospace"] && [p.style isEqual:@"white-shadow"] && [p.position isEqual:@"middle"], "alternate presentation values");
    p.playbackQuality = @"1080p"; p.preferredAudioLanguage = @"hin"; p.preferredSubtitleLanguage = @"eng";
    MSPlaybackPreferences *reloaded = [[MSPlaybackPreferences alloc] initWithDefaults:defaults];
    check(reloaded.subtitleFontSize == 40 && [reloaded.fontFamily isEqual:@"monospace"], "reload presentation");
    check([reloaded.playbackQuality isEqual:@"1080p"] && [reloaded.preferredAudioLanguage isEqual:@"hin"] && [reloaded.preferredSubtitleLanguage isEqual:@"eng"], "reload playback preferences");
    p.playbackQuality = @"720p"; p.preferredAudioLanguage = @"eng"; p.preferredSubtitleLanguage = @"none";
    check([p.playbackQuality isEqual:@"720p"] && [p.preferredAudioLanguage isEqual:@"eng"] && [p.preferredSubtitleLanguage isEqual:@"none"], "quality and subtitle off choices");
    p.fontFamily=@"serif";check([p.subtitleFontWeight isEqual:@"regular"],"legacy serif keeps regular weight before explicit choice");
    p.subtitleFontWeight=@"bold";p.subtitleColorHex=@"#82c9ff";
    check([p.subtitleFontWeight isEqual:@"bold"]&&[p.effectiveSubtitleColorHex isEqual:@"82C9FF"],"custom weight and color saved");
    MSPlaybackPreferences *newReload=[[MSPlaybackPreferences alloc] initWithDefaults:defaults];check([newReload.subtitleFontWeight isEqual:@"bold"]&&[newReload.subtitleColorHex isEqual:@"82C9FF"],"new appearance values reload");
    NSUInteger beforeUnchanged=notices;p.subtitleFontWeight=@"bold";p.subtitleColorHex=@"82c9ff";check(notices==beforeUnchanged,"equivalent normalized colors do not notify");
    p.subtitleColorHex=@"000000";check(MSColorContrastRatio(MSColorRGB(p.subtitleColorHex),0)>=4.5,"dark caption choice made readable");
    p.subtitleColorHex=@"bad URL";p.style=@"yellow-dark";check(!p.subtitleColorHex.length&&[p.effectiveSubtitleColorHex isEqual:@"FFE859"],"invalid custom color returns to legacy preset");
    p.subtitleColorHex=@"84BFFF";
    NSUInteger beforeReset = notices; [p resetSubtitleAppearance];
    check(notices == beforeReset + 1, "reset sends one notification");
    check(p.subtitleFontSize == 24 && [p.fontFamily isEqual:@"system"] && [p.style isEqual:@"white-dark"] && [p.position isEqual:@"bottom"], "reset all appearance");
    check([p.playbackQuality isEqual:@"720p"] && [p.preferredAudioLanguage isEqual:@"eng"] && [p.preferredSubtitleLanguage isEqual:@"none"], "appearance reset preserves playback choices");
    check([p.subtitleFontWeight isEqual:@"semibold"]&&!p.subtitleColorHex.length&&[p.effectiveSubtitleColorHex isEqual:@"FFFFFF"],"reset removes custom weight and color");
    beforeReset = notices; [p resetSubtitleAppearance]; check(notices == beforeReset, "reset defaults is silent");
    p.fontFamily = @"random-font"; p.style = @"https://example.invalid/"; p.position = @"outside"; p.playbackQuality = @"4k"; p.preferredAudioLanguage = @"none"; p.preferredSubtitleLanguage = @"unknown";
    check([p.fontFamily isEqual:@"system"] && [p.style isEqual:@"white-dark"] && [p.position isEqual:@"bottom"], "invalid presentation rejected");
    check([p.playbackQuality isEqual:@"auto"] && [p.preferredAudioLanguage isEqual:@"system"] && [p.preferredSubtitleLanguage isEqual:@"system"], "invalid playback enums rejected");
    [defaults setObject:@[@1] forKey:@"MiniStream.PlaybackPreferences.v1"];
    check(p.subtitleFontSize == 24 && [p.fontFamily isEqual:@"system"], "malformed root safely defaults");
    p.position = @"top"; check([p.position isEqual:@"top"], "setter repairs malformed root");
    [defaults setObject:@{@"fontSize":@"32", @"fontFamily":@2, @"style":@[], @"position":@{}, @"quality":@12, @"audioLanguage":@YES, @"subtitleLanguage":@[]} forKey:@"MiniStream.PlaybackPreferences.v1"];
    check(p.subtitleFontSize == 24 && [p.fontFamily isEqual:@"system"] && [p.style isEqual:@"white-dark"] && [p.position isEqual:@"bottom"], "malformed presentation types safely default");
    check([p.playbackQuality isEqual:@"auto"] && [p.preferredAudioLanguage isEqual:@"system"] && [p.preferredSubtitleLanguage isEqual:@"system"], "malformed playback types safely default");
    [defaults setObject:@{@"fontSize":@(-1)} forKey:@"MiniStream.PlaybackPreferences.v1"]; check(p.subtitleFontSize == 14, "stored out-of-range value bounded");
    [defaults setObject:@{@"fontWeight":@[],@"subtitleColor":@123,@"quality":@"1080p",@"extension-field":@"keep"} forKey:@"MiniStream.PlaybackPreferences.v1"];check([p.subtitleFontWeight isEqual:@"semibold"]&&!p.subtitleColorHex.length,"malformed new preference values safe");p.subtitleFontWeight=@"medium";p.subtitleColorHex=@"00AAFF";check([defaults dictionaryForKey:@"MiniStream.PlaybackPreferences.v1"][@"extension-field"]!=nil,"new setters preserve unrelated dictionary fields");check([p.playbackQuality isEqual:@"1080p"],"new settings preserve playback quality");
    check([[defaults objectForKey:@"unrelated"] isEqual:@"keep"], "unrelated preferences preserved");
    [p resetSubtitleAppearance];NSArray *vlc=MSVLCSubtitleOptions(p);
    check([vlc containsObject:@"--freetype-font=Helvetica Neue"]&&[vlc containsObject:@"--freetype-monofont=Menlo"],"VLC default safe font families");
    check([vlc containsObject:@"--freetype-color=16777215"]&&[vlc containsObject:@"--freetype-bold"],"VLC default white semibold maps bold");
    check([vlc containsObject:@"--freetype-rel-fontsize=16"]&&[vlc containsObject:@"--freetype-background-opacity=180"],"VLC default relative size and backplate");
    p.subtitleColorHex=@"82C9FF";p.subtitleFontWeight=@"regular";p.fontFamily=@"serif";p.style=@"white-shadow";p.subtitleFontSize=40;vlc=MSVLCSubtitleOptions(p);
    check([vlc containsObject:@"--freetype-color=8571391"],"VLC custom RGB integer matches chosen colour");
    check([vlc containsObject:@"--freetype-font=Georgia"]&&[vlc containsObject:@"--no-freetype-bold"],"VLC serif regular maps no forced bold");
    check([vlc containsObject:@"--freetype-rel-fontsize=10"]&&[vlc containsObject:@"--freetype-background-opacity=0"],"VLC large size and shadow without backplate");
    p.fontFamily=@"monospace";p.subtitleFontWeight=@"medium";p.subtitleFontSize=14;vlc=MSVLCSubtitleOptions(p);check([vlc containsObject:@"--freetype-font=Menlo"]&&[vlc containsObject:@"--no-freetype-bold"]&&[vlc containsObject:@"--freetype-rel-fontsize=27"],"VLC monospace medium and minimum size");
    p.subtitleFontWeight=@"bold";vlc=MSVLCSubtitleOptions(p);check([vlc containsObject:@"--freetype-bold"]&&[vlc containsObject:@"--freetype-outline-color=0"]&&[vlc containsObject:@"--freetype-outline-opacity=255"]&&[vlc containsObject:@"--freetype-outline-thickness=2"]&&vlc.count==14,"VLC forced bold and bounded outline option set");
    [p resetSubtitleAppearance];vlc=MSVLCSubtitleOptions(p);check([vlc containsObject:@"--freetype-shadow-opacity=0"],"VLC default shadow explicitly disabled");
    p.fontFamily=@"arial";p.subtitleShadowEnabled=YES;vlc=MSVLCSubtitleOptions(p);
    check([vlc containsObject:@"--freetype-font=Arial"]&&[vlc containsObject:@"--freetype-background-opacity=180"]&&[vlc containsObject:@"--freetype-shadow-opacity=128"],"VLC Arial and independent shadow with dark background");
    check([vlc containsObject:@"--freetype-shadow-color=0"]&&[vlc containsObject:@"--freetype-shadow-angle=-45"]&&[vlc containsObject:@"--freetype-shadow-distance=0.06"],"VLC shadow geometry explicitly bounded");
    p.style=@"white-shadow";p.subtitleShadowEnabled=NO;vlc=MSVLCSubtitleOptions(p);check([vlc containsObject:@"--freetype-shadow-opacity=0"]&&[vlc containsObject:@"--freetype-background-opacity=0"],"VLC transparent background does not force shadow on");
    check([MSVLCSubtitleOptionsForVideoHeight(p,720) containsObject:@"--sub-margin=0"],"VLC default keeps native subtitle position");
    p.subtitleVerticalOffset=.25;check([MSVLCSubtitleOptionsForVideoHeight(p,720) containsObject:@"--sub-margin=180"],"VLC positive offset raises720 captions");
    p.subtitleVerticalOffset=-.05;check([MSVLCSubtitleOptionsForVideoHeight(p,720) containsObject:@"--sub-margin=0"],"VLC lower offset clamps within video");
    p.subtitleVerticalOffset=-.01;check([MSVLCSubtitleOptionsForVideoHeight(p,720) containsObject:@"--sub-margin=0"],"VLC a small negative offset never raises native bottom captions");
    p.subtitleVerticalOffset=.25;
    for(NSNumber *height in @[@0,@(-1),@15,@8193,@(NAN),@(INFINITY),@(-INFINITY)])
        check([MSVLCSubtitleOptionsForVideoHeight(p,height.doubleValue) containsObject:@"--sub-margin=0"],"VLC requested offset with unknown or unsupported dimensions keeps native position");
    check([MSVLCSubtitleOptionsForVideoHeight(p,360) containsObject:@"--sub-margin=90"],"VLC offset scales with actual360 source height");
    check([MSVLCSubtitleOptionsForVideoHeight(p,1080) containsObject:@"--sub-margin=270"],"VLC offset scales with actual1080 source height");
    p.subtitleVerticalOffset=0;check([MSVLCSubtitleOptionsForVideoHeight(p,NAN) containsObject:@"--sub-margin=0"],"VLC default with missing dimensions keeps native position");
    p.subtitleColorHex=@"82C9FF";p.subtitleFontWeight=@"bold";p.subtitleFontSize=40;MSTextRendererProbe *renderer=[MSTextRendererProbe new];
    check(MSVLCApplySubtitleLiveStyle(renderer,p)&&renderer.writes==4&&[renderer.font isEqual:@"Arial"]&&renderer.size.integerValue==10&&renderer.color.unsignedIntValue==8571391&&renderer.bold.boolValue,"guarded live adapter applies exact chosen font size color and bold values");
    check(!MSVLCApplySubtitleLiveStyle(nil,p)&&!MSVLCApplySubtitleLiveStyle([NSObject new],p),"missing pinned renderer selectors safely decline live styling");
    p.playbackQuality=@"auto";check(MSVLCAdaptiveOptions(p).count==0,"automatic quality leaves adaptive selection unrestricted");
    p.playbackQuality=@"720p";check([MSVLCAdaptiveOptions(p) isEqual:@[@"--adaptive-maxwidth=1280",@"--adaptive-maxheight=720"]],"720p maps to pinned VLC rendition limits");
    p.playbackQuality=@"1080p";check([MSVLCAdaptiveOptions(p) isEqual:@[@"--adaptive-maxwidth=1920",@"--adaptive-maxheight=1080"]],"1080p maps to pinned VLC rendition limits");
    reloaded=[[MSPlaybackPreferences alloc] initWithDefaults:defaults];check([MSVLCAdaptiveOptions(reloaded) isEqual:MSVLCAdaptiveOptions(p)],"adaptive options follow persisted quality on reopen");
    NSUInteger beforeOptions=notices;(void)MSVLCAdaptiveOptions(p);check(notices==beforeOptions,"reading adaptive options does not mutate preferences");
    p.playbackQuality=@"--unsafe-option";check(MSVLCAdaptiveOptions(p).count==0,"unrecognized quality cannot inject engine options");
    [defaults setObject:@{@"quality":@[]} forKey:@"MiniStream.PlaybackPreferences.v1"];check(MSVLCAdaptiveOptions(p).count==0,"malformed saved quality yields no extra engine options");
    [NSNotificationCenter.defaultCenter removeObserver:observer]; [defaults removePersistentDomainForName:suite];
    printf("%u playback preference checks, %u failures\n",checks,failures); return failures ? 1 : 0;
} }
