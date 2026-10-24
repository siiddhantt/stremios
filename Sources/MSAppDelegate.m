#import "MSAppDelegate.h"
#import "MSBrowseViewController.h"
#import "MSCatalogViewController.h"
#import "MSCatalogDetailViewController.h"
#import "MSStreamListViewController.h"
#import "MSSettingsViewController.h"
#import "MSMedia.h"
#import "MSTheme.h"
#import "MSAddonImporter.h"

@interface MSNavigationController : UINavigationController
@end
@implementation MSNavigationController
- (UIViewController *)childViewControllerForStatusBarStyle { return self.topViewController; }
@end

@interface MSTabController : UITabBarController
@end
@implementation MSTabController
- (UIViewController *)childViewControllerForStatusBarStyle { return self.selectedViewController; }
@end

@implementation MSAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Demo fixtures remain available to isolated tests, outside the normal app.
    NSArray<MSMedia *> *catalog = @[];
    __block __weak UITabBarController *weakTabs;
    MSVideoSelection selection = ^(MSMetadata *metadata, MSEpisode *episode) {
        UINavigationController *navigation = (UINavigationController *)weakTabs.selectedViewController;
        MSStreamListViewController *sources=[[MSStreamListViewController alloc] initWithMetadata:metadata episode:episode];
        if ([navigation.topViewController isKindOfClass:MSCatalogDetailViewController.class] && [(MSCatalogDetailViewController *)navigation.topViewController resumeRequested]) [sources requestResumeFromLastSource];
        [navigation pushViewController:sources animated:YES];
    };
    MSCatalogViewController *browse = [[MSCatalogViewController alloc] initWithCatalogClient:MSCatalogClient.sharedClient demoCatalog:catalog videoSelection:selection];
    MSBrowseViewController *library = [[MSBrowseViewController alloc] initWithCatalog:catalog libraryOnly:YES videoSelection:selection];
    MSSettingsViewController *settings = [[MSSettingsViewController alloc] initWithCatalog:catalog];
    NSMutableArray *controllers = [NSMutableArray array];
    for (UIViewController *root in @[browse, library, settings]) {
        MSNavigationController *navigation = [[MSNavigationController alloc] initWithRootViewController:root];
        MSApplyNavigationStyle(navigation);
        [controllers addObject:navigation];
    }
    MSTabController *tabs = [MSTabController new]; tabs.viewControllers = controllers; weakTabs = tabs;
    tabs.tabBar.translucent = NO; tabs.tabBar.barStyle = UIBarStyleBlack;
    tabs.tabBar.barTintColor = MSBackgroundColor(); tabs.tabBar.tintColor = MSAccentColor();
    tabs.tabBar.unselectedItemTintColor = MSSecondaryColor();
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = MSBackgroundColor(); self.window.tintColor = MSAccentColor();
    self.window.rootViewController = tabs; [self.window makeKeyAndVisible];
    [self importAddons:NO];
    return YES;
}
- (void)importAddons:(BOOL)retry {
    __weak typeof(self) weakSelf = self;
    MSAddonImportCompletion completion = ^(NSUInteger added, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || (!added && !error) || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:error ? @"Add-on import paused" : @"Add-ons ready" message:error.localizedDescription ?: [NSString stringWithFormat:@"%lu configured add-ons were imported into protected app storage. Choose a title, then Sources.", (unsigned long)added] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        if(error) [alert addAction:[UIAlertAction actionWithTitle:@"Retry" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; [weakSelf importAddons:YES]; }]];
        UIViewController *presenter = self.window.rootViewController;
        if (!presenter.presentedViewController) [presenter presentViewController:alert animated:YES completion:nil];
    };
    if (retry) [MSAddonImporter retryPendingConfigurationWithCompletion:completion];
    else [MSAddonImporter importPendingConfigurationWithCompletion:completion];
}

@end
