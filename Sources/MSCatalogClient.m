#import "MSCatalogClient.h"
#import "MSHTTPClient.h"
#import "MSAddons.h"
#import <math.h>
static NSString *MSString(id value, NSUInteger limit) { return [value isKindOfClass:NSString.class] ? ([value length] > limit ? [value substringToIndex:limit] : value) : @""; }
static NSString *MSIMDbRating(id value) {
    NSString *text = nil;
    if ([value isKindOfClass:NSString.class] && [value length] <= 16)
        text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    else if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
        text = [value stringValue];
    if (!text.length || text.length > 16) return @"";
    static NSRegularExpression *decimal; static dispatch_once_t once;
    dispatch_once(&once, ^{ decimal = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?:\\.[0-9]+)?$" options:0 error:nil]; });
    if (![decimal firstMatchInString:text options:0 range:NSMakeRange(0,text.length)]) return @"";
    double number = text.doubleValue;
    return isfinite(number) && number >= 0 && number <= 10 ? [NSString stringWithFormat:@"%.1f",number] : @"";
}
@implementation MSEpisode
+ (instancetype)fromDictionary:(NSDictionary *)raw {
    NSString *identifier = [raw[@"id"] isKindOfClass:NSString.class] && [raw[@"id"] length] <= 1024 ? raw[@"id"] : @""; if (!identifier.length) return nil;
    MSEpisode *episode = [self new]; episode->_identifier = identifier;
    episode->_title = MSString(raw[@"title"] ?: raw[@"name"], 300);
    episode->_season = [raw[@"season"] respondsToSelector:@selector(integerValue)] ? MAX(0, [raw[@"season"] integerValue]) : 0;
    episode->_episode = [raw[@"episode"] respondsToSelector:@selector(integerValue)] ? MAX(0, [raw[@"episode"] integerValue]) : 0;
    episode->_released = MSString(raw[@"released"], 80); return episode;
}
@end
@implementation MSMetadata
+ (instancetype)metadataWithDictionary:(NSDictionary *)raw fallbackType:(NSString *)type {
    return [self metadataWithDictionary:raw fallbackType:type originConnectionIdentifier:nil];
}
+ (instancetype)metadataWithDictionary:(NSDictionary *)raw fallbackType:(NSString *)type originConnectionIdentifier:(NSString *)connectionIdentifier {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    NSString *identifier = [raw[@"id"] isKindOfClass:NSString.class] && [raw[@"id"] length] <= 1024 ? raw[@"id"] : @"", *title = MSString(raw[@"name"], 400);
    if (!identifier.length || !title.length) return nil;
    MSMetadata *item = [self new]; item->_identifier = identifier; item->_title = title;
    NSDictionary *hints = [raw[@"behaviorHints"] isKindOfClass:NSDictionary.class] ? raw[@"behaviorHints"] : @{};
    id videoID = hints[@"defaultVideoId"];
    BOOL validVideoID = [videoID isKindOfClass:NSString.class] && [videoID length] > 0 && [videoID length] <= 1024 && [videoID rangeOfString:@"://"].location == NSNotFound && [videoID rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
    item->_defaultVideoIdentifier = validVideoID ? [videoID copy] : identifier;
    if ([connectionIdentifier isKindOfClass:NSString.class] && connectionIdentifier.length == 36 && [[NSUUID alloc] initWithUUIDString:connectionIdentifier]) item->_originConnectionIdentifier = connectionIdentifier.uppercaseString;
    item->_type = [@[@"movie", @"series"] containsObject:raw[@"type"]] ? raw[@"type"] : type;
    item->_releaseInfo = MSString(raw[@"releaseInfo"], 80); item->_runtime = MSString(raw[@"runtime"], 80); item->_summary = MSString(raw[@"description"], 12000);
    item->_imdbRating = MSIMDbRating(raw[@"imdbRating"]);
    NSURL *poster = [NSURL URLWithString:MSString(raw[@"poster"], 4096)]; item->_posterURL = MSIsSafeRemoteURL(poster) ? poster : nil;
    NSURL *background = [NSURL URLWithString:MSString(raw[@"background"], 4096)]; item->_backgroundURL = MSIsSafeRemoteURL(background) ? background : nil;
    NSString *logoText = [raw[@"logo"] isKindOfClass:NSString.class] && [raw[@"logo"] length] <= 4096 ? raw[@"logo"] : nil;
    NSURL *logo = logoText.length ? [NSURL URLWithString:logoText] : nil; item->_logoURL = MSIsSafeRemoteURL(logo) ? logo : nil;
    NSMutableArray *genres = [NSMutableArray array], *episodes = [NSMutableArray array];
    if ([raw[@"genres"] isKindOfClass:NSArray.class]) for (id genre in raw[@"genres"]) { if (genres.count >= 20) break; if ([genre isKindOfClass:NSString.class]) [genres addObject:MSString(genre, 80)]; }
    if ([raw[@"videos"] isKindOfClass:NSArray.class]) for (id video in raw[@"videos"]) { if (episodes.count >= 5000) break; if ([video isKindOfClass:NSDictionary.class]) { MSEpisode *e = [MSEpisode fromDictionary:video]; if(e) [episodes addObject:e]; } }
    [episodes sortUsingComparator:^NSComparisonResult(MSEpisode *a, MSEpisode *b) { if (a.season != b.season) return a.season < b.season ? NSOrderedAscending : NSOrderedDescending; return a.episode < b.episode ? NSOrderedAscending : a.episode > b.episode ? NSOrderedDescending : NSOrderedSame; }];
    item->_genres = [genres copy]; item->_episodes = [episodes copy]; return item;
}
@end
@interface MSCatalogPage ()
@property(nonatomic,copy,readwrite) NSArray<MSMetadata *> *items;
@property(nonatomic,readwrite) NSUInteger receivedCount, nextSkip;
@property(nonatomic,readwrite) BOOL hasMore;
@end
@implementation MSCatalogPage
@end

@interface MSCatalogOperation : NSObject <MSCancellable>
@property(atomic) BOOL cancelled;
@property(nonatomic) BOOL finished;
@property(nonatomic,strong) id<MSCancellable> request;
@property(nonatomic,copy) void (^completion)(MSMetadata *,NSError *);
@property(nonatomic,copy) NSArray<MSAddon *> *addons;
@property(nonatomic,copy) NSString *type, *identifier;
@property(nonatomic) NSUInteger index;
@end
@implementation MSCatalogOperation
- (void)cancel { self.cancelled = YES; [self.request cancel]; self.request = nil; self.completion = nil; }
- (void)finish:(MSMetadata *)metadata error:(NSError *)error {
    if (self.finished || self.cancelled) return;
    self.finished = YES; self.request = nil;
    void (^completion)(MSMetadata *,NSError *) = self.completion; self.completion = nil;
    if (completion) completion(metadata,error);
}
- (void)loadNext {
    if (self.cancelled || self.finished) return;
    if (self.index >= self.addons.count) { [self finish:nil error:MSNetworkError(@"The title's details are unavailable from compatible add-ons.")]; return; }
    MSAddon *addon = self.addons[self.index++];
    NSUInteger requestIndex = self.index;
    NSURL *URL = [addon resourceURL:@"meta" type:self.type identifier:self.identifier extras:nil];
    // The request retains this operation until it settles; cancellation clears
    // the transport callback, and completion releases the request before return.
    id<MSCancellable> request = [MSHTTPClient.sharedClient fetchJSONURL:URL completion:^(NSDictionary *document,NSError *error) {
        if (self.cancelled || self.finished) return;
        self.request = nil;
        MSMetadata *metadata = error ? nil : [MSMetadata metadataWithDictionary:document[@"meta"] fallbackType:self.type originConnectionIdentifier:addon.connectionIdentifier];
        if (metadata && [metadata.identifier isEqual:self.identifier] && [metadata.type isEqual:self.type]) [self finish:metadata error:nil];
        else [self loadNext];
    }];
    if (!self.finished && !self.cancelled && self.index == requestIndex) self.request = request;
}
@end

static id<MSCancellable> MSCatalogFailure(NSError *error, void (^completion)(id,NSError *)) {
    MSCatalogOperation *operation = [MSCatalogOperation new];
    dispatch_async(dispatch_get_main_queue(), ^{ if (!operation.cancelled) completion(nil,error); });
    return operation;
}

@implementation MSCatalogClient
+ (instancetype)sharedClient { static MSCatalogClient *client; static dispatch_once_t once; dispatch_once(&once, ^{ client = [self new]; }); return client; }
- (id<MSCancellable>)loadCatalogType:(NSString *)type search:(NSString *)search skip:(NSUInteger)skip completion:(void (^)(MSCatalogPage *, NSError *))completion {
    NSString *kind = [type isEqualToString:@"series"] ? @"series" : @"movie";
    for (MSAddon *addon in MSAddonStore.sharedStore.addons) if (addon.builtIn && [addon.identifier isEqual:@"com.linvo.cinemeta"]) {
        for (MSAddonCatalog *catalog in addon.catalogs) if ([catalog.type isEqual:kind] && [catalog.identifier isEqual:@"top"])
            return [self loadCatalog:catalog extras:search.length ? @{@"search":MSString(search,200)} : nil skip:skip completion:completion];
    }
    return MSCatalogFailure(MSNetworkError(@"The default catalog is unavailable."),completion);
}
- (id<MSCancellable>)loadCatalog:(MSAddonCatalog *)catalog extras:(NSDictionary *)extras skip:(NSUInteger)skip completion:(void (^)(MSCatalogPage *,NSError *))completion {
    MSAddon *addon = [MSAddonStore.sharedStore addonForConnectionIdentifier:catalog.connectionIdentifier];
    MSAddonCatalog *current = nil;
    for (MSAddonCatalog *candidate in addon.catalogs) if ([candidate.identity isEqual:catalog.identity]) { current = candidate; break; }
    if (!current || addon.configurationRequired || ![@[@"movie",@"series"] containsObject:current.type]) return MSCatalogFailure(MSNetworkError(@"This catalog connection is unavailable. Choose another catalog."),completion);
    NSError *validation = nil; NSDictionary *requestExtras = [current requestExtrasForValues:extras skip:skip error:&validation];
    if (!requestExtras) return MSCatalogFailure(validation,completion);
    NSURL *url = [addon resourceURL:@"catalog" type:current.type identifier:current.identifier extras:requestExtras];
    return [[MSHTTPClient sharedClient] fetchJSONURL:url completion:^(NSDictionary *document, NSError *error) {
        if (error) { completion(nil,error); return; }
        NSArray *raw = [document[@"metas"] isKindOfClass:NSArray.class] ? document[@"metas"] : nil;
        if (!raw || raw.count > 2000 || raw.count > 100000 - skip) { completion(nil,MSNetworkError(@"The catalog response was incomplete or exceeded the supported page size.")); return; }
        NSMutableArray *items = [NSMutableArray array];
        for (id row in raw) { if(items.count >= 500) break; MSMetadata *item = [MSMetadata metadataWithDictionary:row fallbackType:current.type originConnectionIdentifier:addon.connectionIdentifier]; if(item) [items addObject:item]; }
        MSAddonCatalogExtra *paging = [current extraNamed:@"skip"];
        NSUInteger nextSkip = skip + raw.count; BOOL hasMore = raw.count > 0 && paging != nil;
        if (paging.options.count) {
            NSUInteger next = NSUIntegerMax;
            for (NSString *option in paging.options) { NSUInteger offset = option.integerValue; if (offset > skip && offset < next) next = offset; }
            if (next == NSUIntegerMax) hasMore = NO; else nextSkip = next;
        }
        MSCatalogPage *page = [MSCatalogPage new]; page.items = items; page.receivedCount = raw.count; page.nextSkip = nextSkip; page.hasMore = hasMore; completion(page,nil);
    }];
}
- (id<MSCancellable>)loadMetadataType:(NSString *)type identifier:(NSString *)identifier completion:(void (^)(MSMetadata *, NSError *))completion {
    return [self loadMetadataType:type identifier:identifier preferredConnectionIdentifier:nil completion:completion];
}
- (id<MSCancellable>)loadMetadataType:(NSString *)type identifier:(NSString *)identifier preferredConnectionIdentifier:(NSString *)connectionIdentifier completion:(void (^)(MSMetadata *, NSError *))completion {
    if (![@[@"movie",@"series"] containsObject:type] || ![identifier isKindOfClass:NSString.class] || !identifier.length || identifier.length > 1024)
        return MSCatalogFailure(MSNetworkError(@"This title has an unsupported identifier or type."),completion);
    MSAddonStore *store = MSAddonStore.sharedStore; MSAddon *preferred = [store addonForConnectionIdentifier:connectionIdentifier];
    NSMutableArray *addons = [NSMutableArray array];
    if (preferred && !preferred.configurationRequired && [preferred supportsResource:@"meta" type:type identifier:identifier]) [addons addObject:preferred];
    for (MSAddon *addon in store.addons) {
        if (addons.count >= 4) break;
        if (addon != preferred && !addon.configurationRequired && [addon supportsResource:@"meta" type:type identifier:identifier]) [addons addObject:addon];
    }
    MSCatalogOperation *operation = [MSCatalogOperation new]; operation.addons = addons; operation.type = type; operation.identifier = identifier; operation.completion = completion;
    if (NSThread.isMainThread) [operation loadNext]; else dispatch_async(dispatch_get_main_queue(), ^{ [operation loadNext]; });
    return operation;
}
@end
