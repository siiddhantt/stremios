#import <Foundation/Foundation.h>
#import "MSAddons.h"

#ifndef MS_ADDON_STORE_TESTING
#error Compile this test with MS_ADDON_STORE_TESTING; never use a real app storage directory.
#endif
static NSURL *TestRoot;
static BOOL TestFailCommit;
static NSUInteger TestChecks;
NSURL *MSAddonTestStorageDirectory(void) { return [TestRoot URLByAppendingPathComponent:@"MiniStream" isDirectory:YES]; }
BOOL MSAddonTestFailCommit(void) { return TestFailCommit; }
static NSURL *TestStoreFile(void) { return [MSAddonTestStorageDirectory() URLByAppendingPathComponent:@"addons.json"]; }
static NSData *TestSavedBytes(void) { return [NSData dataWithContentsOfURL:TestStoreFile()]; }
static void Check(BOOL condition, const char *label) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", label); exit(1); }
    TestChecks++;
}
static NSDictionary *Manifest(void) {
    return @{@"id":@"test.addon", @"name":@"Test add-on", @"types":@[@"movie", @"series"], @"resources":@[@"stream", @"catalog"], @"idPrefixes":@[@"tt"]};
}
int main(void) {
    @autoreleasepool {
        TestRoot = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"MiniStreamAddonTests-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error = nil;
        NSURL *URL = [MSAddon manifestURLFromString:@"stremio://addons.example/config%2Fvalue/manifest.json?token=demo%2Bvalue&flag=1" error:&error];
        Check([URL.scheme isEqual:@"https"] && !error, "stremio scheme normalizes to HTTPS");
        for (NSString *bad in @[@"http://addons.example/manifest.json", @"https://user:pass@addons.example/manifest.json", @"https://@addons.example/manifest.json", @"https://addons.example/manifest.json#fragment", @"https://addons.example/config", @""]) {
            Check(![MSAddon manifestURLFromString:bad error:nil], "invalid manifest URL rejected");
        }
        MSAddon *addon = [MSAddon addonWithManifest:Manifest() URL:URL error:&error];
        Check(addon != nil, "valid manifest accepted");
        Check([addon supportsResource:@"stream" type:@"series" identifier:@"tt123:1:2"], "global prefix supports episode ID");
        Check(![addon supportsResource:@"stream" type:@"movie" identifier:@"other123"], "global prefix filters IDs");
        Check(![addon supportsResource:@"stream" type:@"channel" identifier:@"tt123"], "global types filter resources");
        Check([addon supportsResource:@"catalog" type:@"movie" identifier:@"top"], "catalog ignores ID prefixes");
        NSURL *resource = [addon resourceURL:@"stream" type:@"series" identifier:@"tt123:1:2" extras:nil];
        NSURLComponents *parts = [NSURLComponents componentsWithURL:resource resolvingAgainstBaseURL:NO];
        Check([parts.percentEncodedPath isEqual:@"/config%2Fvalue/stream/series/tt123%3A1%3A2.json"], "configured escaped path and episode ID preserved");
        Check([parts.percentEncodedQuery isEqual:@"token=demo%2Bvalue&flag=1"], "configured query preserved verbatim");
        NSURL *catalog = [addon resourceURL:@"catalog" type:@"movie" identifier:@"top" extras:@{@"search":@"A/B & C?", @"skip":@"100"}];
        Check([[NSURLComponents componentsWithURL:catalog resolvingAgainstBaseURL:NO].percentEncodedPath hasSuffix:@"/catalog/movie/top/search=A%2FB%20%26%20C%3F&skip=100.json"], "extras encoded individually and sorted");
        Check(![addon resourceURL:@"stream" type:@"movie" identifier:@"tt123" extras:(id)@{@"skip":@1}], "non-string extras rejected");
        NSMutableDictionary *objects = [Manifest() mutableCopy];
        objects[@"resources"] = @[@{@"name":@"stream", @"types":@[@"channel"]}, @{@"name":@"meta", @"types":@[@"movie"], @"idPrefixes":@[@"custom:"]}];
        MSAddon *objectAddon = [MSAddon addonWithManifest:objects URL:URL error:nil];
        Check([objectAddon supportsResource:@"stream" type:@"channel" identifier:@"anything"], "descriptor types override global and absent prefixes mean all");
        Check(![objectAddon supportsResource:@"stream" type:@"movie" identifier:@"tt123"], "descriptor type enforced");
        Check([objectAddon supportsResource:@"meta" type:@"movie" identifier:@"custom:42"], "descriptor prefix accepted");
        Check(![objectAddon supportsResource:@"meta" type:@"movie" identifier:@"tt123"], "descriptor prefixes do not inherit globals");
        objects[@"resources"] = @[@{@"name":@"stream", @"types":@[@"movie"], @"idPrefixes":@[]}];
        MSAddon *emptyFilter = [MSAddon addonWithManifest:objects URL:URL error:nil];
        Check(![emptyFilter supportsResource:@"stream" type:@"movie" identifier:@"tt123"], "empty prefix filter matches no IDs");
        NSMutableDictionary *bad = [Manifest() mutableCopy]; bad[@"resources"] = @[@{@"name":@"stream"}];
        Check(![MSAddon addonWithManifest:bad URL:URL error:nil], "descriptor without types rejected");
        bad = [Manifest() mutableCopy]; bad[@"padding"] = [@"x" stringByPaddingToLength:256 * 1024 withString:@"x" startingAtIndex:0];
        Check(![MSAddon addonWithManifest:bad URL:URL error:nil], "manifest byte limit enforced");
        MSAddonStore *store = [MSAddonStore new];
        Check(store.addons.count == 2 && store.addons[0].builtIn && store.addons[1].builtIn, "two built-ins available without stored data");
        Check([store addManifest:Manifest() URL:URL error:&error], "custom add-on saved in private file storage");
        NSDictionary *fileAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:TestStoreFile().path error:nil];
        NSDictionary *directoryAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:MSAddonTestStorageDirectory().path error:nil];
        Check(([fileAttributes[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600, "file mode is 0600");
        Check(([directoryAttributes[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0700, "directory mode is 0700");
        NSNumber *excluded = nil;
        [TestStoreFile() getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil];
        Check(excluded.boolValue, "file excluded from backup");
        [MSAddonTestStorageDirectory() getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil];
        Check(excluded.boolValue, "directory excluded from backup");
        Check(store.addons.count == 3, "successful save updates entries");
        Check(![store addManifest:Manifest() URL:URL error:nil] && store.addons.count == 3, "duplicate configured URL rejected");
        MSAddonStore *reloaded = [MSAddonStore new];
        Check(reloaded.addons.count == 3 && [reloaded.addons.lastObject.manifestURL.absoluteString isEqual:URL.absoluteString], "configured example URL survives protected-store round trip");
        NSURL *updatedURL = [NSURL URLWithString:@"https://addons.example/updated/manifest.json"];
        NSData *oldBytes = TestSavedBytes(); TestFailCommit = YES;
        Check(![store replaceAddon:store.addons.lastObject manifest:Manifest() URL:updatedURL error:nil] && [oldBytes isEqual:TestSavedBytes()], "failed credential replacement preserves previous connection");
        TestFailCommit = NO;
        Check([store replaceAddon:store.addons.lastObject manifest:Manifest() URL:updatedURL error:nil] && store.addons.count == 3, "replacement commits without duplicate entry");
        Check([store.addons.lastObject.manifestURL isEqual:updatedURL], "replacement URL saved");
        Check(![store replaceAddon:store.addons.firstObject manifest:Manifest() URL:URL error:nil], "built-in replacement rejected");
        Check([store replaceAddon:store.addons.lastObject manifest:Manifest() URL:URL error:nil], "original test connection restored");
        NSData *before = TestSavedBytes();
        TestFailCommit = YES;
        Check(![store removeAddon:store.addons.lastObject error:&error] && error != nil, "precommit write failure reported");
        Check(store.addons.count == 3 && [before isEqual:TestSavedBytes()], "failed write preserves entries and stored bytes");
        TestFailCommit = NO;
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0400} ofItemAtPath:TestStoreFile().path error:nil];
        Check(![store addManifest:Manifest() URL:[NSURL URLWithString:@"https://other.example/manifest.json"] error:&error] && store.loadError != nil, "invalid storage protection blocks mutation");
        Check([before isEqual:TestSavedBytes()], "read failure never overwrites saved bytes");
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:TestStoreFile().path error:nil];
        Check(![store removeAddon:store.addons.firstObject error:nil], "built-ins cannot be removed");
        for (NSUInteger i = 1; i < 12; i++) {
            NSURL *next = [NSURL URLWithString:[NSString stringWithFormat:@"https://addons.example/config%lu/manifest.json", (unsigned long)i]];
            Check([store addManifest:Manifest() URL:next error:nil], "custom entry below cap accepted");
        }
        Check(store.addons.count == 14 && ![store addManifest:Manifest() URL:[NSURL URLWithString:@"https://addons.example/overflow/manifest.json"] error:nil], "twelve custom add-on cap enforced");
        Check([store removeAddon:store.addons.lastObject error:nil] && store.addons.count == 13, "custom add-on removal persisted");
        [[@"invalid" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:TestStoreFile() options:0 error:nil];
        Check(![store reloadWithError:&error] && store.loadError != nil, "malformed stored data surfaces an error");
        Check(store.addons.count == 13, "malformed storage does not replace in-memory entries");
        [[NSMutableData dataWithLength:512 * 1024 + 1] writeToURL:TestStoreFile() options:0 error:nil];
        Check(![store reloadWithError:&error] && store.addons.count == 13, "oversized stored bytes rejected without replacing entries");
        NSArray *remaining = [NSFileManager.defaultManager contentsOfDirectoryAtPath:MSAddonTestStorageDirectory().path error:nil];
        Check(remaining.count == 1 && [remaining.firstObject isEqual:@"addons.json"], "failed commit removes temporary staging file");
        Check([NSFileManager.defaultManager removeItemAtURL:TestStoreFile() error:nil], "oversized test fixture removed");
        MSAddonStore *largeStore = [MSAddonStore new];
        NSString *prefix = [@"test:" stringByPaddingToLength:160 withString:@"x" startingAtIndex:0];
        NSMutableArray *prefixes = [NSMutableArray array]; for (NSUInteger i = 0; i < 64; i++) [prefixes addObject:prefix];
        NSMutableArray *resources = [NSMutableArray array];
        for (NSUInteger i = 0; i < 5; i++) [resources addObject:@{@"name":@"stream", @"types":@[@"movie"], @"idPrefixes":prefixes}];
        NSMutableDictionary *largeManifest = [Manifest() mutableCopy]; largeManifest[@"resources"] = resources;
        BOOL reachedStorageCap = NO;
        for (NSUInteger i = 0; i < 12; i++) {
            NSData *previous = TestSavedBytes(); NSUInteger oldCount = largeStore.addons.count;
            NSURL *next = [NSURL URLWithString:[NSString stringWithFormat:@"https://large.example/config%lu/manifest.json", (unsigned long)i]];
            if (![largeStore addManifest:largeManifest URL:next error:&error]) {
                reachedStorageCap = YES;
                Check(previous.length > 0 && [previous isEqual:TestSavedBytes()] && largeStore.addons.count == oldCount, "store-size failure preserves last committed file and entries");
                break;
            }
        }
        Check(reachedStorageCap && TestSavedBytes().length <= 512 * 1024, "512 KiB aggregate storage cap enforced");
        Check([NSFileManager.defaultManager removeItemAtURL:TestRoot error:nil], "isolated temporary store cleaned up");
        printf("PASS: %lu add-on checks (isolated file store; iOS Data Protection requires device check)\n", (unsigned long)TestChecks);
    }
    return 0;
}
