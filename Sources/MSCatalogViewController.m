#import "MSCatalogViewController.h"
#import "MSCatalogDetailViewController.h"
#import "MSImageLoader.h"
#import "MSMedia.h"
#import "MSTheme.h"
#import <math.h>

@interface MSCatalogPosterCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *artwork;
@property(nonatomic, strong) UILabel *placeholder;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *infoLabel;
@property(nonatomic, strong) id<MSCancellable> request;
@property(nonatomic) NSUInteger generation;
- (void)configure:(MSMetadata *)metadata;
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
- (void)configure:(MSMetadata *)metadata {
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

@interface MSCatalogViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic, strong) MSCatalogClient *client;
@property(nonatomic, copy) MSVideoSelection selection;
@property(nonatomic, strong) UICollectionView *collection;
@property(nonatomic,strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UISegmentedControl *typeControl;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) NSMutableArray<MSMetadata *> *items;
@property(nonatomic, strong) NSMutableSet<NSString *> *identifiers;
@property(nonatomic, strong) id<MSCancellable> request;
@property(nonatomic, copy) NSString *query;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger nextSkip;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL hasMore;
@property(nonatomic) BOOL failed;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL loadedFirstPage;
@end

@implementation MSCatalogViewController
- (instancetype)initWithCatalogClient:(MSCatalogClient *)client demoCatalog:(NSArray<MSMedia *> *)demo videoSelection:(MSVideoSelection)selection {
    if ((self = [super init])) {
        (void)demo; _client = client; _selection = [selection copy]; _query = @"";
        _items = [NSMutableArray array]; _identifiers = [NSMutableSet set]; _hasMore = YES;
        self.title = @"Browse"; self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Browse" image:MSTabImage(@"browse") tag:0];
    }
    return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = MSBackgroundColor();
    self.definesPresentationContext = YES;
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self; self.searchController.searchBar.delegate = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search movies";
    self.searchController.searchBar.barStyle = UIBarStyleBlack; self.searchController.searchBar.tintColor = MSAccentColor();
    self.navigationItem.searchController = self.searchController; self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.typeControl = [[UISegmentedControl alloc] initWithItems:@[@"Movies", @"Series"]];
    self.typeControl.selectedSegmentIndex = 0; self.typeControl.tintColor = MSAccentColor();
    self.typeControl.accessibilityLabel = @"Title type";
    [self.typeControl addTarget:self action:@selector(typeChanged) forControlEvents:UIControlEventValueChanged];
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.sectionInset = UIEdgeInsetsMake(16, 20, 24, 20); layout.minimumInteritemSpacing = 16; layout.minimumLineSpacing = 20;
    self.collection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collection.backgroundColor = MSBackgroundColor(); self.collection.alwaysBounceVertical = YES;
    self.collection.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.collection.dataSource = self; self.collection.delegate = self;
    self.refreshControl = [UIRefreshControl new]; self.refreshControl.tintColor = MSAccentColor();
    [self.refreshControl addTarget:self action:@selector(refreshCatalog) forControlEvents:UIControlEventValueChanged];
    self.collection.refreshControl = self.refreshControl;
    [self.collection registerClass:MSCatalogPosterCell.class forCellWithReuseIdentifier:@"remote-poster"];
    self.emptyLabel = MSLabel(UIFontTextStyleBody, MSSecondaryColor()); self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel = MSLabel(UIFontTextStyleFootnote, MSSecondaryColor()); self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.retryButton = MSButton(@"Try again", NO); self.retryButton.hidden = YES;
    [self.retryButton addTarget:self action:@selector(retry) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *footer = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusLabel, self.retryButton]];
    footer.axis = UILayoutConstraintAxisVertical; footer.spacing = 8;
    for (UIView *view in @[self.typeControl, self.collection, footer]) { view.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
        [self.typeControl.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.typeControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20], [self.typeControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.typeControl.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.collection.topAnchor constraintEqualToAnchor:self.typeControl.bottomAnchor constant:4], [self.collection.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collection.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.collection.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-8],
        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20], [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self updateStatus];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; self.visible = YES;
    [self.collection reloadData];
    if (!self.loadedFirstPage && !self.loading && !self.failed) [self loadNextPage];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated]; self.visible = NO; [self cancelLoading];
    for (MSCatalogPosterCell *cell in self.collection.visibleCells) [cell cancelPoster];
}
- (void)inactive:(NSNotification *)notification { [self cancelLoading]; }
- (void)active:(NSNotification *)notification {
    if (!self.visible) return;
    [self.collection reloadData];
    if (!self.loadedFirstPage && !self.failed) [self loadNextPage];
}
- (void)cancelLoading {
    self.generation++; [self.request cancel]; self.request = nil; self.loading = NO;
    [self.refreshControl endRefreshing];
    [self updateStatus];
}
- (NSString *)selectedType { return self.typeControl.selectedSegmentIndex == 1 ? @"series" : @"movie"; }
- (void)typeChanged {
    self.searchController.searchBar.placeholder = self.typeControl.selectedSegmentIndex == 1 ? @"Search series" : @"Search movies";
    [self resetCatalogDebounced:NO];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length > 160) query = [query substringToIndex:160];
    if ([query isEqualToString:self.query]) return;
    self.query = query; [self resetCatalogDebounced:YES];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (void)resetCatalogDebounced:(BOOL)debounced {
    [self cancelLoading]; self.nextSkip = 0; self.hasMore = YES; self.failed = NO; self.loadedFirstPage = NO;
    [self.items removeAllObjects]; [self.identifiers removeAllObjects]; [self.collection reloadData];
    [self.collection setContentOffset:CGPointMake(0, -self.collection.adjustedContentInset.top) animated:NO];
    [self updateStatus]; NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((debounced ? 0.4 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && self.visible && self.generation == generation) [self loadNextPage];
    });
}
- (void)loadNextPage {
    if (!self.visible || self.loading || !self.hasMore || self.nextSkip >= 500 || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.loading = YES; self.failed = NO; [self updateStatus];
    NSUInteger generation = self.generation; NSUInteger requestedSkip = self.nextSkip;
    __weak typeof(self) weakSelf = self;
    self.request = [self.client loadCatalogType:self.selectedType search:self.query.length ? self.query : nil skip:requestedSkip completion:^(MSCatalogPage *page, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.generation != generation || !self.visible) return;
        self.loading = NO; self.request = nil;
        [self.refreshControl endRefreshing];
        if (!page || error) { self.failed = YES; [self updateStatus]; return; }
        self.loadedFirstPage = YES;
        NSUInteger previousCount = self.items.count;
        for (MSMetadata *item in page.items) {
            NSString *key = [NSString stringWithFormat:@"%@:%@", item.type, item.identifier];
            if (self.items.count >= 500) break;
            if (![self.identifiers containsObject:key]) { [self.identifiers addObject:key]; [self.items addObject:item]; }
        }
        self.nextSkip = page.nextSkip;
        self.hasMore = page.hasMore && self.items.count > previousCount && page.nextSkip > requestedSkip && page.nextSkip < 500 && self.items.count < 500;
        [self.collection reloadData]; [self updateStatus];
    }];
}
- (void)retry { self.failed = NO; [self loadNextPage]; }
- (void)refreshCatalog {
    // Reconfigure visible cells as well, so failed artwork is retried with the catalog.
    [self resetCatalogDebounced:NO];
}
- (void)updateStatus {
    if (!self.isViewLoaded) return;
    self.retryButton.hidden = !self.failed;
    if (self.failed) self.statusLabel.text = @"Couldn't load titles. Check your connection and try again.";
    else if (self.loading) self.statusLabel.text = self.items.count ? @"Loading more titles…" : @"Loading titles…";
    else if (self.nextSkip >= 500 || self.items.count >= 500) self.statusLabel.text = @"Showing up to 500 titles. Search to narrow the results.";
    else self.statusLabel.text = @"";
    self.statusLabel.hidden = !self.statusLabel.text.length;
    if (!self.items.count) {
        self.emptyLabel.text = self.failed ? @"Titles are unavailable right now." : self.loadedFirstPage ? (self.query.length ? @"No matching titles.\nTry another search." : @"No titles found.") : @"Loading titles…";
        self.collection.backgroundView = self.emptyLabel;
    } else self.collection.backgroundView = nil;
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { return self.items.count; }
- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    MSCatalogPosterCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"remote-poster" forIndexPath:indexPath];
    [cell configure:self.items[indexPath.item]]; return cell;
}
- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.failed && (NSUInteger)indexPath.item + 8 >= self.items.count) [self loadNextPage];
}
- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath { [(MSCatalogPosterCell *)cell cancelPoster]; }
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat available = collectionView.bounds.size.width - collectionView.adjustedContentInset.left - collectionView.adjustedContentInset.right - 40;
    CGFloat minimum = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? 260 : 160;
    NSInteger columns = MAX(1, (NSInteger)((available + 16) / (minimum + 16)));
    CGFloat width = floor((available - (columns - 1) * 16) / columns);
    CGFloat text = 2 * [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline].lineHeight + [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].lineHeight + 32;
    return CGSizeMake(width, width * 1.5 + text);
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    [self.searchController.searchBar resignFirstResponder];
    MSCatalogDetailViewController *detail = [[MSCatalogDetailViewController alloc] initWithMetadata:self.items[indexPath.item] catalogClient:self.client videoSelection:self.selection];
    [self.navigationController pushViewController:detail animated:YES];
}
- (void)fontChanged:(NSNotification *)notification { [self.collection.collectionViewLayout invalidateLayout]; [self.collection reloadData]; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator { [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator]; [self.collection.collectionViewLayout invalidateLayout]; }
- (void)dealloc { [self.request cancel]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
