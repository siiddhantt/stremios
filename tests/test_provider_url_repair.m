#import <Foundation/Foundation.h>
#import "MSProviderURLRepair.h"
static unsigned checks, failures;
static void check(BOOL condition, const char *name) { checks++; if (!condition) { failures++; fprintf(stderr,"FAIL provider repair: %s\n",name); } }
static NSString *repeat(NSString *value,NSUInteger count) { return [@"" stringByPaddingToLength:count withString:value startingAtIndex:0]; }
static NSURL *url(NSString *path) { return [NSURL URLWithString:[@"https://mediafusion.elfhosted.com" stringByAppendingString:path]]; }
static NSString *const provider=@"stremio.addons.mediafusion|elfhostedtrb";
static NSURL *repair(NSURL *source,NSURL *manifest) { return MSRestoreMediaFusionPlaybackURL(source,manifest,provider); }
static void unchanged(NSURL *source,NSURL *manifest,const char *name) { check(repair(source,manifest)==source,name); }
int main(void) { @autoreleasepool {
    // Synthetic strings only. No live service call, account URL, or stored key.
    NSString *known=[@"D-" stringByAppendingString:repeat(@"a",64)];
    NSString *reference=[NSString stringWithFormat:@"T-%@.%@",repeat(@"8",64),repeat(@"9",43)];
    NSString *tail=[@"/playback/torbox/" stringByAppendingString:reference];
    NSURL *manifest=url([NSString stringWithFormat:@"/%@/manifest.json",known]);
    NSURL *broken=url([@"/streaming_provider/D-[redacted]" stringByAppendingString:tail]);
    NSURL *expected=url([[ @"/streaming_provider/" stringByAppendingString:known] stringByAppendingString:tail]);
    NSURL *restored=repair(broken,manifest);
    check([restored isEqual:expected],"exact overlapping hex/base32 redaction restores known component");
    check([restored.lastPathComponent isEqual:reference],"signed reference retained byte-for-byte");
    check([manifest.path isEqual:[NSString stringWithFormat:@"/%@/manifest.json",known]],"manifest remains immutable");
    unchanged(expected,manifest,"already-valid URL keeps exact original object");
    check(MSRestoreMediaFusionPlaybackURL(nil,manifest,provider)==nil,"nil URL remains nil");
    check(MSRestoreMediaFusionPlaybackURL(broken,nil,provider)==broken,"missing configuration cannot repair");
    for (NSString *identity in @[@"com.stremio.torrentio.addon",@"stremio.addons.mediafusion",@"other",@""])
        check(MSRestoreMediaFusionPlaybackURL(broken,manifest,identity)==broken,"unrelated add-on cannot borrow configuration");
    for (NSString *bad in @[@"http://mediafusion.elfhosted.com",@"https://other.invalid",@"https://mediafusion.elfhosted.com.evil.invalid",@"https://mediafusion.elfhosted.com.",@"https://user@mediafusion.elfhosted.com",@"https://user:pass@mediafusion.elfhosted.com",@"https://mediafusion.elfhosted.com:444"]) {
        unchanged([NSURL URLWithString:[bad stringByAppendingString:broken.path]],manifest,"wrong source origin/credentials/port rejected");
        unchanged(broken,[NSURL URLWithString:[bad stringByAppendingString:manifest.path]],"wrong manifest origin/credentials/port rejected");
    }
    for (NSString *suffix in @[@"?a=1",@"?",@"#fragment",@"#"]) {
        unchanged([NSURL URLWithString:[broken.absoluteString stringByAppendingString:suffix]],manifest,"source query/fragment ambiguity rejected");
        unchanged(broken,[NSURL URLWithString:[manifest.absoluteString stringByAppendingString:suffix]],"manifest query/fragment ambiguity rejected");
    }
    for (NSString *component in @[@"D-[redacted]-wrong",@"D-[redacted][redacted]",@"D-[redacted]x",@"D-%255Bredacted%255D",@"D-%2f[redacted]",@"D-%2e%2e",@"D-%61[redacted]"])
        unchanged(url([[@"/streaming_provider/" stringByAppendingString:component] stringByAppendingString:tail]),manifest,"non-exact or encoded component is untouched");
    for (NSString *route in @[@"/streaming_provider/D-[redacted]/playback/realdebrid/",@"/streaming_provider/D-[redacted]/playback/Torbox/",@"/streaming_provider/D-[redacted]/other/torbox/",@"/streaming_provider/D-[redacted]/playback/torbox/../",@"/prefix/streaming_provider/D-[redacted]/playback/torbox/"])
        unchanged(url([route stringByAppendingString:reference]),manifest,"unsupported provider/route/traversal rejected");
    for (NSString *token in @[@"not-a-reference",@"T-short.short",[reference stringByAppendingString:@"/filename"],[reference stringByAppendingString:@"/1/2"],[reference stringByReplacingOccurrencesOfString:@"T-" withString:@"T-%38"],[reference stringByAppendingString:@"="],[reference stringByAppendingString:@"%2Fextra"]])
        unchanged(url([@"/streaming_provider/D-[redacted]/playback/torbox/" stringByAppendingString:token]),manifest,"malformed or encoded reference is untouched");
    for (NSString *path in @[@"/wrong/manifest.json",@"/D-short/manifest.json",[@"/" stringByAppendingFormat:@"%@/configure",known],[@"/prefix/" stringByAppendingFormat:@"%@/manifest.json",known],[@"/" stringByAppendingFormat:@"%@/manifest.json/",known],[@"/" stringByAppendingFormat:@"%@/manifest%%2ejson",known]])
        unchanged(broken,url(path),"unrecognized configuration shape rejected");
    // Disjoint base32/hex runs, mixed case and visible punctuation must survive
    // exactly; a partial match is insufficient even when it looks plausible.
    NSString *mixed=[NSString stringWithFormat:@"D-%@_89_%@-8",repeat(@"G",32),repeat(@"f",40)];
    NSURL *mixedManifest=url([NSString stringWithFormat:@"/%@/manifest.json",mixed]);
    NSURL *mixedBroken=url([@"/streaming_provider/D-[redacted]_89_[redacted]-8" stringByAppendingString:tail]);
    check([repair(mixedBroken,mixedManifest).path isEqual:[NSString stringWithFormat:@"/streaming_provider/%@%@",mixed,tail]],"disjoint mixed-case runs restored exactly");
    unchanged(broken,mixedManifest,"different configured secret cannot match placeholder alone");
    NSURL *explicitPort=[NSURL URLWithString:[broken.absoluteString stringByReplacingOccurrencesOfString:@".com/" withString:@".com:443/"]];
    check(repair(explicitPort,manifest).port.integerValue==443,"explicit HTTPS default port preserved");
    fprintf(stdout,"%u provider URL repair checks, %u failures\n",checks,failures); return failures?1:0;
} }
