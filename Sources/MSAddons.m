#import "MSAddons.h"
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdio.h>

NSString * const MSAddonsDidChangeNotification = @"MSAddonsDidChangeNotification";
static NSUInteger const MSMaximumStoreBytes = 512 * 1024;
static NSUInteger const MSMaximumCustomAddons = 12;
static NSUInteger const MSMaximumManifestBytes = 256 * 1024;

static NSError *MSAddonError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"MiniStreamAddons" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL MSSetAddonError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = MSAddonError(code, message); return NO;
}
static BOOL MSStringWithin(id value, NSUInteger limit) { return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= limit; }
static BOOL MSPathName(id value) {
    if (!MSStringWithin(value, 80)) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound && ![value isEqualToString:@"."] && ![value isEqualToString:@".."];
}
static BOOL MSStringArray(id value, BOOL requireNonempty, BOOL pathNames) {
    if (![value isKindOfClass:NSArray.class] || [value count] > 64 || (requireNonempty && ![value count])) return NO;
    for (id entry in value) if (!MSStringWithin(entry, 256) || (pathNames && !MSPathName(entry))) return NO;
    return YES;
}
static NSString *MSAddonEncode(NSString *value) {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
}

@interface MSAddon ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, strong, readwrite) NSURL *manifestURL;
@property(nonatomic, readwrite) BOOL builtIn;
@property(nonatomic, copy) NSDictionary *storedManifest;
@end

@implementation MSAddon
+ (NSURL *)manifestURLFromString:(NSString *)string error:(NSError **)error {
    if (![string isKindOfClass:NSString.class]) { MSSetAddonError(error, 1, @"Enter a complete HTTPS or stremio manifest address."); return nil; }
    NSString *trimmed = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || trimmed.length > 16384) { MSSetAddonError(error, 1, @"The add-on address is empty or too long."); return nil; }
    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    if ([components.scheme.lowercaseString isEqualToString:@"stremio"]) components.scheme = @"https";
    NSURL *URL = components.URL;
    if (!URL || ![components.scheme.lowercaseString isEqualToString:@"https"] || !components.host.length || components.user != nil || components.password != nil || components.fragment != nil || ![URL.lastPathComponent isEqualToString:@"manifest.json"]) {
        MSSetAddonError(error, 1, @"Use an HTTPS or stremio address ending in manifest.json, without a username, password or fragment."); return nil;
    }
    return URL;
}
+ (instancetype)addonWithManifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError **)error {
    NSURL *validatedURL = [self manifestURLFromString:URL.absoluteString error:error];
    if (!validatedURL) return nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:manifest]) { MSSetAddonError(error, 2, @"This address did not return a valid add-on manifest."); return nil; }
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    if (!encoded || encoded.length > MSMaximumManifestBytes) { MSSetAddonError(error, 2, @"The add-on manifest exceeds the supported size."); return nil; }
    if (!MSStringWithin(manifest[@"id"], 256) || !MSStringWithin(manifest[@"name"], 160) || !MSStringArray(manifest[@"types"], YES, YES) || ![manifest[@"resources"] isKindOfClass:NSArray.class] || ![manifest[@"resources"] count] || [manifest[@"resources"] count] > 32) {
        MSSetAddonError(error, 2, @"The add-on manifest is missing a valid name, identifier, types or resources."); return nil;
    }
    id globalPrefixes = manifest[@"idPrefixes"];
    if (globalPrefixes && !MSStringArray(globalPrefixes, NO, NO)) { MSSetAddonError(error, 2, @"The add-on's identifier filters are invalid."); return nil; }
    NSMutableArray *resources = [NSMutableArray array];
    for (id resource in manifest[@"resources"]) {
        if ([resource isKindOfClass:NSString.class] && MSPathName(resource)) { [resources addObject:resource]; continue; }
        if (![resource isKindOfClass:NSDictionary.class] || !MSPathName(resource[@"name"]) || !MSStringArray(resource[@"types"], YES, YES) || (resource[@"idPrefixes"] && !MSStringArray(resource[@"idPrefixes"], NO, NO))) {
            MSSetAddonError(error, 2, @"The add-on has an invalid resource description."); return nil;
        }
        NSMutableDictionary *descriptor = [@{@"name":resource[@"name"], @"types":resource[@"types"]} mutableCopy];
        if (resource[@"idPrefixes"]) descriptor[@"idPrefixes"] = resource[@"idPrefixes"];
        [resources addObject:descriptor];
    }
    NSMutableDictionary *stored = [@{@"id":manifest[@"id"], @"name":manifest[@"name"], @"types":manifest[@"types"], @"resources":resources} mutableCopy];
    if (globalPrefixes) stored[@"idPrefixes"] = globalPrefixes;
    NSData *canonical = [NSJSONSerialization dataWithJSONObject:stored options:0 error:nil];
    MSAddon *addon = [MSAddon new]; addon.identifier = manifest[@"id"]; addon.name = manifest[@"name"]; addon.manifestURL = validatedURL;
    addon.storedManifest = [NSJSONSerialization JSONObjectWithData:canonical options:0 error:nil];
    return addon;
}
- (BOOL)supportsResource:(NSString *)resource type:(NSString *)type identifier:(NSString *)identifier {
    if (!MSPathName(resource) || !MSPathName(type) || !MSStringWithin(identifier, 2048)) return NO;
    for (id entry in self.storedManifest[@"resources"]) {
        BOOL descriptor = [entry isKindOfClass:NSDictionary.class];
        NSString *name = descriptor ? entry[@"name"] : entry;
        if (![name isEqualToString:resource]) continue;
        NSArray *types = descriptor ? entry[@"types"] : self.storedManifest[@"types"];
        if (![types containsObject:type]) continue;
        // Object resource descriptors have their own optional prefix filter. Missing means all IDs.
        NSArray *prefixes = descriptor ? entry[@"idPrefixes"] : self.storedManifest[@"idPrefixes"];
        if ([resource isEqualToString:@"catalog"] || !prefixes) return YES;
        for (NSString *prefix in prefixes) if ([identifier hasPrefix:prefix]) return YES;
    }
    return NO;
}
- (NSURL *)resourceURL:(NSString *)resource type:(NSString *)type identifier:(NSString *)identifier extras:(NSDictionary<NSString *,NSString *> *)extras {
    if (![self supportsResource:resource type:type identifier:identifier] || (extras && (![extras isKindOfClass:NSDictionary.class] || extras.count > 16))) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:self.manifestURL resolvingAgainstBaseURL:NO];
    NSString *path = components.percentEncodedPath;
    NSRange separator = [path rangeOfString:@"/" options:NSBackwardsSearch];
    if (separator.location == NSNotFound) return nil;
    NSString *base = [path substringToIndex:separator.location];
    NSMutableString *suffix = [NSMutableString stringWithFormat:@"/%@/%@/%@", MSAddonEncode(resource), MSAddonEncode(type), MSAddonEncode(identifier)];
    if (extras.count) {
        for (id key in extras) if (!MSStringWithin(key, 80) || ![extras[key] isKindOfClass:NSString.class] || [extras[key] length] > 4096) return nil;
        NSMutableArray *pairs = [NSMutableArray array];
        for (NSString *key in [[extras allKeys] sortedArrayUsingSelector:@selector(compare:)]) [pairs addObject:[NSString stringWithFormat:@"%@=%@", MSAddonEncode(key), MSAddonEncode(extras[key])]];
        [suffix appendFormat:@"/%@", [pairs componentsJoinedByString:@"&"]];
    }
    [suffix appendString:@".json"];
    components.percentEncodedPath = [base stringByAppendingString:suffix];
    // The configured query is intentionally retained verbatim by NSURLComponents.
    return components.URL;
}
@end

