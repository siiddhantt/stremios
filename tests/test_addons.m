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
static NSDictionary *CatalogManifest(void) {
    NSMutableDictionary *manifest = [Manifest() mutableCopy];
    manifest[@"version"] = @"1.2.3";
    manifest[@"catalogs"] = @[@{@"id":@"language/list",@"name":@"By language",@"type":@"movie",@"extra":@[@{@"name":@"genre",@"isRequired":@YES,@"options":@[@"Hindi",@"हिन्दी",@"English"]},@{@"name":@"search"},@{@"name":@"skip"}]}];
    manifest[@"behaviorHints"] = @{@"configurable":@YES};
    manifest[@"config"] = @[@{@"key":@"apiKey",@"type":@"password",@"title":@"Service key",@"default":@"must-not-persist"}];
    return manifest;
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
        MSAddon *catalogAddon = [MSAddon addonWithManifest:CatalogManifest() URL:URL error:nil];
        MSAddonCatalog *descriptor = catalogAddon.catalogs.firstObject;
        Check(descriptor && descriptor.extras.count == 3 && [[descriptor extraNamed:@"genre"] isRequired], "catalog descriptors preserve required option schemas");
        Check(![descriptor requestExtrasForValues:nil skip:0 error:nil], "missing required filter prevents a catalog request");
        Check(![descriptor requestExtrasForValues:@{@"genre":@"French"} skip:0 error:nil], "undeclared option cannot be invented");
        Check(![descriptor requestExtrasForValues:@{@"genre":@"Hindi",@"unknown":@"x"} skip:0 error:nil], "undeclared extra rejected");
        Check(![descriptor requestExtrasForValues:@{@"genre":@"Hindi",@"skip":@"9"} skip:0 error:nil], "caller cannot override pagination cursor");
        NSDictionary *filter = [descriptor requestExtrasForValues:@{@"genre":@"हिन्दी",@"search":@"a/b & c"} skip:37 error:nil];
        NSURL *filteredURL = [catalogAddon resourceURL:@"catalog" type:descriptor.type identifier:descriptor.identifier extras:filter];
        Check(filter && [filter[@"skip"] isEqual:@"37"] && [filteredURL.absoluteString containsString:@"language%2Flist/genre="], "required Unicode filter and explicit cursor serialize under configured base");
        Check(![descriptor.identity containsString:@"token"] && ![descriptor.identity containsString:@"config%2Fvalue"], "catalog identity contains no configured URL or credential");
        Check(catalogAddon.configurable && !catalogAddon.configurationRequired && [catalogAddon.version isEqual:@"1.2.3"], "configuration flags and version retained");
        Check(!catalogAddon.configurationFields.firstObject[@"default"], "secret-like configuration defaults never retained");
        Check([[NSURLComponents componentsWithURL:catalogAddon.configureURL resolvingAgainstBaseURL:NO].percentEncodedPath isEqual:@"/config%2Fvalue/configure"], "configure path keeps exact configured prefix");
        NSMutableDictionary *legacyManifest = [Manifest() mutableCopy];
        legacyManifest[@"catalogs"] = @[@{@"id":@"legacy",@"type":@"series",@"extraSupported":@[@"genre",@"search"],@"extraRequired":@[@"genre"],@"genres":@[@"Drama"]}];
        MSAddonCatalog *legacyCatalog = [MSAddon addonWithManifest:legacyManifest URL:URL error:nil].catalogs.firstObject;
        Check([legacyCatalog.name isEqual:@"legacy"] && [[legacyCatalog extraNamed:@"genre"] isRequired] && [[legacyCatalog extraNamed:@"genre"] options].count == 1, "legacy catalog extras normalize with fallback display name");
        Check(![legacyCatalog requestExtrasForValues:@{@"genre":@"Drama"} skip:1 error:nil], "unpaginated catalog rejects a second page");
        NSMutableDictionary *badCatalog = [CatalogManifest() mutableCopy]; badCatalog[@"catalogs"] = @[@{@"id":@"bad",@"type":@"movie",@"extra":@[@{@"name":@"genre",@"options":@[@1]}]}];
        Check(![MSAddon addonWithManifest:badCatalog URL:URL error:nil], "malformed catalog options rejected safely");
        badCatalog[@"catalogs"] = @[@{@"id":@"same",@"type":@"movie"},@{@"id":@"same",@"type":@"movie"}];
        Check(![MSAddon addonWithManifest:badCatalog URL:URL error:nil], "duplicate catalog identity rejected");
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
        NSMutableDictionary *requiresConfiguration = [CatalogManifest() mutableCopy]; requiresConfiguration[@"behaviorHints"] = @{@"configurationRequired":@YES};
        Check([MSAddon addonWithManifest:requiresConfiguration URL:URL error:nil].configurationRequired && ![store addManifest:requiresConfiguration URL:URL error:nil], "unconfigured preview parses but cannot be installed");
        Check([store addManifest:CatalogManifest() URL:URL error:&error], "custom add-on saved in private file storage");
        NSString *connectionID = store.addons.lastObject.connectionIdentifier;
        Check([[NSUUID alloc] initWithUUIDString:connectionID] != nil, "connection has a local UUID separate from manifest ID");
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
        Check([reloaded.addons.lastObject.connectionIdentifier isEqual:connectionID] && reloaded.addons.lastObject.catalogs.count == 1, "connection UUID and catalogs survive protected-store round trip");
        Check([reloaded addonForConnectionIdentifier:connectionID] == reloaded.addons.lastObject && reloaded.allCatalogs.count == 5, "catalog discovery resolves stable local origin");
        NSURL *updatedURL = [NSURL URLWithString:@"https://addons.example/updated/manifest.json"];
        NSData *oldBytes = TestSavedBytes(); TestFailCommit = YES;
        Check(![store replaceAddon:store.addons.lastObject manifest:Manifest() URL:updatedURL error:nil] && [oldBytes isEqual:TestSavedBytes()], "failed credential replacement preserves previous connection");
        TestFailCommit = NO;
        Check([store replaceAddon:store.addons.lastObject manifest:Manifest() URL:updatedURL error:nil] && store.addons.count == 3, "replacement commits without duplicate entry");
        Check([store.addons.lastObject.manifestURL isEqual:updatedURL], "replacement URL saved");
        Check([store.addons.lastObject.connectionIdentifier isEqual:connectionID] && [store.addons.lastObject.identifier isEqual:@"test.addon"], "credential replacement preserves connection and old playback identifier semantics");
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
        NSMutableSet *connectionIDs = [NSMutableSet set]; for (MSAddon *entry in store.addons) [connectionIDs addObject:entry.connectionIdentifier];
        Check(connectionIDs.count == store.addons.count, "same manifest ID at different configured URLs gets distinct connection UUIDs");
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
        NSData *legacyBytes = [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"addons":@[@{@"url":URL.absoluteString,@"manifest":CatalogManifest()}]} options:0 error:nil];
        Check([legacyBytes writeToURL:TestStoreFile() options:0 error:nil], "legacy schema fixture saved in isolated protected store");
        TestFailCommit = YES; MSAddonStore *failedMigration = [MSAddonStore new];
        Check(failedMigration.loadError != nil && [legacyBytes isEqual:TestSavedBytes()], "failed UUID migration preserves original legacy bytes");
        TestFailCommit = NO; MSAddonStore *migrated = [MSAddonStore new];
        NSDictionary *migratedDocument = [NSJSONSerialization JSONObjectWithData:TestSavedBytes() options:0 error:nil];
        NSString *migratedID = migrated.addons.lastObject.connectionIdentifier;
        Check(!migrated.loadError && [migratedDocument[@"version"] isEqual:@2] && [migrated.addons.lastObject.manifestURL isEqual:URL], "legacy migration preserves configured connection and writes schema two");
        Check([[MSAddonStore new].addons.lastObject.connectionIdentifier isEqual:migratedID], "migrated UUID remains stable on subsequent reload");
        NSMutableDictionary *future = [migratedDocument mutableCopy]; future[@"version"] = @99;
        NSData *futureBytes = [NSJSONSerialization dataWithJSONObject:future options:0 error:nil]; [futureBytes writeToURL:TestStoreFile() options:0 error:nil];
        Check(![migrated reloadWithError:nil] && [futureBytes isEqual:TestSavedBytes()], "unknown future schema remains untouched");
        Check([NSFileManager.defaultManager removeItemAtURL:TestRoot error:nil], "isolated temporary store cleaned up");
        printf("PASS: %lu add-on checks (isolated file store; iOS Data Protection requires device check)\n", (unsigned long)TestChecks);
    }
    return 0;
}
