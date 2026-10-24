#import "MSCatalogPickerViewController.h"
#import "MSTheme.h"

@interface MSOutsideDismissNavigationController () <UIGestureRecognizerDelegate>
@property(nonatomic,strong) UITapGestureRecognizer *outsideDismissTap;
@property(nonatomic,weak) UIView *outsideDismissContainer;
@property(nonatomic) BOOL outsideDismissPending;
@end
@implementation MSOutsideDismissNavigationController
- (void)removeOutsideDismissGesture {
    [self.outsideDismissTap.view removeGestureRecognizer:self.outsideDismissTap];
    self.outsideDismissTap.delegate=nil;self.outsideDismissTap=nil;self.outsideDismissContainer=nil;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];[self removeOutsideDismissGesture];self.outsideDismissPending=NO;
    UIView *container=self.presentationController.containerView;
    if(!container||!self.presentingViewController)return;
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(outsideTapped:)];
    tap.delegate=self;tap.cancelsTouchesInView=YES;tap.delaysTouchesBegan=YES;
    self.outsideDismissTap=tap;self.outsideDismissContainer=container;[container addGestureRecognizer:tap];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if(gesture!=self.outsideDismissTap||self.outsideDismissPending||self.isBeingDismissed||self.presentedViewController||!self.view.window)return NO;
    UIView *container=self.outsideDismissContainer;
    if(!container||touch.window!=self.view.window||![touch.view isDescendantOfView:container])return NO;
    // Test the whole navigation sheet, including its bar and pushed filter
    // screens. Inside taps and scrolling never enter this recognizer.
    return !CGRectContainsPoint(self.view.bounds,[touch locationInView:self.view]);
}
- (void)outsideTapped:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateRecognized||self.outsideDismissPending||self.isBeingDismissed||self.presentedViewController)return;
    self.outsideDismissPending=YES;
    [self dismissViewControllerAnimated:YES completion:^{[self removeOutsideDismissGesture];}];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated];[self removeOutsideDismissGesture]; }
- (void)dealloc { [_outsideDismissTap.view removeGestureRecognizer:_outsideDismissTap]; }
@end

NSString *MSCatalogFilterTitle(MSAddonCatalog *catalog, MSAddonCatalogExtra *extra) {
    if ([extra.name isEqualToString:@"genre"]) {
        if ([catalog.identifier isEqualToString:@"tmdb.language"]) return @"Language";
        if ([catalog.identifier isEqualToString:@"tmdb.year"]) return @"Year";
        if ([catalog.identifier isEqualToString:@"tmdb.trending"]) return @"Period";
    }
    return [[extra.name stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
}
static MSSettingsCell *MSCatalogChoiceCell(UITableView *table, NSString *title, NSString *value, NSInteger row, NSInteger count, BOOL disclosure) {
    MSSettingsCell *cell=[table dequeueReusableCellWithIdentifier:@"catalog-choice"];
    if(!cell)cell=[[MSSettingsCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"catalog-choice"];
    cell.nameLabel.text=title;cell.valueLabel.text=value;cell.valueLabel.numberOfLines=2;
    [cell position:row count:count disclosure:disclosure];cell.accessibilityTraits|=UIAccessibilityTraitButton;cell.accessibilityHint=nil;
    return cell;
}
@interface MSCatalogPickerViewController ()
@property(nonatomic,copy) NSArray<NSArray<MSAddonCatalog *> *> *groups;
@property(nonatomic,copy) NSString *selectedIdentity;
@property(nonatomic,copy) void (^selection)(MSAddonCatalog *);
@end
@implementation MSCatalogPickerViewController
- (instancetype)initWithCatalogs:(NSArray<MSAddonCatalog *> *)catalogs selectedIdentity:(NSString *)identity selection:(void (^)(MSAddonCatalog *))selection {
    if((self=[super init])) {
        self.title=@"Catalogs";_selection=[selection copy];_selectedIdentity=[identity copy];
        NSMutableArray *keys=[NSMutableArray array],*groups=[NSMutableArray array];
        for(MSAddonCatalog *catalog in catalogs) {
            NSUInteger index=[keys indexOfObject:catalog.connectionIdentifier];
            if(index==NSNotFound){[keys addObject:catalog.connectionIdentifier];[groups addObject:[NSMutableArray array]];index=groups.count-1;}
            [groups[index] addObject:catalog];
        }
        _groups=[groups copy];self.preferredContentSize=CGSizeMake(520,640);
    }return self;
}
- (void)viewDidLoad { [super viewDidLoad];self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)]; }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.groups.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.groups[section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.groups[section].firstObject.addonName; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MSAddonCatalog *catalog=self.groups[indexPath.section][indexPath.row];BOOL selected=[catalog.identity isEqualToString:self.selectedIdentity];
    MSSettingsCell *cell=MSCatalogChoiceCell(tableView,catalog.name,selected?@"✓":@"",indexPath.row,self.groups[indexPath.section].count,NO);
    cell.valueLabel.textColor=MSAccentColor();cell.accessibilityValue=selected?@"Selected":nil;if(selected)cell.accessibilityTraits|=UIAccessibilityTraitSelected;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    MSAddonCatalog *catalog=self.groups[indexPath.section][indexPath.row];void(^selection)(MSAddonCatalog *)=self.selection;
    [self dismissViewControllerAnimated:YES completion:^{if(selection)selection(catalog);}];
}
@end

@interface MSCatalogExtraOptionsController : MSSettingsTableController <UISearchResultsUpdating>
@property(nonatomic,strong) MSAddonCatalogExtra *extra;
@property(nonatomic,copy) NSArray<NSString *> *options;
@property(nonatomic,copy) NSString *value;
@property(nonatomic,strong) UISearchController *search;
@property(nonatomic,copy) void(^selection)(NSString *);
@end
@implementation MSCatalogExtraOptionsController
- (void)viewDidLoad {
    [super viewDidLoad];self.options=self.extra.options;self.definesPresentationContext=YES;
    if(self.extra.options.count>20){
        self.search=[[UISearchController alloc]initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;
        self.search.searchBar.placeholder=[@"Find " stringByAppendingString:self.title.lowercaseString];self.search.searchBar.barStyle=UIBarStyleBlack;self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;
    }
}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    NSString *query=[controller.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.options=query.length?[self.extra.options filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *option,NSDictionary *bindings){(void)bindings;return [option rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound;}]]:self.extra.options;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.options.count+(self.extra.isRequired?0:1); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL any=!self.extra.isRequired&&indexPath.row==0;NSString *value=any?@"":self.options[indexPath.row-(self.extra.isRequired?0:1)];BOOL selected=[value isEqualToString:self.value?:@""];
    MSSettingsCell *cell=MSCatalogChoiceCell(tableView,any?@"Any":value,selected?@"✓":@"",indexPath.row,[self tableView:tableView numberOfRowsInSection:0],NO);
    cell.valueLabel.textColor=MSAccentColor();cell.accessibilityValue=selected?@"Selected":nil;if(selected)cell.accessibilityTraits|=UIAccessibilityTraitSelected;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL any=!self.extra.isRequired&&indexPath.row==0;NSString *value=any?@"":self.options[indexPath.row-(self.extra.isRequired?0:1)];
    if(self.selection)self.selection(value);[self.navigationController popViewControllerAnimated:YES];
}
@end

@interface MSCatalogFiltersViewController ()
@property(nonatomic,strong) MSAddonCatalog *catalog;
@property(nonatomic,copy) NSArray<MSAddonCatalogExtra *> *extras;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *values;
@property(nonatomic,copy) void(^apply)(NSDictionary<NSString *,NSString *> *);
@end
@implementation MSCatalogFiltersViewController
- (instancetype)initWithCatalog:(MSAddonCatalog *)catalog values:(NSDictionary<NSString *,NSString *> *)values apply:(void (^)(NSDictionary<NSString *,NSString *> *))apply {
    if((self=[super init])) {
        _catalog=catalog;_values=[values mutableCopy];_apply=[apply copy];self.title=@"Filters";self.preferredContentSize=CGSizeMake(520,600);
        NSMutableArray *extras=[NSMutableArray array];for(MSAddonCatalogExtra *extra in catalog.extras)if(![@[@"skip",@"search"] containsObject:extra.name])[extras addObject:extra];_extras=extras;
    }return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:@"Apply" style:UIBarButtonItemStyleDone target:self action:@selector(applyChanges)];
    [self updateApplyState];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)updateApplyState { BOOL ready=YES;for(MSAddonCatalogExtra *extra in self.extras)if(extra.isRequired&&!self.values[extra.name].length)ready=NO;self.navigationItem.rightBarButtonItem.enabled=ready; }
