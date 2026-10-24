#import "MSCatalogViewController.h"
#import "MSCatalogDetailViewController.h"
#import "MSImageLoader.h"
#import "MSMedia.h"
#import "MSAddons.h"
#import "MSCatalogPickerViewController.h"
#import "MSTheme.h"
#import "MSPlayerControls.h"
#import <math.h>

// Use the same local traits for layout and text. Per-controller accessibility
// overrides (and split/rotation updates) must not measure the global category.
static UIFont *MSCatalogTextFont(UIFontTextStyle style, UITraitCollection *traits) {
    BOOL headline=[style isEqualToString:UIFontTextStyleHeadline];
    UIFont *base=[UIFont systemFontOfSize:headline?17:13 weight:headline?UIFontWeightSemibold:UIFontWeightRegular];
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:base compatibleWithTraitCollection:traits];
}

@interface MSCatalogPosterCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *artwork;
@property(nonatomic, strong) UILabel *placeholder;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *infoLabel;
@property(nonatomic, strong) id<MSCancellable> request;
@property(nonatomic) NSUInteger generation;
- (void)configure:(MSMetadata *)metadata traits:(UITraitCollection *)traits;
- (void)cancelPoster;
@end
@implementation MSCatalogPosterCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = MSSurfaceColor(); self.contentView.layer.cornerRadius = 12; self.contentView.clipsToBounds = YES;
        _artwork = [UIImageView new]; _artwork.contentMode = UIViewContentModeScaleAspectFill; _artwork.clipsToBounds = YES;
        _placeholder = MSLabel(UIFontTextStyleCaption1, MSSecondaryColor()); _placeholder.text = @"No poster"; _placeholder.textAlignment = NSTextAlignmentCenter;
        _titleLabel = MSLabel(UIFontTextStyleHeadline, MSPrimaryColor()); _titleLabel.numberOfLines = 2;
        _infoLabel = MSLabel(UIFontTextStyleFootnote, MSSecondaryColor()); _infoLabel.numberOfLines = 1;
        for (UIView *view in @[_artwork, _placeholder, _titleLabel, _infoLabel]) { view.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:view]; }
        [NSLayoutConstraint activateConstraints:@[
            [_artwork.topAnchor constraintEqualToAnchor:self.contentView.topAnchor], [_artwork.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_artwork.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor], [_artwork.heightAnchor constraintEqualToAnchor:_artwork.widthAnchor multiplier:1.5],
            [_placeholder.centerXAnchor constraintEqualToAnchor:_artwork.centerXAnchor], [_placeholder.centerYAnchor constraintEqualToAnchor:_artwork.centerYAnchor],
            [_titleLabel.topAnchor constraintEqualToAnchor:_artwork.bottomAnchor constant:12], [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_infoLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6], [_infoLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_infoLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor], [_infoLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-12]
        ]];
        self.isAccessibilityElement = YES; self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}
- (void)configure:(MSMetadata *)metadata traits:(UITraitCollection *)traits {
    self.titleLabel.font=MSCatalogTextFont(UIFontTextStyleHeadline,traits);
    self.infoLabel.font=MSCatalogTextFont(UIFontTextStyleFootnote,traits);
    [self cancelPoster]; self.artwork.image = nil; self.placeholder.hidden = NO;
    self.titleLabel.text = metadata.title; self.infoLabel.text = metadata.releaseInfo;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", metadata.title, metadata.releaseInfo];
    self.accessibilityHint = @"Open title details";
    if (!metadata.posterURL) return;
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    self.request = [MSImageLoader.sharedLoader loadURL:metadata.posterURL maxPixelSize:400 completion:^(UIImage *image, NSError *error) {
        (void)error;
        typeof(self) self = weakSelf;
        if (!self || generation != self.generation) return;
        self.request = nil; self.artwork.image = image; self.placeholder.hidden = image != nil;
    }];
}
- (void)cancelPoster { self.generation++; [self.request cancel]; self.request = nil; }
- (void)prepareForReuse { [super prepareForReuse]; [self cancelPoster]; self.artwork.image = nil; self.placeholder.hidden = NO; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; self.contentView.alpha = highlighted ? 0.7 : 1; }
- (void)dealloc { [self.request cancel]; }
@end