@interface MSAddonStore ()
@property(nonatomic, copy, readwrite) NSArray<MSAddon *> *addons;
@property(nonatomic, strong, readwrite) NSError *loadError;
@property(nonatomic, copy) NSArray<MSAddon *> *builtIns;
@end
@implementation MSAddonStore
+ (instancetype)sharedStore { static MSAddonStore *store; static dispatch_once_t once; dispatch_once(&once, ^{ store = [MSAddonStore new]; }); return store; }
- (instancetype)init {
    if ((self = [super init])) {
        MSAddon *cinemeta = [MSAddon addonWithManifest:@{@"id":@"com.linvo.cinemeta", @"name":@"Cinemeta", @"types":@[@"movie", @"series"], @"resources":@[@"catalog", @"meta"], @"idPrefixes":@[@"tt"]} URL:[NSURL URLWithString:@"https://v3-cinemeta.strem.io/manifest.json"] error:nil];
        MSAddon *subtitles = [MSAddon addonWithManifest:@{@"id":@"org.stremio.opensubtitlesv3", @"name":@"OpenSubtitles v3", @"types":@[@"movie", @"series"], @"resources":@[@"subtitles"], @"idPrefixes":@[@"tt"]} URL:[NSURL URLWithString:@"https://opensubtitles-v3.strem.io/manifest.json"] error:nil];
        cinemeta.builtIn = YES; subtitles.builtIn = YES; _builtIns = @[cinemeta, subtitles]; _addons = _builtIns;
        [self reloadWithError:nil];
    }
    return self;
}
- (NSURL *)storageDirectory {
#ifdef MS_ADDON_STORE_TESTING
    extern NSURL *MSAddonTestStorageDirectory(void);
    return MSAddonTestStorageDirectory();
#else
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"MiniStream" isDirectory:YES];
#endif
}
- (NSURL *)storageFile { return [[self storageDirectory] URLByAppendingPathComponent:@"addons.json" isDirectory:NO]; }
- (NSDictionary *)protectedAttributesWithMode:(NSUInteger)mode {
#ifdef MS_ADDON_STORE_TESTING
    // macOS host tests exercise atomic file behavior in an isolated temporary folder.
    // NSFileProtectionComplete itself is verified by the separate iOS device harness.
    return @{NSFilePosixPermissions:@(mode)};
#else
    return @{NSFilePosixPermissions:@(mode), NSFileProtectionKey:NSFileProtectionComplete};
#endif
}
- (BOOL)hasRequiredProtection:(NSURL *)URL mode:(NSUInteger)mode directory:(BOOL)directory {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:URL.path error:nil];
    if (![attributes[NSFileType] isEqual:directory ? NSFileTypeDirectory : NSFileTypeRegular] || ([attributes[NSFilePosixPermissions] unsignedIntegerValue] & 0777) != mode) return NO;
