#import <Foundation/Foundation.h>
#import "MSArtworkCache.h"
static unsigned checks, failures;
static void check(BOOL pass, const char *name) { checks++; if (!pass) { failures++; fprintf(stderr,"FAIL cache: %s\n",name); } }
static void pumpUntil(BOOL (^done)(void), double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && end.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static NSData *bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static BOOL store(MSArtworkCache *cache, NSString *key, NSData *data, NSUInteger generation) {
    __block BOOL done=NO,result=NO,onMain=NO;
    [cache storeData:data forKey:key generation:generation completion:^(BOOL stored){result=stored;onMain=NSThread.isMainThread;done=YES;}];
    pumpUntil(^BOOL{return done;},2); check(done&&onMain,"write callback main and bounded"); return result;
}
static NSData *readCache(MSArtworkCache *cache, NSString *key) {
    __block BOOL done=NO,onMain=NO; __block NSData *result=nil;
    [cache readDataForKey:key completion:^(NSData *data){result=data;onMain=NSThread.isMainThread;done=YES;}];
    pumpUntil(^BOOL{return done;},2); check(done&&onMain,"read callback main and bounded"); return result;
}
static NSDictionary *stats(MSArtworkCache *cache) {
    __block NSDictionary *result=nil;
    [cache storageStatsWithCompletion:^(NSDictionary *value){result=value;}];
    pumpUntil(^BOOL{return result!=nil;},2); check(result!=nil,"stats completes");return result;
}
static void clear(MSArtworkCache *cache) {
    __block BOOL done=NO;[cache clearWithCompletion:^{done=NSThread.isMainThread;}];pumpUntil(^BOOL{return done;},2);check(done,"clear callback main and bounded");
}
int main(void) { @autoreleasepool {
    NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"MiniStream-cache-tests-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *directory=[root URLByAppendingPathComponent:@"cache" isDirectory:YES];
    MSArtworkCache *cache=[[MSArtworkCache alloc] initWithDirectoryURL:directory byteLimit:10 maximumAge:3600 maximumEntryBytes:6];
    NSString *a=[MSArtworkCache cacheKeyForURL:[NSURL URLWithString:@"https://fixture.invalid/image?token=synthetic-secret"]];
    NSString *b=[MSArtworkCache cacheKeyForURL:[NSURL URLWithString:@"https://fixture.invalid/b"]];
    NSString *c=[MSArtworkCache cacheKeyForURL:[NSURL URLWithString:@"https://fixture.invalid/c"]];
    check(a.length==64&&![a containsString:@"token"]&&![a containsString:@"fixture"],"hashed names reveal no URL text");
    check([a isEqual:[MSArtworkCache cacheKeyForURL:[NSURL URLWithString:@"https://fixture.invalid/image?token=synthetic-secret"]]]&&![a isEqual:b],"stable distinct URL digests");
    check(readCache(cache,a)==nil,"cold disk miss");
    check(store(cache,a,bytes(@"AAAA"),cache.generation),"valid encoded bytes stored");
    check([readCache(cache,a) isEqual:bytes(@"AAAA")],"disk hit returns exact bytes");
    NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:nil];
    check(names.count==1&&[names.firstObject isEqual:[a stringByAppendingString:@".art"]],"only hash artwork file, no URL index metadata");
    NSDictionary *fa=[NSFileManager.defaultManager attributesOfItemAtPath:[directory URLByAppendingPathComponent:names.firstObject].path error:nil];
    NSDictionary *da=[NSFileManager.defaultManager attributesOfItemAtPath:directory.path error:nil];
    check([fa[NSFilePosixPermissions] unsignedIntegerValue]==0600&&[da[NSFilePosixPermissions] unsignedIntegerValue]==0700,"private file and directory permissions");
    NSNumber *excluded=nil;[directory getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil];
    check(excluded.boolValue,"artwork directory excluded from backup");
    MSArtworkCache *reopened=[[MSArtworkCache alloc] initWithDirectoryURL:directory byteLimit:10 maximumAge:3600 maximumEntryBytes:6];
    check([readCache(reopened,a) isEqual:bytes(@"AAAA")],"fresh cache instance reuses persisted bytes");
    check(!store(cache,b,bytes(@"toolarge"),cache.generation),"per-entry byte cap enforced");
    check(!store(cache,@"../../escape",bytes(@"x"),cache.generation),"path traversal key rejected");
    check(!store(cache,b,[NSData data],cache.generation),"empty entries rejected");
    check(store(cache,b,bytes(@"BBBB"),cache.generation),"second entry stored");
    NSURL *aURL=[directory URLByAppendingPathComponent:[a stringByAppendingString:@".art"]];
    NSURL *bURL=[directory URLByAppendingPathComponent:[b stringByAppendingString:@".art"]];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:-120]} ofItemAtPath:bURL.path error:nil];
    (void)readCache(cache,a);
    check(store(cache,c,bytes(@"CCCC"),cache.generation),"third entry triggers cap enforcement");
    NSDictionary *measured=stats(cache);
    check([measured[@"artworkDiskBytes"] unsignedIntegerValue]==8&&[measured[@"artworkDiskFiles"] unsignedIntegerValue]==2,"disk bytes and file cap measured accurately");
    check(readCache(cache,b)==nil&&[readCache(cache,a) isEqual:bytes(@"AAAA")]&&[readCache(cache,c) isEqual:bytes(@"CCCC")],"least recently used entry evicted, recent hits retained");
    NSUInteger old=cache.generation;clear(cache);
    check(cache.generation!=old&&!store(cache,a,bytes(@"stale"),old),"clear invalidates delayed stale writer generation");
    check([stats(cache)[@"artworkDiskBytes"] unsignedIntegerValue]==0&&readCache(cache,a)==nil,"clear leaves empty cache");
    // Block the queue, enqueue old writes/reads, clear synchronously, then let
    // queued I/O run. Old callbacks must not recreate or return cleared data.
    dispatch_queue_t queue=[cache valueForKey:@"ioQueue"];
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0);
    dispatch_async(queue,^{dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));});
    check(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,"serial I/O queue test gate entered");
    __block BOOL writeDone=NO,oldStored=YES,readDone=NO,clearDone=NO;__block NSData *oldRead=nil;
    [cache storeData:bytes(@"race") forKey:a generation:cache.generation completion:^(BOOL result){oldStored=result;writeDone=YES;}];
    [cache readDataForKey:a completion:^(NSData *value){oldRead=value;readDone=YES;}];
    [cache clearWithCompletion:^{clearDone=YES;}];dispatch_semaphore_signal(release);
    pumpUntil(^BOOL{return writeDone&&readDone&&clearDone;},2);
    check(writeDone&&readDone&&clearDone&&!oldStored&&!oldRead,"clear wins over queued write and read race");
    check([stats(cache)[@"artworkDiskBytes"] unsignedIntegerValue]==0,"queued operations cannot repopulate cleared disk");
    check(store(cache,a,bytes(@"new"),cache.generation)&&[readCache(cache,a) isEqual:bytes(@"new")],"new-generation requests work after clear");
    [bytes(@"corrupt-too-large") writeToURL:aURL atomically:YES];
    check(readCache(cache,a)==nil&&! [NSFileManager.defaultManager fileExistsAtPath:aURL.path],"oversized on-disk file rejected and removed before reading");
    NSURL *outside=[root URLByAppendingPathComponent:@"outside"];
    [bytes(@"safe") writeToURL:outside atomically:YES];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:aURL.path withDestinationPath:outside.path error:nil];
    check(readCache(cache,a)==nil&&[[NSData dataWithContentsOfURL:outside] isEqual:bytes(@"safe")],"symlink entry not followed; target unchanged");
    NSURL *ttlDirectory=[root URLByAppendingPathComponent:@"ttl" isDirectory:YES];
    MSArtworkCache *ttl=[[MSArtworkCache alloc] initWithDirectoryURL:ttlDirectory byteLimit:10 maximumAge:1 maximumEntryBytes:6];
    check(store(ttl,a,bytes(@"expire"),ttl.generation),"TTL fixture stored");
    pumpUntil(^BOOL{return NO;},1.1);
    check(readCache(ttl,a)==nil&&[stats(ttl)[@"artworkDiskFiles"] unsignedIntegerValue]==0,"expired entry removed on access");
    clear(cache);clear(ttl);[NSFileManager.defaultManager removeItemAtURL:root error:nil];
    printf("%s %u artwork cache checks; %u failures (isolated temp storage only)\n",failures?"FAIL":"PASS",checks,failures);
    return failures?1:0;
} }