static UIFont *MSCatalogControlFont(UITraitCollection *traits) {
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold] compatibleWithTraitCollection:traits];
}

// Two real buttons retain visible labels and separate VoiceOver targets. The
// shared Tabler templates are cached by MSPlayerIcon, just like player controls.
@interface MSCatalogTypeControl : UIControl
@property(nonatomic) NSInteger selectedSegmentIndex;
@property(nonatomic,strong) NSArray<UIButton *> *buttons;
@property(nonatomic,strong) UIStackView *buttonStack;
@end
@implementation MSCatalogTypeControl
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.backgroundColor=MSSurfaceColor();self.layer.cornerRadius=14;
        NSMutableArray *buttons=[NSMutableArray array];NSArray *titles=@[@"Movies",@"Series"],*icons=@[@"movies",@"series"];
        for(NSUInteger index=0;index<titles.count;index++){
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=(NSInteger)index;button.layer.cornerRadius=10;
            [button setTitle:titles[index] forState:UIControlStateNormal];[button setImage:MSPlayerIcon(icons[index]) forState:UIControlStateNormal];
            button.contentEdgeInsets=UIEdgeInsetsMake(10,12,10,20);button.titleEdgeInsets=UIEdgeInsetsMake(0,8,0,-8);
            button.titleLabel.font=MSCatalogControlFont(self.traitCollection);button.titleLabel.adjustsFontForContentSizeCategory=YES;
            button.accessibilityLabel=titles[index];button.accessibilityHint=@"Show catalogs for this title type";
            [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
            [button addTarget:self action:@selector(selectedButton:) forControlEvents:UIControlEventTouchUpInside];[buttons addObject:button];
        }
        self.buttons=buttons;self.buttonStack=[[UIStackView alloc]initWithArrangedSubviews:buttons];self.buttonStack.distribution=UIStackViewDistributionFillEqually;self.buttonStack.spacing=2;self.buttonStack.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:self.buttonStack];
        [NSLayoutConstraint activateConstraints:@[[self.buttonStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],[self.buttonStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],[self.buttonStack.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],[self.buttonStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4]]];
        self.isAccessibilityElement=NO;self.shouldGroupAccessibilityChildren=YES;self.selectedSegmentIndex=0;
    }return self;
}
- (CGSize)intrinsicContentSize {
    CGFloat width=0,height=44;for(UIButton *button in self.buttons){width=MAX(width,button.intrinsicContentSize.width);height=MAX(height,button.intrinsicContentSize.height);}
    return CGSizeMake(ceil(width)*2+10,ceil(height)+8);
}
- (void)setSelectedSegmentIndex:(NSInteger)index {
    _selectedSegmentIndex=index==1?1:0;
    for(UIButton *button in self.buttons){BOOL selected=button.tag==_selectedSegmentIndex;button.backgroundColor=selected?MSAccentColor():UIColor.clearColor;button.tintColor=selected?MSBackgroundColor():MSSecondaryColor();[button setTitleColor:button.tintColor forState:UIControlStateNormal];button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);}
}
- (void)selectedButton:(UIButton *)button {if(self.selectedSegmentIndex==button.tag)return;self.selectedSegmentIndex=button.tag;[self sendActionsForControlEvents:UIControlEventValueChanged];}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];for(UIButton *button in self.buttons)button.titleLabel.font=MSCatalogControlFont(self.traitCollection);[self invalidateIntrinsicContentSize];
}
@end