#ifndef MS_ADDON_STORE_TESTING
    if (![attributes[NSFileProtectionKey] isEqual:NSFileProtectionComplete]) return NO;
#endif
    NSNumber *excluded = nil;
    return [URL getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil] && excluded.boolValue;
}
- (BOOL)prepareStorageDirectory {
    NSURL *directory = [self storageDirectory];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:directory.path error:nil];
    if (attributes && ![attributes[NSFileType] isEqual:NSFileTypeDirectory]) return NO;
    if (!attributes && ![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:[self protectedAttributesWithMode:0700] error:nil]) return NO;
    if (![NSFileManager.defaultManager setAttributes:[self protectedAttributesWithMode:0700] ofItemAtPath:directory.path error:nil]) return NO;
    if (![directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil]) return NO;
    return [self hasRequiredProtection:directory mode:0700 directory:YES];
}
- (BOOL)reloadWithError:(NSError **)error {
    NSURL *file = [self storageFile]; NSError *readError = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:&readError];
    if (!attributes && [readError.domain isEqual:NSCocoaErrorDomain] && (readError.code == NSFileReadNoSuchFileError || readError.code == NSFileNoSuchFileError)) {
        self.addons = self.builtIns; self.loadError = nil; return YES;
    }
    if (!attributes || ![self hasRequiredProtection:[self storageDirectory] mode:0700 directory:YES] || ![self hasRequiredProtection:file mode:0600 directory:NO] || [attributes[NSFileSize] unsignedLongLongValue] > MSMaximumStoreBytes) {
        self.loadError = MSAddonError(3, @"Saved add-ons could not be read from protected app storage. Unlock this iPad and try again. Saved data has not been replaced.");
        if (error) *error = self.loadError; return NO;
    }
    NSData *data = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:file.path];
    @try {
        data = [handle readDataOfLength:MSMaximumStoreBytes + 1];
    } @catch (__unused NSException *exception) { data = nil; }
    @finally { [handle closeFile]; }
    id saved = data.length && data.length <= MSMaximumStoreBytes ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![saved isKindOfClass:NSDictionary.class] || ![saved[@"version"] isEqual:@1] || ![saved[@"addons"] isKindOfClass:NSArray.class] || [saved[@"addons"] count] > MSMaximumCustomAddons) {
        self.loadError = MSAddonError(3, @"Saved add-ons could not be decoded. They have not been replaced."); if (error) *error = self.loadError; return NO;
    }
    NSMutableArray *addons = [self.builtIns mutableCopy];
    for (id entry in saved[@"addons"]) {
        MSAddon *addon = nil;
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"url"] isKindOfClass:NSString.class]) {
            NSURL *URL = [MSAddon manifestURLFromString:entry[@"url"] error:nil];
            if (URL) addon = [MSAddon addonWithManifest:entry[@"manifest"] URL:URL error:nil];
        }
        if (!addon) { self.loadError = MSAddonError(3, @"A saved add-on is invalid. Saved entries have not been replaced."); if (error) *error = self.loadError; return NO; }
        [addons addObject:addon];
    }
    self.addons = addons; self.loadError = nil; return YES;
}
- (BOOL)saveCustomAddons:(NSArray<MSAddon *> *)custom error:(NSError **)error {
    NSMutableArray *entries = [NSMutableArray array];
    for (MSAddon *addon in custom) [entries addObject:@{@"url":addon.manifestURL.absoluteString, @"manifest":addon.storedManifest}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"addons":entries} options:0 error:nil];
    if (!data || data.length > MSMaximumStoreBytes) return MSSetAddonError(error, 4, @"The add-on list exceeds the 512 KiB protected-storage limit.");
    if (![self prepareStorageDirectory]) return MSSetAddonError(error, 4, @"Protected app storage is unavailable. Unlock this iPad and try again. Nothing was changed.");
    NSURL *temporary = [[self storageDirectory] URLByAppendingPathComponent:[NSString stringWithFormat:@".addons-%@.tmp", NSUUID.UUID.UUIDString]];
    NSDataWritingOptions options = NSDataWritingWithoutOverwriting;
