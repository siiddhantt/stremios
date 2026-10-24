#import "MSAddonImporter.h"
#import "MSAddons.h"
#import "MSHTTPClient.h"
#import <UIKit/UIKit.h>

static NSUInteger const MSImportMaximumBytes = 32 * 1024;
static NSError *MSImportError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"MiniStreamAddonImport" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSURL *MSImportFile(NSString *name) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:name isDirectory:NO];
}
static NSURL *MSConfigurationFile(void) { return MSImportFile(@"AddonImport.json"); }
static NSURL *MSRetryFile(void) { return MSImportFile(@"AddonImport.retry-required"); }
static BOOL MSProtectImportFile(NSURL *URL) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:URL.path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) return NO;
    if (![NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionComplete} ofItemAtPath:URL.path error:nil]) return NO;
    return [URL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
}
static BOOL MSWriteRetryMarker(void) {
    NSData *marker = [@"Explicit retry required.\n" dataUsingEncoding:NSUTF8StringEncoding];
    if (![marker writeToURL:MSRetryFile() options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:nil]) return NO;
    return MSProtectImportFile(MSRetryFile());
}
static BOOL MSRemoveImportFile(NSURL *URL) {
    if (![NSFileManager.defaultManager fileExistsAtPath:URL.path]) return YES;
    return [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
}

@interface MSAddonImportOperation : NSObject <MSCancellable>
@property(nonatomic, copy) MSAddonImportCompletion completion;
@property(nonatomic, strong) id<MSCancellable> request;
@property(nonatomic, strong) MSAddonImportOperation *keepAlive;
@property(nonatomic, copy) NSArray<NSURL *> *URLs;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger added;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL explicitRetry;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL finished;
@property(atomic) BOOL cancelled;
- (void)start;
@end
static __weak MSAddonImportOperation *MSActiveImportOperation;

@implementation MSAddonImportOperation
- (void)start {
    if (self.cancelled) { [self finish:nil]; return; }
    if (self.finished) return;
    self.keepAlive = self;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        return;
    }
    [self beginImport];
}
- (void)becameActive:(NSNotification *)notification {
    [NSNotificationCenter.defaultCenter removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    if (!self.cancelled && !self.finished) [self beginImport];
}
- (void)beginImport {
    if (self.started || self.finished || self.cancelled) return;
    self.started = YES;
    NSURL *file = MSConfigurationFile();
    if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) {
        BOOL removed = MSRemoveImportFile(MSRetryFile());
        [self finish:removed ? nil : MSImportError(6, @"The temporary import marker could not be removed. Retry to finish cleanup.")]; return;
    }
    if (!MSProtectImportFile(file)) { [self finish:MSImportError(1, @"The temporary add-on file could not be protected. Nothing was imported.")]; return; }
    if (!self.explicitRetry && [NSFileManager.defaultManager fileExistsAtPath:MSRetryFile().path]) { [self finish:nil]; return; }
    // Write the marker before parsing/network access. Even a process termination now
    // leaves the next launch waiting for an explicit retry, not repeated requests.
    if (!MSWriteRetryMarker()) { [self finish:MSImportError(1, @"The import retry state could not be saved. Nothing was imported.")]; return; }
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > MSImportMaximumBytes) {
        [self finish:MSImportError(2, @"The temporary add-on file is invalid or exceeds 32 KiB. Replace it before retrying.")]; return;
    }
    NSData *data = nil;
    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:file.path];
        data = [handle readDataOfLength:MSImportMaximumBytes + 1]; [handle closeFile];
    } @catch (__unused NSException *exception) { data = nil; }
    if (!data.length || data.length > MSImportMaximumBytes) { [self finish:MSImportError(2, @"The temporary add-on file could not be read safely. Replace it before retrying.")]; return; }
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *strings = [document isKindOfClass:NSDictionary.class] ? document[@"manifestURLs"] : nil;
    if (![strings isKindOfClass:NSArray.class] || strings.count > 12) { [self finish:MSImportError(2, @"The import must contain a manifestURLs list with at most 12 addresses.")]; return; }
    NSMutableArray *URLs = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (id string in strings) {
        NSURL *URL = [MSAddon manifestURLFromString:string error:nil];
        if (!URL || !MSIsSafeRemoteURL(URL)) { [self finish:MSImportError(2, @"The import contains an invalid or unsupported manifest address. Check the configuration before retrying.")]; return; }
        if (![seen containsObject:URL.absoluteString]) { [seen addObject:URL.absoluteString]; [URLs addObject:URL]; }
    }
    self.URLs = URLs;
    if (![MSAddonStore.sharedStore reloadWithError:nil]) { [self finish:MSImportError(3, @"Saved add-ons could not be read from protected app storage. Unlock this iPad and retry the import.")]; return; }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [self importNext];
}
- (void)importNext {
    if (self.finished || self.cancelled) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { [self becameInactive:nil]; return; }
    while (self.index < self.URLs.count) {
        NSURL *URL = self.URLs[self.index]; BOOL alreadySaved = NO;
        for (MSAddon *addon in MSAddonStore.sharedStore.addons) if ([addon.manifestURL.absoluteString isEqualToString:URL.absoluteString]) { alreadySaved = YES; break; }
        if (alreadySaved) { self.index++; continue; }
        NSUInteger generation = ++self.generation;
        __weak typeof(self) weakSelf = self;
        self.request = [MSHTTPClient.sharedClient fetchJSONURL:URL completion:^(NSDictionary *manifest, NSError *networkError) {
            typeof(self) self = weakSelf;
            if (!self || self.finished || self.cancelled || self.generation != generation) return;
            self.request = nil;
            if (!manifest || networkError) { [self finish:MSImportError(4, @"An add-on manifest could not be loaded. Saved add-ons were kept; retry when the connection or provider is available.")]; return; }
            NSError *storeError = nil;
            if (![MSAddonStore.sharedStore addManifest:manifest URL:URL error:&storeError]) {
                // Another local screen could have saved the same URL during the fetch.
                BOOL alreadySaved = NO;
                for (MSAddon *addon in MSAddonStore.sharedStore.addons) if ([addon.manifestURL.absoluteString isEqualToString:URL.absoluteString]) { alreadySaved = YES; break; }
                if (!alreadySaved) { [self finish:MSImportError(5, @"An add-on could not be validated or saved in protected app storage. Saved add-ons were kept. Check the configuration, unlock the iPad, then retry.")]; return; }
            } else self.added++;
            self.index++; [self importNext];
        }];
        return;
    }
    if (!MSRemoveImportFile(MSConfigurationFile()) || !MSRemoveImportFile(MSRetryFile())) {
        [self finish:MSImportError(6, @"The add-ons were saved, but the temporary import files could not be removed. Retry to finish cleanup.")]; return;
    }
    [self finish:nil];
}
- (void)becameInactive:(NSNotification *)notification {
    if (!self.finished) [self finish:MSImportError(7, @"The import paused when StremIOS became inactive. Saved add-ons were kept; use Retry Import to continue.")];
}
- (void)finish:(NSError *)error {
    if (self.finished) return;
    self.finished = YES; self.generation++; [self.request cancel]; self.request = nil; self.URLs = nil;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (MSActiveImportOperation == self) MSActiveImportOperation = nil;
    MSAddonImportCompletion completion = self.completion; self.completion = nil;
    if (!self.cancelled && completion) completion(self.added, error);
    self.keepAlive = nil;
}
- (void)cancel {
    self.cancelled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self finish:nil]; });
}
- (void)dealloc { [self.request cancel]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

@implementation MSAddonImporter
+ (id<MSCancellable>)operationWithRetry:(BOOL)retry completion:(MSAddonImportCompletion)completion {
    MSAddonImportOperation *operation = [MSAddonImportOperation new]; operation.explicitRetry = retry; operation.completion = completion;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (MSActiveImportOperation && !MSActiveImportOperation.finished) { [operation finish:MSImportError(8, @"An add-on import is already running.")]; return; }
        MSActiveImportOperation = operation; [operation start];
    }); return operation;
}
+ (id<MSCancellable>)importPendingConfigurationWithCompletion:(MSAddonImportCompletion)completion { return [self operationWithRetry:NO completion:completion]; }
+ (id<MSCancellable>)retryPendingConfigurationWithCompletion:(MSAddonImportCompletion)completion { return [self operationWithRetry:YES completion:completion]; }
+ (BOOL)hasPendingRetry { return [NSFileManager.defaultManager fileExistsAtPath:MSConfigurationFile().path] || [NSFileManager.defaultManager fileExistsAtPath:MSRetryFile().path]; }
@end