@interface MSCatalogSelectionControl : UIControl
@property(nonatomic,strong) UILabel *nameLabel,*sourceLabel;
@end
@implementation MSCatalogSelectionControl
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.backgroundColor=MSSurfaceColor();self.layer.cornerRadius=12;
        _nameLabel=MSLabel(UIFontTextStyleBody,MSPrimaryColor());_nameLabel.font=MSFont(UIFontTextStyleBody,UIFontWeightSemibold);_nameLabel.numberOfLines=1;_nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        _sourceLabel=MSLabel(UIFontTextStyleCaption1,MSSecondaryColor());_sourceLabel.numberOfLines=1;
        UIImageView *chevron=[[UIImageView alloc]initWithImage:MSPlayerIcon(@"close")];chevron.tintColor=MSSecondaryColor();chevron.isAccessibilityElement=NO;
        UIStackView *labels=[[UIStackView alloc]initWithArrangedSubviews:@[_nameLabel,_sourceLabel]];labels.axis=UILayoutConstraintAxisVertical;labels.spacing=2;
        UIStackView *row=[[UIStackView alloc]initWithArrangedSubviews:@[labels,chevron]];row.spacing=12;row.alignment=UIStackViewAlignmentCenter;row.userInteractionEnabled=NO;row.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:row];
        [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[chevron setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        NSLayoutConstraint *height=[self.heightAnchor constraintGreaterThanOrEqualToConstant:58];height.priority=999;
        [NSLayoutConstraint activateConstraints:@[height,[row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],[row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],[row.topAnchor constraintEqualToAnchor:self.topAnchor constant:9],[row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-9]]];
        self.isAccessibilityElement=YES;self.accessibilityTraits=UIAccessibilityTraitButton;self.accessibilityHint=@"Choose a catalog from an installed add-on";
    }return self;
}
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted];self.alpha=highlighted?.7:1; }
@end

@interface MSCatalogViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic,strong) MSCatalogClient *client;
@property(nonatomic,copy) MSVideoSelection selection;
@property(nonatomic,strong) UICollectionView *collection;
@property(nonatomic,strong) UIRefreshControl *refreshControl;
@property(nonatomic,strong) MSCatalogTypeControl *typeControl;
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,strong) MSCatalogSelectionControl *catalogButton;
@property(nonatomic,strong) UIButton *filterButton,*clearButton;
@property(nonatomic,strong) UILabel *filterSummary,*statusLabel,*emptyLabel;
@property(nonatomic,strong) UIStackView *catalogBar,*activeFilterBar,*controlsRow;
@property(nonatomic,strong) NSArray<MSAddonCatalog *> *availableCatalogs;
@property(nonatomic,strong) MSAddonCatalog *selectedCatalog;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *filterValues;
@property(nonatomic,strong) UIButton *retryButton;
@property(nonatomic,strong) NSMutableArray<MSMetadata *> *items;
@property(nonatomic,strong) NSMutableSet<NSString *> *identifiers;
@property(nonatomic,strong) id<MSCancellable> request;
@property(nonatomic,copy) NSString *query;
@property(nonatomic) NSUInteger generation,nextSkip;
@property(nonatomic) BOOL loading,hasMore,failed,visible,loadedFirstPage;
@end