- (void)applyChanges { NSDictionary *values=[self.values copy];void(^apply)(NSDictionary *)=self.apply;[self dismissViewControllerAnimated:YES completion:^{if(apply)apply(values);}]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0?self.extras.count:1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section==0?self.catalog.name:nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return section==0?@"Options are provided by this catalog. Required filters must be selected before loading.":nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.section==1){MSSettingsCell *cell=MSCatalogChoiceCell(tableView,@"Clear filters",@"",0,1,NO);cell.nameLabel.textColor=MSAccentColor();return cell;}
    MSAddonCatalogExtra *extra=self.extras[indexPath.row];NSString *value=self.values[extra.name];
    MSSettingsCell *cell=MSCatalogChoiceCell(tableView,MSCatalogFilterTitle(self.catalog,extra),value.length?value:(extra.isRequired?@"Choose…":@"Any"),indexPath.row,self.extras.count,YES);
    cell.nameLabel.textColor=MSPrimaryColor();cell.valueLabel.textColor=MSSecondaryColor();if(extra.isRequired)cell.accessibilityHint=@"Required filter";return cell;
}
- (void)setValue:(NSString *)value forExtra:(MSAddonCatalogExtra *)extra {
    if(value.length)self.values[extra.name]=value;else[self.values removeObjectForKey:extra.name];[self updateApplyState];[self.tableView reloadData];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if(indexPath.section==1){[self.values removeAllObjects];[self updateApplyState];[self.tableView reloadData];return;}
    MSAddonCatalogExtra *extra=self.extras[indexPath.row];__weak typeof(self) weakSelf=self;
    if(extra.options.count){
        MSCatalogExtraOptionsController *options=[MSCatalogExtraOptionsController new];options.extra=extra;options.value=self.values[extra.name];options.title=MSCatalogFilterTitle(self.catalog,extra);
        options.selection=^(NSString *value){[weakSelf setValue:value forExtra:extra];};[self.navigationController pushViewController:options animated:YES];return;
    }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:MSCatalogFilterTitle(self.catalog,extra) message:extra.isRequired?@"A value is required by this catalog.":nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=weakSelf.values[extra.name];field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.clearButtonMode=UITextFieldViewModeWhileEditing;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Set" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;NSString *value=[weakAlert.textFields.firstObject.text?:@"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(value.length>160)value=[value substringToIndex:160];[weakSelf setValue:value forExtra:extra];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
