#import <Foundation/Foundation.h>
#import "MSPlaybackPreferences.h"
#import "MSColorPolicy.h"
#import "MSVLCSubtitleStyle.h"
#import <math.h>
static unsigned checks, failures;
static void check(BOOL value, const char *name) { checks++; if (!value) { failures++; fprintf(stderr,"FAIL playback preferences: %s\n",name); } }
int main(void) { @autoreleasepool {
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
    p.subtitleFontWeight=@"bold";vlc=MSVLCSubtitleOptions(p);check([vlc containsObject:@"--freetype-bold"]&&[vlc containsObject:@"--freetype-outline-color=0"]&&[vlc containsObject:@"--freetype-outline-opacity=255"]&&[vlc containsObject:@"--freetype-outline-thickness=2"]&&vlc.count==10,"VLC forced bold and bounded outline option set");
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