@implementation MSCatalogViewController
- (instancetype)initWithCatalogClient:(MSCatalogClient *)client demoCatalog:(NSArray<MSMedia *> *)demo videoSelection:(MSVideoSelection)selection {
    if((self=[super init])) {
        (void)demo;_client=client;_selection=[selection copy];_query=@"";_filterValues=@{};_availableCatalogs=@[];
        _items=[NSMutableArray array];_identifiers=[NSMutableSet set];_hasMore=YES;
        self.title=@"Discover";self.tabBarItem=[[UITabBarItem alloc]initWithTitle:@"Discover" image:MSTabImage(@"browse") tag:0];
    }return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=MSBackgroundColor();self.definesPresentationContext=YES;
    self.searchController=[[UISearchController alloc]initWithSearchResultsController:nil];self.searchController.searchResultsUpdater=self;self.searchController.searchBar.delegate=self;
    self.searchController.obscuresBackgroundDuringPresentation=NO;self.searchController.searchBar.barStyle=UIBarStyleBlack;self.searchController.searchBar.tintColor=MSAccentColor();
    self.navigationItem.searchController=self.searchController;self.navigationItem.hidesSearchBarWhenScrolling=NO;
    self.typeControl=[MSCatalogTypeControl new];self.typeControl.accessibilityLabel=@"Title type";
    [self.typeControl setContentHuggingPriority:751 forAxis:UILayoutConstraintAxisHorizontal];[self.typeControl setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.typeControl addTarget:self action:@selector(typeChanged) forControlEvents:UIControlEventValueChanged];
    self.catalogButton=[MSCatalogSelectionControl new];[self.catalogButton addTarget:self action:@selector(chooseCatalog) forControlEvents:UIControlEventTouchUpInside];
    self.filterButton=MSButton(@"Filters",NO);[self.filterButton setImage:MSPlayerIcon(@"filters") forState:UIControlStateNormal];self.filterButton.tintColor=MSPrimaryColor();self.filterButton.contentEdgeInsets=UIEdgeInsetsMake(10,12,10,20);self.filterButton.titleEdgeInsets=UIEdgeInsetsMake(0,8,0,-8);self.filterButton.titleLabel.font=MSCatalogControlFont(self.traitCollection);self.filterButton.accessibilityLabel=@"Catalog filters";[self.filterButton addTarget:self action:@selector(chooseFilters) forControlEvents:UIControlEventTouchUpInside];
    [self.filterButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[self.filterButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.catalogBar=[[UIStackView alloc]initWithArrangedSubviews:@[self.catalogButton,self.filterButton]];self.catalogBar.spacing=12;self.catalogBar.alignment=UIStackViewAlignmentFill;
    self.filterSummary=MSLabel(UIFontTextStyleFootnote,MSSecondaryColor());self.filterSummary.numberOfLines=2;
    self.clearButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.clearButton setTitle:@"Clear" forState:UIControlStateNormal];self.clearButton.accessibilityLabel=@"Clear catalog filters";self.clearButton.titleLabel.font=MSFont(UIFontTextStyleSubheadline,UIFontWeightMedium);self.clearButton.titleLabel.adjustsFontForContentSizeCategory=YES;self.clearButton.contentEdgeInsets=UIEdgeInsetsMake(8,8,8,8);[self.clearButton addTarget:self action:@selector(clearFilters) forControlEvents:UIControlEventTouchUpInside];
    NSLayoutConstraint *clearHeight=[self.clearButton.heightAnchor constraintGreaterThanOrEqualToConstant:44];clearHeight.priority=999;clearHeight.active=YES;
    [self.clearButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[self.clearButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.activeFilterBar=[[UIStackView alloc]initWithArrangedSubviews:@[self.filterSummary,self.clearButton]];self.activeFilterBar.spacing=8;self.activeFilterBar.alignment=UIStackViewAlignmentCenter;
    self.controlsRow=[[UIStackView alloc]initWithArrangedSubviews:@[self.typeControl,self.catalogBar]];self.controlsRow.spacing=12;self.controlsRow.alignment=UIStackViewAlignmentFill;
    UIStackView *header=[[UIStackView alloc]initWithArrangedSubviews:@[self.controlsRow,self.activeFilterBar]];header.axis=UILayoutConstraintAxisVertical;header.spacing=10;
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];layout.sectionInset=UIEdgeInsetsMake(16,20,24,20);layout.minimumInteritemSpacing=16;layout.minimumLineSpacing=20;
    self.collection=[[UICollectionView alloc]initWithFrame:CGRectZero collectionViewLayout:layout];self.collection.backgroundColor=MSBackgroundColor();self.collection.alwaysBounceVertical=YES;self.collection.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.collection.dataSource=self;self.collection.delegate=self;
    self.refreshControl=[UIRefreshControl new];self.refreshControl.tintColor=MSAccentColor();[self.refreshControl addTarget:self action:@selector(refreshCatalog) forControlEvents:UIControlEventValueChanged];self.collection.refreshControl=self.refreshControl;
    [self.collection registerClass:MSCatalogPosterCell.class forCellWithReuseIdentifier:@"remote-poster"];
    self.emptyLabel=MSLabel(UIFontTextStyleBody,MSSecondaryColor());self.emptyLabel.textAlignment=NSTextAlignmentCenter;
    self.statusLabel=MSLabel(UIFontTextStyleFootnote,MSSecondaryColor());self.statusLabel.textAlignment=NSTextAlignmentCenter;
    self.retryButton=MSButton(@"Try again",NO);self.retryButton.hidden=YES;[self.retryButton addTarget:self action:@selector(retry) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *footer=[[UIStackView alloc]initWithArrangedSubviews:@[self.statusLabel,self.retryButton]];footer.axis=UILayoutConstraintAxisVertical;footer.spacing=8;
    for(UIView *view in @[header,self.collection,footer]){view.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:view];}
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],[header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],[header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.collection.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:2],[self.collection.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.collection.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.collection.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-8],
        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],[footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],[footer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(addonsChanged:) name:MSAddonsDidChangeNotification object:nil];
    [self restoreCatalogSelection];[self updateStatus];
}
- (NSString *)selectedType { return self.typeControl.selectedSegmentIndex==1?@"series":@"movie"; }
- (NSString *)selectionDefaultsKey { return [@"MiniStream.discover." stringByAppendingString:self.selectedType]; }
- (NSDictionary<NSString *,NSString *> *)validFilterValues:(id)stored catalog:(MSAddonCatalog *)catalog {
    if(![stored isKindOfClass:NSDictionary.class])return @{};NSMutableDictionary *valid=[NSMutableDictionary dictionary];
    for(MSAddonCatalogExtra *extra in catalog.extras){if([@[@"search",@"skip"] containsObject:extra.name])continue;id value=stored[extra.name];if(![value isKindOfClass:NSString.class]||![value length]||[value length]>(extra.options.count?256:160)||[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)continue;if(extra.options.count&&![extra.options containsObject:value])continue;valid[extra.name]=value;}
    return valid;
}
- (void)persistSelection {
    if(!self.selectedCatalog)return;
    [NSUserDefaults.standardUserDefaults setObject:@{@"connection":self.selectedCatalog.connectionIdentifier,@"catalog":self.selectedCatalog.identifier,@"type":self.selectedCatalog.type,@"filters":self.filterValues?:@{}} forKey:self.selectionDefaultsKey];
}
- (void)restoreCatalogSelection {
    NSMutableArray *catalogs=[NSMutableArray array];for(MSAddonCatalog *catalog in MSAddonStore.sharedStore.allCatalogs)if([catalog.type isEqualToString:self.selectedType])[catalogs addObject:catalog];self.availableCatalogs=catalogs;
    id saved=[NSUserDefaults.standardUserDefaults objectForKey:self.selectionDefaultsKey];NSDictionary *record=[saved isKindOfClass:NSDictionary.class]?saved:@{};MSAddonCatalog *selected=nil;
    for(MSAddonCatalog *catalog in catalogs)if([catalog.connectionIdentifier isEqual:record[@"connection"]]&&[catalog.identifier isEqual:record[@"catalog"]]&&[catalog.type isEqual:record[@"type"]]){selected=catalog;break;}
    self.selectedCatalog=selected?:catalogs.firstObject;self.filterValues=selected?[self validFilterValues:record[@"filters"] catalog:selected]:@{};[self updateCatalogControls];
}
- (NSArray<MSAddonCatalogExtra *> *)filterExtras {
    NSMutableArray *extras=[NSMutableArray array];for(MSAddonCatalogExtra *extra in self.selectedCatalog.extras)if(![@[@"search",@"skip"] containsObject:extra.name])[extras addObject:extra];return extras;
}
- (NSString *)missingInputMessage {
    if(!self.selectedCatalog)return @"No catalogs for this title type.\nAdd a catalog connection in Settings.";
    for(MSAddonCatalogExtra *extra in self.selectedCatalog.extras){
        if(!extra.isRequired||[extra.name isEqualToString:@"skip"])continue;
        if([extra.name isEqualToString:@"search"]){if(!self.query.length)return @"Search to see titles in this catalog.";}
        else if(!self.filterValues[extra.name].length)return [NSString stringWithFormat:@"Choose %@ in Filters to see titles.",MSCatalogFilterTitle(self.selectedCatalog,extra).lowercaseString];
    }return nil;
}
- (void)updateCatalogControls {
    BOOL searchSupported=[self.selectedCatalog extraNamed:@"search"]!=nil;
    if(!searchSupported){self.query=@"";self.searchController.searchBar.text=@"";self.searchController.active=NO;}
    self.navigationItem.searchController=searchSupported?self.searchController:nil;self.searchController.searchBar.userInteractionEnabled=searchSupported;
    self.searchController.searchBar.placeholder=searchSupported?([self.selectedType isEqualToString:@"series"]?@"Search this series catalog":@"Search this movie catalog"):@"Search unavailable for this catalog";
    self.catalogButton.enabled=self.availableCatalogs.count>0;self.catalogButton.nameLabel.text=self.selectedCatalog.name?:@"No catalogs";self.catalogButton.sourceLabel.text=self.selectedCatalog.addonName?:@"Add a connection in Settings";
    self.catalogButton.accessibilityLabel=[NSString stringWithFormat:@"Catalog, %@, %@",self.catalogButton.nameLabel.text,self.catalogButton.sourceLabel.text];
    self.filterButton.enabled=self.filterExtras.count>0;self.filterButton.hidden=!self.filterButton.enabled;
    [self.filterButton setTitle:self.filterValues.count?[NSString stringWithFormat:@"Filters · %lu",(unsigned long)self.filterValues.count]:@"Filters" forState:UIControlStateNormal];
    NSMutableArray *parts=[NSMutableArray array];for(MSAddonCatalogExtra *extra in self.filterExtras)if(self.filterValues[extra.name].length)[parts addObject:[NSString stringWithFormat:@"%@: %@",MSCatalogFilterTitle(self.selectedCatalog,extra),self.filterValues[extra.name]]];
    self.filterSummary.text=[parts componentsJoinedByString:@" · "];self.activeFilterBar.hidden=!parts.count;
    [self updateResponsiveHeader];
}
- (void)updateResponsiveHeader {
    BOOL stacked=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)||self.view.bounds.size.width<680;
    UILayoutConstraintAxis axis=stacked?UILayoutConstraintAxisVertical:UILayoutConstraintAxisHorizontal;
    if(self.controlsRow.axis!=axis)self.controlsRow.axis=axis;if(self.catalogBar.axis!=axis)self.catalogBar.axis=axis;
    self.catalogButton.nameLabel.numberOfLines=stacked?2:1;
}
- (void)chooseCatalog {
    if(self.presentedViewController||!self.availableCatalogs.count)return;[self.searchController.searchBar resignFirstResponder];__weak typeof(self) weakSelf=self;
    MSCatalogPickerViewController *picker=[[MSCatalogPickerViewController alloc]initWithCatalogs:self.availableCatalogs selectedIdentity:self.selectedCatalog.identity selection:^(MSAddonCatalog *selected){
        typeof(self) self=weakSelf;if(!self)return;MSAddonCatalog *current=nil;for(MSAddonCatalog *catalog in MSAddonStore.sharedStore.allCatalogs)if([catalog.identity isEqualToString:selected.identity]){current=catalog;break;}if(!current)return;
        if([current.identity isEqualToString:self.selectedCatalog.identity])return;self.selectedCatalog=current;self.filterValues=@{};self.query=@"";self.searchController.searchBar.text=@"";[self persistSelection];[self updateCatalogControls];[self resetCatalogDebounced:NO];
    }];[self presentCatalogSheet:picker];
}
- (void)chooseFilters {
    if(self.presentedViewController||!self.filterExtras.count)return;[self.searchController.searchBar resignFirstResponder];NSString *identity=self.selectedCatalog.identity;__weak typeof(self) weakSelf=self;
    MSCatalogFiltersViewController *filters=[[MSCatalogFiltersViewController alloc]initWithCatalog:self.selectedCatalog values:self.filterValues apply:^(NSDictionary *values){typeof(self) self=weakSelf;if(!self||![self.selectedCatalog.identity isEqualToString:identity])return;self.filterValues=[self validFilterValues:values catalog:self.selectedCatalog];[self persistSelection];[self updateCatalogControls];[self resetCatalogDebounced:NO];}];[self presentCatalogSheet:filters];
}
- (void)presentCatalogSheet:(UIViewController *)controller { UINavigationController *navigation=[[MSOutsideDismissNavigationController alloc]initWithRootViewController:controller];MSApplyNavigationStyle(navigation);navigation.modalPresentationStyle=UIModalPresentationFormSheet;navigation.preferredContentSize=controller.preferredContentSize;[self presentViewController:navigation animated:YES completion:nil]; }
- (void)clearFilters { self.filterValues=@{};[self persistSelection];[self updateCatalogControls];[self resetCatalogDebounced:NO]; }
- (void)typeChanged { [self restoreCatalogSelection];[self resetCatalogDebounced:NO]; }
- (void)addonsChanged:(NSNotification *)notification { (void)notification;[self restoreCatalogSelection];[self resetCatalogDebounced:NO]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];self.visible=YES;[self.collection reloadData];if(!self.loadedFirstPage&&!self.loading&&!self.failed)[self loadNextPage]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];self.visible=NO;[self cancelLoading];for(MSCatalogPosterCell *cell in self.collection.visibleCells)[cell cancelPoster]; }
- (void)inactive:(NSNotification *)notification { (void)notification;[self cancelLoading];for(MSCatalogPosterCell *cell in self.collection.visibleCells)[cell cancelPoster]; }
- (void)active:(NSNotification *)notification { (void)notification;if(!self.visible)return;[self.collection reloadData];if(!self.loadedFirstPage&&!self.failed)[self loadNextPage]; }
- (void)cancelLoading { self.generation++;[self.request cancel];self.request=nil;self.loading=NO;[self.refreshControl endRefreshing];[self updateStatus]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if(![self.selectedCatalog extraNamed:@"search"])return;NSString *query=[searchController.searchBar.text?:@"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(query.length>160)query=[query substringToIndex:160];if([query isEqualToString:self.query])return;self.query=query;[self resetCatalogDebounced:YES];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (void)resetCatalogDebounced:(BOOL)debounced {
    [self cancelLoading];self.nextSkip=0;self.hasMore=YES;self.failed=NO;self.loadedFirstPage=NO;[self.items removeAllObjects];[self.identifiers removeAllObjects];[self.collection reloadData];[self.collection setContentOffset:CGPointMake(0,-self.collection.adjustedContentInset.top) animated:NO];[self updateStatus];NSUInteger generation=self.generation;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((debounced?.4:0)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{typeof(self) self=weakSelf;if(self&&self.visible&&self.generation==generation)[self loadNextPage];});
}
- (void)loadNextPage {
    if(!self.visible||self.loading||!self.hasMore||self.nextSkip>=500||self.missingInputMessage.length||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){[self.refreshControl endRefreshing];[self updateStatus];return;}
    self.loading=YES;self.failed=NO;[self updateStatus];NSUInteger generation=self.generation,requestedSkip=self.nextSkip;NSMutableDictionary *extras=[self.filterValues mutableCopy];if(self.query.length)extras[@"search"]=self.query;__weak typeof(self) weakSelf=self;
    self.request=[self.client loadCatalog:self.selectedCatalog extras:extras skip:requestedSkip completion:^(MSCatalogPage *page,NSError *error){
        typeof(self) self=weakSelf;if(!self||self.generation!=generation||!self.visible)return;self.loading=NO;self.request=nil;[self.refreshControl endRefreshing];if(!page||error){self.failed=YES;[self updateStatus];return;}
        self.loadedFirstPage=YES;NSUInteger previousCount=self.items.count;
        for(MSMetadata *item in page.items){NSString *key=[NSString stringWithFormat:@"%@:%@",item.type,item.identifier];if(self.items.count>=500)break;if(![self.identifiers containsObject:key]){[self.identifiers addObject:key];[self.items addObject:item];}}
        self.nextSkip=page.nextSkip;self.hasMore=page.hasMore&&self.items.count>previousCount&&page.nextSkip>requestedSkip&&page.nextSkip<500&&self.items.count<500;[self.collection reloadData];[self updateStatus];
    }];
}
- (void)retry { self.failed=NO;[self loadNextPage]; }
- (void)refreshCatalog { [self resetCatalogDebounced:NO]; }
- (void)updateStatus {
    if(!self.isViewLoaded)return;NSString *missing=self.missingInputMessage;self.retryButton.hidden=!self.failed||missing.length;
    if(missing.length)self.statusLabel.text=@"";
    else if(self.failed)self.statusLabel.text=@"Couldn't load titles. Check your connection and try again.";
    else if(self.loading)self.statusLabel.text=self.items.count?@"Loading more titles…":@"Loading titles…";
    else if(self.nextSkip>=500||self.items.count>=500)self.statusLabel.text=@"Showing up to 500 titles. Change the catalog or filters to narrow the results.";
    else self.statusLabel.text=@"";
    self.statusLabel.hidden=!self.statusLabel.text.length;
    if(!self.items.count){self.emptyLabel.text=missing.length?missing:self.failed?@"Titles are unavailable right now.":self.loadedFirstPage?(self.query.length?@"No matching titles.\nTry another search.":@"No titles found.\nTry another catalog or clear filters."):@"Loading titles…";self.collection.backgroundView=self.emptyLabel;}else self.collection.backgroundView=nil;
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { return self.items.count; }
- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath { MSCatalogPosterCell *cell=[collectionView dequeueReusableCellWithReuseIdentifier:@"remote-poster" forIndexPath:indexPath];[cell configure:self.items[indexPath.item] traits:self.traitCollection];return cell; }
- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath { if(!self.failed&&(NSUInteger)indexPath.item+8>=self.items.count)[self loadNextPage]; }
- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath { [(MSCatalogPosterCell *)cell cancelPoster]; }
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat available=collectionView.bounds.size.width-collectionView.adjustedContentInset.left-collectionView.adjustedContentInset.right-40;CGFloat minimum=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)?260:160;NSInteger columns=MAX(1,(NSInteger)((available+16)/(minimum+16)));CGFloat width=floor((available-(columns-1)*16)/columns);CGFloat text=ceil(2*MSCatalogTextFont(UIFontTextStyleHeadline,self.traitCollection).lineHeight)+ceil(MSCatalogTextFont(UIFontTextStyleFootnote,self.traitCollection).lineHeight)+30;return CGSizeMake(width,width*1.5+text);
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath { [collectionView deselectItemAtIndexPath:indexPath animated:NO];[self.searchController.searchBar resignFirstResponder];MSCatalogDetailViewController *detail=[[MSCatalogDetailViewController alloc]initWithMetadata:self.items[indexPath.item] catalogClient:self.client videoSelection:self.selection];[self.navigationController pushViewController:detail animated:YES]; }
- (void)fontChanged:(NSNotification *)notification { (void)notification;self.filterButton.titleLabel.font=MSCatalogControlFont(self.traitCollection);[self.typeControl invalidateIntrinsicContentSize];[self updateResponsiveHeader];[self.collection.collectionViewLayout invalidateLayout];[self.collection reloadData]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(self.isViewLoaded&&![previousTraitCollection.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory])[self fontChanged:nil];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];[self updateResponsiveHeader]; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator { [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];[self.collection.collectionViewLayout invalidateLayout]; }
- (void)dealloc { [self.request cancel];[NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