#ifndef MS_ADDON_STORE_TESTING
    options |= NSDataWritingFileProtectionComplete;
#endif
    BOOL prepared = [data writeToURL:temporary options:options error:nil]
        && [NSFileManager.defaultManager setAttributes:[self protectedAttributesWithMode:0600] ofItemAtPath:temporary.path error:nil]
        && [temporary setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil]
        && [self hasRequiredProtection:temporary mode:0600 directory:NO];
    if (prepared) {
        int descriptor = open(temporary.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
        prepared = descriptor >= 0 && fsync(descriptor) == 0;
        if (descriptor >= 0) close(descriptor);
    }
#ifdef MS_ADDON_STORE_TESTING
    extern BOOL MSAddonTestFailCommit(void);
    if (MSAddonTestFailCommit()) prepared = NO;
#endif
    // The destination is replaced only after the new bytes and their protection are
    // ready. A failed preparation/rename leaves the previous file intact.
    BOOL committed = prepared && rename(temporary.fileSystemRepresentation, [self storageFile].fileSystemRepresentation) == 0;
    if (!committed) {
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
        return MSSetAddonError(error, 4, @"The add-on could not be saved in protected app storage. Unlock this iPad and try again. Nothing was changed.");
    }
    self.addons = [self.builtIns arrayByAddingObjectsFromArray:custom]; self.loadError = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:MSAddonsDidChangeNotification object:self];
    return YES;
}
- (BOOL)addManifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError **)error {
    MSAddon *addon = [MSAddon addonWithManifest:manifest URL:URL error:error]; if (!addon) return NO;
    if (![self reloadWithError:error]) return NO;
    NSMutableArray *custom = [NSMutableArray array];
    for (MSAddon *existing in self.addons) {
        if ([existing.manifestURL.absoluteString isEqualToString:addon.manifestURL.absoluteString]) return MSSetAddonError(error, 5, @"This add-on is already installed.");
        if (!existing.builtIn) [custom addObject:existing];
    }
    if (custom.count >= MSMaximumCustomAddons) return MSSetAddonError(error, 5, @"You can add up to 12 custom add-ons. Remove one before adding another.");
    [custom addObject:addon]; return [self saveCustomAddons:custom error:error];
}
- (BOOL)replaceAddon:(MSAddon *)existing manifest:(NSDictionary *)manifest URL:(NSURL *)URL error:(NSError **)error {
    if (existing.builtIn) return MSSetAddonError(error, 5, @"Built-in add-ons cannot be replaced.");
    MSAddon *replacement = [MSAddon addonWithManifest:manifest URL:URL error:error];
    if (!replacement || ![self reloadWithError:error]) return NO;
    NSMutableArray *custom = [NSMutableArray array]; BOOL found = NO;
    for (MSAddon *entry in self.addons) {
        if ([entry.manifestURL.absoluteString isEqual:existing.manifestURL.absoluteString] && !entry.builtIn) {
            [custom addObject:replacement]; found = YES;
        } else {
            if ([entry.manifestURL.absoluteString isEqual:replacement.manifestURL.absoluteString]) return MSSetAddonError(error, 5, @"That connection is already installed.");
            if (!entry.builtIn) [custom addObject:entry];
        }
    }
    if (!found) return MSSetAddonError(error, 5, @"This connection is no longer installed.");
    return [self saveCustomAddons:custom error:error];
}
- (BOOL)removeAddon:(MSAddon *)addon error:(NSError **)error {
    if (addon.builtIn) return MSSetAddonError(error, 5, @"Built-in add-ons cannot be removed.");
    if (![self reloadWithError:error]) return NO;
    NSMutableArray *custom = [NSMutableArray array]; BOOL found = NO;
    for (MSAddon *existing in self.addons) {
        if (existing.builtIn) continue;
        if ([existing.manifestURL.absoluteString isEqualToString:addon.manifestURL.absoluteString]) found = YES;
        else [custom addObject:existing];
    }
    if (!found) return MSSetAddonError(error, 5, @"This add-on is no longer installed.");
    return [self saveCustomAddons:custom error:error];
}
@end
