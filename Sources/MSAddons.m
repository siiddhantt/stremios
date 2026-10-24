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

@interface MSAddonCatalogExtra ()
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, readwrite) BOOL isRequired;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *options;
@property(nonatomic, readwrite) NSUInteger optionsLimit;
@end
@implementation MSAddonCatalogExtra
@end

@interface MSAddonCatalog ()
@property(nonatomic, copy, readwrite) NSString *connectionIdentifier, *addonName, *identifier, *type, *name;
@property(nonatomic, copy, readwrite) NSArray<MSAddonCatalogExtra *> *extras;
@end
@implementation MSAddonCatalog
- (NSString *)identity { return [NSString stringWithFormat:@"%@/%@/%@", self.connectionIdentifier, MSAddonEncode(self.type), MSAddonEncode(self.identifier)]; }
- (MSAddonCatalogExtra *)extraNamed:(NSString *)name { for (MSAddonCatalogExtra *extra in self.extras) if ([extra.name isEqual:name]) return extra; return nil; }
- (NSDictionary *)requestExtrasForValues:(NSDictionary *)values skip:(NSUInteger)skip error:(NSError **)error {
    if ((values && ![values isKindOfClass:NSDictionary.class]) || values.count > 16 || skip > 100000) {
        MSSetAddonError(error, 7, @"The catalog filters exceed the supported limit."); return nil;
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (id key in values) {
        MSAddonCatalogExtra *extra = [key isKindOfClass:NSString.class] ? [self extraNamed:key] : nil;
        id value = values[key];
        if (!extra || [key isEqual:@"skip"] || ![value isKindOfClass:NSString.class] || [value length] > ([key isEqual:@"search"] ? 200 : 1024) || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            MSSetAddonError(error, 7, @"A catalog filter is unsupported or invalid."); return nil;
        }
        if (![value length]) continue;
        // This client offers one declared option per filter. Do not guess how a
        // provider serializes multiple options or silently truncate its values.
        if (extra.options.count && ![extra.options containsObject:value]) { MSSetAddonError(error, 7, @"Choose one of this catalog's available filter values."); return nil; }
        result[key] = value;
    }
    MSAddonCatalogExtra *paging = [self extraNamed:@"skip"];
    if (paging) {
        NSString *cursor = [NSString stringWithFormat:@"%lu", (unsigned long)skip];
        if (skip && paging.options.count && ![paging.options containsObject:cursor]) { MSSetAddonError(error,7,@"This catalog does not support that page offset."); return nil; }
        result[@"skip"] = cursor;
    }
    else if (skip) { MSSetAddonError(error, 7, @"This catalog does not support more pages."); return nil; }
    for (MSAddonCatalogExtra *extra in self.extras) if (extra.isRequired && ![result[extra.name] length]) {
        MSSetAddonError(error, 7, @"Choose the required catalog filters before loading titles."); return nil;
    }
    return result;
}
@end

static BOOL MSUUIDString(id value) { return MSStringWithin(value, 36) && [[NSUUID alloc] initWithUUIDString:value] != nil; }
static BOOL MSManifestText(id value, NSUInteger limit) {
    return MSStringWithin(value, limit) && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static NSArray *MSCatalogDefinitions(id raw, NSError **error) {
    if (!raw) return @[];
    if (![raw isKindOfClass:NSArray.class] || [raw count] > 64) { MSSetAddonError(error, 2, @"The add-on has too many or invalid catalogs."); return nil; }
    NSMutableArray *catalogs = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (id entry in raw) {
        if (![entry isKindOfClass:NSDictionary.class] || !MSPathName(entry[@"type"]) || !MSManifestText(entry[@"id"],256) || [entry[@"id"] containsString:@"://"] || (entry[@"name"] && !MSManifestText(entry[@"name"],160))) {
            MSSetAddonError(error, 2, @"The add-on has an invalid catalog description."); return nil;
        }
        NSString *identity = [NSString stringWithFormat:@"%@/%@",entry[@"type"],MSAddonEncode(entry[@"id"])];
        if ([seen containsObject:identity]) { MSSetAddonError(error,2,@"The add-on contains duplicate catalogs."); return nil; } [seen addObject:identity];
        id extraInput = entry[@"extra"];
        if (!extraInput) {
            id supported = entry[@"extraSupported"], required = entry[@"extraRequired"];
            if ((supported && !MSStringArray(supported,NO,YES)) || (required && !MSStringArray(required,NO,YES))) { MSSetAddonError(error,2,@"The catalog's legacy filters are invalid."); return nil; }
            NSMutableArray *legacy = [NSMutableArray array];
            NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSetWithArray:supported ?: @[]]; [names addObjectsFromArray:required ?: @[]];
            for (NSString *name in names) {
                NSMutableDictionary *extra = [@{@"name":name,@"isRequired":@([required containsObject:name])} mutableCopy];
                if ([name isEqual:@"genre"] && entry[@"genres"]) extra[@"options"] = entry[@"genres"];
                [legacy addObject:extra];
            } extraInput = legacy;
        }
        if (![extraInput isKindOfClass:NSArray.class] || [extraInput count] > 16) { MSSetAddonError(error,2,@"The catalog has too many or invalid filters."); return nil; }
        NSMutableArray *extras = [NSMutableArray array]; NSMutableSet *extraNames = [NSMutableSet set];
        for (id rawExtra in extraInput) {
            if (![rawExtra isKindOfClass:NSDictionary.class] || !MSPathName(rawExtra[@"name"]) || [extraNames containsObject:rawExtra[@"name"]] ||
                (rawExtra[@"isRequired"] && ![rawExtra[@"isRequired"] isKindOfClass:NSNumber.class])) { MSSetAddonError(error,2,@"The catalog has an invalid filter description."); return nil; }
            id options = rawExtra[@"options"] ?: @[];
            if (![options isKindOfClass:NSArray.class] || [options count] > 256) { MSSetAddonError(error,2,@"The catalog filter options exceed the supported limit."); return nil; }
            NSMutableArray *cleanOptions = [NSMutableArray array];
            for (id option in options) {
                if (!MSManifestText(option,256)) { MSSetAddonError(error,2,@"The catalog contains an invalid filter option."); return nil; }
                if ([rawExtra[@"name"] isEqual:@"skip"] && ([option length] > 6 || [option rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound || [option integerValue] > 100000 || ![[NSString stringWithFormat:@"%ld",(long)[option integerValue]] isEqual:option])) { MSSetAddonError(error,2,@"The catalog page offsets are invalid."); return nil; }
                if (![cleanOptions containsObject:option]) [cleanOptions addObject:option];
            }
            id limit = rawExtra[@"optionsLimit"];
            if (limit && (![limit isKindOfClass:NSNumber.class] || [limit doubleValue] < 1 || [limit doubleValue] > 256 || [limit doubleValue] != [limit integerValue])) { MSSetAddonError(error,2,@"The catalog filter selection limit is invalid."); return nil; }
            [extras addObject:@{@"name":rawExtra[@"name"],@"isRequired":@([rawExtra[@"isRequired"] boolValue]),@"options":cleanOptions,@"optionsLimit":limit ?: @1}];
            [extraNames addObject:rawExtra[@"name"]];
        }
        [catalogs addObject:@{@"type":entry[@"type"],@"id":entry[@"id"],@"name":entry[@"name"] ?: entry[@"id"],@"extra":extras}];
    }
    return catalogs;
}

static NSArray *MSConfigurationFields(id raw) {
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (id field in raw) {
        if (result.count >= 32) break;
        if (![field isKindOfClass:NSDictionary.class] || !MSManifestText(field[@"key"],80) || ![@[@"text",@"string",@"number",@"password",@"checkbox",@"boolean",@"select"] containsObject:field[@"type"]]) continue;
        NSMutableDictionary *clean = [@{@"key":field[@"key"],@"type":field[@"type"],@"required":@([field[@"required"] respondsToSelector:@selector(boolValue)] && [field[@"required"] boolValue])} mutableCopy];
        if (MSManifestText(field[@"title"],160)) clean[@"title"] = field[@"title"];
        if ([field[@"options"] isKindOfClass:NSArray.class] && [field[@"options"] count] <= 128) {
            NSMutableArray *options = [NSMutableArray array]; for (id option in field[@"options"]) if (MSManifestText(option,256)) [options addObject:option]; clean[@"options"] = options;
        }
        // Never retain configuration defaults: even a text field may contain a key.
        [result addObject:clean];
    } return result;
}

@interface MSAddon ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *connectionIdentifier;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, strong, readwrite) NSURL *manifestURL;
@property(nonatomic, readwrite) BOOL builtIn;
@property(nonatomic, copy) NSDictionary *storedManifest;
- (void)useConnectionIdentifier:(NSString *)identifier;
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
    NSArray *catalogs = MSCatalogDefinitions(manifest[@"catalogs"], error); if (!catalogs) return nil;
    NSMutableDictionary *stored = [@{@"id":manifest[@"id"], @"name":manifest[@"name"], @"types":manifest[@"types"], @"resources":resources, @"catalogs":catalogs} mutableCopy];
    if (globalPrefixes) stored[@"idPrefixes"] = globalPrefixes;
    if (MSManifestText(manifest[@"version"],80)) stored[@"version"] = manifest[@"version"];
    NSDictionary *hints = [manifest[@"behaviorHints"] isKindOfClass:NSDictionary.class] ? manifest[@"behaviorHints"] : @{};
    stored[@"behaviorHints"] = @{@"configurable":@([hints[@"configurable"] respondsToSelector:@selector(boolValue)] && [hints[@"configurable"] boolValue]),@"configurationRequired":@([hints[@"configurationRequired"] respondsToSelector:@selector(boolValue)] && [hints[@"configurationRequired"] boolValue])};
    stored[@"config"] = MSConfigurationFields(manifest[@"config"]);
    NSData *canonical = [NSJSONSerialization dataWithJSONObject:stored options:0 error:nil];
    MSAddon *addon = [MSAddon new]; addon.identifier = manifest[@"id"]; addon.name = manifest[@"name"]; addon.manifestURL = validatedURL;
    addon.storedManifest = [NSJSONSerialization JSONObjectWithData:canonical options:0 error:nil];
    [addon useConnectionIdentifier:NSUUID.UUID.UUIDString];
    return addon;
}
- (void)useConnectionIdentifier:(NSString *)identifier { self.connectionIdentifier = identifier.uppercaseString; }
- (NSString *)version { return self.storedManifest[@"version"] ?: @""; }
- (BOOL)configurable { return [self.storedManifest[@"behaviorHints"][@"configurable"] boolValue] || self.configurationRequired; }
- (BOOL)configurationRequired { return [self.storedManifest[@"behaviorHints"][@"configurationRequired"] boolValue]; }
- (NSArray *)configurationFields { return self.storedManifest[@"config"] ?: @[]; }
- (NSURL *)configureURL {
    if (!self.configurable) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:self.manifestURL resolvingAgainstBaseURL:NO];
    NSRange slash = [parts.percentEncodedPath rangeOfString:@"/" options:NSBackwardsSearch]; if (slash.location == NSNotFound) return nil;
    parts.percentEncodedPath = [[parts.percentEncodedPath substringToIndex:slash.location] stringByAppendingString:@"/configure"]; return parts.URL;
}
- (NSArray<MSAddonCatalog *> *)catalogs {
    NSMutableArray *catalogs = [NSMutableArray array];
    for (NSDictionary *definition in self.storedManifest[@"catalogs"]) {
        if (![self supportsResource:@"catalog" type:definition[@"type"] identifier:definition[@"id"]]) continue;
        MSAddonCatalog *catalog = [MSAddonCatalog new]; catalog.connectionIdentifier = self.connectionIdentifier; catalog.addonName = self.name;
        catalog.identifier = definition[@"id"]; catalog.type = definition[@"type"]; catalog.name = definition[@"name"];
        NSMutableArray *extras = [NSMutableArray array];
        for (NSDictionary *raw in definition[@"extra"]) { MSAddonCatalogExtra *extra = [MSAddonCatalogExtra new]; extra.name = raw[@"name"]; extra.isRequired = [raw[@"isRequired"] boolValue]; extra.options = raw[@"options"]; extra.optionsLimit = [raw[@"optionsLimit"] unsignedIntegerValue]; [extras addObject:extra]; }
        catalog.extras = extras; [catalogs addObject:catalog];
    } return catalogs;
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
        // Offline fallback descriptors from Cinemeta's public manifest. Other
        // connections use their own validated manifest catalogs and options.
        NSArray *genres = @[@"Action",@"Adventure",@"Animation",@"Biography",@"Comedy",@"Crime",@"Documentary",@"Drama",@"Family",@"Fantasy",@"History",@"Horror",@"Mystery",@"Romance",@"Sci-Fi",@"Sport",@"Thriller",@"War",@"Western"];
        NSMutableArray *catalogs = [NSMutableArray array];
        for (NSString *type in @[@"movie",@"series"]) {
            NSArray *options = [type isEqual:@"series"] ? [genres arrayByAddingObjectsFromArray:@[@"Reality-TV",@"Talk-Show",@"Game-Show"]] : genres;
            [catalogs addObject:@{@"id":@"top",@"type":type,@"name":@"Popular",@"extra":@[@{@"name":@"genre",@"options":options},@{@"name":@"search"},@{@"name":@"skip"}]}];
            [catalogs addObject:@{@"id":@"imdbRating",@"type":type,@"name":@"Featured",@"extra":@[@{@"name":@"genre",@"options":options},@{@"name":@"skip"}]}];
        }
        MSAddon *cinemeta = [MSAddon addonWithManifest:@{@"id":@"com.linvo.cinemeta", @"name":@"Cinemeta", @"types":@[@"movie", @"series"], @"resources":@[@"catalog", @"meta"], @"idPrefixes":@[@"tt"], @"catalogs":catalogs} URL:[NSURL URLWithString:@"https://v3-cinemeta.strem.io/manifest.json"] error:nil];
        MSAddon *subtitles = [MSAddon addonWithManifest:@{@"id":@"org.stremio.opensubtitlesv3", @"name":@"OpenSubtitles v3", @"types":@[@"movie", @"series"], @"resources":@[@"subtitles"], @"idPrefixes":@[@"tt"]} URL:[NSURL URLWithString:@"https://opensubtitles-v3.strem.io/manifest.json"] error:nil];
        [cinemeta useConnectionIdentifier:@"30B97DE2-D386-4F82-BB7B-0D57E7100001"];
        [subtitles useConnectionIdentifier:@"30B97DE2-D386-4F82-BB7B-0D57E7100002"];
        cinemeta.builtIn = YES; subtitles.builtIn = YES; _builtIns = @[cinemeta, subtitles]; _addons = _builtIns;
        [self reloadWithError:nil];
    }
    return self;
}
- (NSArray<MSAddonCatalog *> *)allCatalogs {
    NSMutableArray *catalogs = [NSMutableArray array];
    for (MSAddon *addon in self.addons) if (!addon.configurationRequired) [catalogs addObjectsFromArray:addon.catalogs];
    return catalogs;
}
- (MSAddon *)addonForConnectionIdentifier:(NSString *)identifier {
    if (!MSUUIDString(identifier)) return nil;
    for (MSAddon *addon in self.addons) if ([addon.connectionIdentifier caseInsensitiveCompare:identifier] == NSOrderedSame) return addon;
    return nil;
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
    BOOL legacy = [saved isKindOfClass:NSDictionary.class] && [saved[@"version"] isEqual:@1];
    if (![saved isKindOfClass:NSDictionary.class] || (!legacy && ![saved[@"version"] isEqual:@2]) || ![saved[@"addons"] isKindOfClass:NSArray.class] || [saved[@"addons"] count] > MSMaximumCustomAddons) {
        self.loadError = MSAddonError(3, @"Saved add-ons could not be decoded. They have not been replaced."); if (error) *error = self.loadError; return NO;
    }
    NSMutableArray *addons = [self.builtIns mutableCopy]; NSMutableSet *identities = [NSMutableSet set];
    for (MSAddon *addon in self.builtIns) [identities addObject:addon.connectionIdentifier];
    for (id entry in saved[@"addons"]) {
        MSAddon *addon = nil;
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"url"] isKindOfClass:NSString.class]) {
            NSURL *URL = [MSAddon manifestURLFromString:entry[@"url"] error:nil];
            if (URL) addon = [MSAddon addonWithManifest:entry[@"manifest"] URL:URL error:nil];
        }
        NSString *connection = legacy ? NSUUID.UUID.UUIDString : ([entry isKindOfClass:NSDictionary.class] ? entry[@"connectionIdentifier"] : nil);
        if (!addon || !MSUUIDString(connection) || [identities containsObject:connection.uppercaseString]) { self.loadError = MSAddonError(3, @"A saved add-on is invalid. Saved entries have not been replaced."); if (error) *error = self.loadError; return NO; }
        [addon useConnectionIdentifier:connection]; [identities addObject:addon.connectionIdentifier];
        [addons addObject:addon];
    }
    if (legacy) {
        NSArray *custom = [addons subarrayWithRange:NSMakeRange(self.builtIns.count, addons.count - self.builtIns.count)];
        NSError *migrationError = nil;
        if (![self saveCustomAddons:custom error:&migrationError]) {
            self.loadError = MSAddonError(3,@"Saved add-ons could not be upgraded in protected storage. Previous data was kept. Unlock this iPad and try again.");
            if (error) *error = self.loadError; return NO;
        }
        return YES;
    }
    self.addons = addons; self.loadError = nil; return YES;
}
- (BOOL)saveCustomAddons:(NSArray<MSAddon *> *)custom error:(NSError **)error {
    NSMutableArray *entries = [NSMutableArray array];
    for (MSAddon *addon in custom) [entries addObject:@{@"url":addon.manifestURL.absoluteString, @"manifest":addon.storedManifest,@"connectionIdentifier":addon.connectionIdentifier}];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@2, @"addons":entries} options:0 error:nil];
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
    if (addon.configurationRequired) return MSSetAddonError(error,8,@"Configure this add-on first, then paste its completed manifest link.");
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
    if (replacement.configurationRequired) return MSSetAddonError(error,8,@"Configure this add-on first, then paste its completed manifest link.");
    NSMutableArray *custom = [NSMutableArray array]; BOOL found = NO;
    for (MSAddon *entry in self.addons) {
        if ([entry.manifestURL.absoluteString isEqual:existing.manifestURL.absoluteString] && !entry.builtIn) {
            [replacement useConnectionIdentifier:entry.connectionIdentifier];
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
