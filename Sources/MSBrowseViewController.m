#import "MSBrowseViewController.h"
#import "MSCatalogDetailViewController.h"
#import "MSMedia.h"
#import "MSTheme.h"
#import "MSLibraryStore.h"
#import "MSImageLoader.h"
#import <math.h>

@interface MSPosterCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *artwork;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *infoLabel;
@property(nonatomic, strong) UILabel *placeholder;
@property(nonatomic, strong) id<MSCancellable> request;
@property(nonatomic) NSUInteger generation;
- (void)configureRecord:(NSDictionary *)record;
- (void)cancelPoster;
@end
@implementation MSPosterCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.backgroundColor = MSSurfaceColor(); self.contentView.layer.cornerRadius = 12; self.contentView.clipsToBounds = YES;
        _artwork = [UIImageView new]; _artwork.contentMode = UIViewContentModeScaleAspectFill; _artwork.clipsToBounds = YES;
        _placeholder = MSLabel(UIFontTextStyleCaption1, MSSecondaryColor()); _placeholder.text = @"No poster"; _placeholder.textAlignment = NSTextAlignmentCenter;
        _nameLabel = MSLabel(UIFontTextStyleHeadline, MSPrimaryColor()); _nameLabel.numberOfLines = 2;
        _infoLabel = MSLabel(UIFontTextStyleFootnote, MSSecondaryColor()); _infoLabel.numberOfLines = 2;
        for (UIView *view in @[_artwork, _placeholder, _nameLabel, _infoLabel]) { view.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:view]; }
        [NSLayoutConstraint activateConstraints:@[
            [_artwork.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor], [_artwork.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_artwork.topAnchor constraintEqualToAnchor:self.contentView.topAnchor], [_artwork.heightAnchor constraintEqualToAnchor:_artwork.widthAnchor multiplier:1.5],
            [_placeholder.centerXAnchor constraintEqualToAnchor:_artwork.centerXAnchor], [_placeholder.centerYAnchor constraintEqualToAnchor:_artwork.centerYAnchor],
            [_nameLabel.topAnchor constraintEqualToAnchor:_artwork.bottomAnchor constant:10], [_nameLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_infoLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:6], [_infoLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_infoLabel.trailingAnchor constraintEqualToAnchor:_nameLabel.trailingAnchor], [_infoLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-12]
        ]]; self.isAccessibilityElement = YES; self.accessibilityTraits = UIAccessibilityTraitButton;
    } return self;
}
- (void)configureRecord:(NSDictionary *)record {
    [self cancelPoster]; self.artwork.image = nil; self.placeholder.hidden = NO;
    self.nameLabel.text = record[@"title"];
    double position = [record[@"position"] doubleValue], duration = [record[@"duration"] doubleValue];
    NSString *episode = [record[@"type"] isEqualToString:@"series"] && record[@"episode"] ? [NSString stringWithFormat:@"S%02ld · E%02ld", (long)[record[@"season"] integerValue], (long)[record[@"episode"] integerValue]] : @"";
    if (position >= 5 && (duration <= 0 || position < duration-10)) self.infoLabel.text = [NSString stringWithFormat:@"%@%@Resume at %@", episode, episode.length ? @"\n" : @"", MSTimeDescription(position)];
    else if (episode.length) self.infoLabel.text = [NSString stringWithFormat:@"%@%@%@", episode, [record[@"episodeTitle"] length] ? @"\n" : @"", record[@"episodeTitle"] ?: @""];
    else self.infoLabel.text = [NSString stringWithFormat:@"%@%@%@", [record[@"type"] isEqualToString:@"series"] ? @"Series" : @"Movie", [record[@"releaseInfo"] length] ? @" · " : @"", record[@"releaseInfo"] ?: @""];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", self.nameLabel.text, self.infoLabel.text]; self.accessibilityHint = @"Open details and playback options. Hold for Library actions.";
    NSString *address = [record[@"posterURL"] isKindOfClass:NSString.class] ? record[@"posterURL"] : nil;
    if (!address.length) return;
    NSUInteger generation = self.generation; __weak typeof(self) weakSelf = self;
    self.request = [MSImageLoader.sharedLoader loadURL:[NSURL URLWithString:address] maxPixelSize:400 completion:^(UIImage *image, NSError *error) {
        (void)error; typeof(self) self = weakSelf; if (!self || self.generation != generation) return;
        self.request = nil; self.artwork.image = image; self.placeholder.hidden = image != nil;
    }];
}
- (void)cancelPoster { self.generation++; [self.request cancel]; self.request = nil; }
- (void)prepareForReuse { [super prepareForReuse]; [self cancelPoster]; self.artwork.image = nil; self.placeholder.hidden = NO; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; self.contentView.alpha = highlighted ? 0.7 : 1; }
- (void)dealloc { [self.request cancel]; }
@end

@interface MSBrowseHeader : UICollectionReusableView
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIStackView *stack;
@property(nonatomic, strong) UISegmentedControl *category;
- (void)setCategory:(UISegmentedControl *)category;
@end
@implementation MSBrowseHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _label = MSLabel(UIFontTextStyleSubheadline, MSSecondaryColor());
        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_label]]; _stack.axis = UILayoutConstraintAxisVertical; _stack.spacing = 12;
        _stack.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[[_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20], [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20], [_stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:8], [_stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-8]]];
    } return self;
}
- (void)setCategory:(UISegmentedControl *)category {
    if (_category == category && category.superview == self.stack) return;
    [_category removeFromSuperview]; _category = category;
    if (category) [self.stack insertArrangedSubview:category atIndex:0];
}
@end

@interface MSBrowseViewController () <UICollectionViewDelegateFlowLayout>
@property(nonatomic, copy) NSArray<MSMedia *> *catalog;
@property(nonatomic, copy) NSArray<NSDictionary *> *visibleRecords;
@property(nonatomic, copy) MSVideoSelection videoSelection;
@property(nonatomic, strong) UISegmentedControl *modeControl;
@property(nonatomic, strong) id<MSCancellable> metadataRequest;
@property(nonatomic, strong) NSMutableSet<NSString *> *metadataAttempts;
@property(nonatomic) NSUInteger metadataGeneration;
@property(nonatomic) BOOL libraryOnly;
@property(nonatomic) BOOL visible;
@end
@implementation MSBrowseViewController
- (instancetype)initWithCatalog:(NSArray<MSMedia *> *)catalog libraryOnly:(BOOL)libraryOnly {
    return [self initWithCatalog:catalog libraryOnly:libraryOnly videoSelection:nil];
}
- (instancetype)initWithCatalog:(NSArray<MSMedia *> *)catalog libraryOnly:(BOOL)libraryOnly videoSelection:(MSVideoSelection)selection {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new]; layout.sectionInset = UIEdgeInsetsMake(8, 20, 24, 20); layout.minimumInteritemSpacing = 16; layout.minimumLineSpacing = 20;
    if ((self = [super initWithCollectionViewLayout:layout])) {
        _catalog = [catalog copy]; _visibleRecords = @[]; _libraryOnly = libraryOnly; _videoSelection = [selection copy]; _metadataAttempts = [NSMutableSet set];
        self.title = libraryOnly ? @"Library" : @"Browse"; self.tabBarItem = [[UITabBarItem alloc] initWithTitle:self.title image:MSTabImage(libraryOnly ? @"library" : @"browse") tag:libraryOnly ? 1 : 0];
    } return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.collectionView.backgroundColor = MSBackgroundColor(); self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:MSPosterCell.class forCellWithReuseIdentifier:@"poster"];
    [self.collectionView registerClass:MSBrowseHeader.class forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"header"];
    if (self.libraryOnly) {
        self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Continue", @"Saved", @"History"]]; self.modeControl.selectedSegmentIndex = 0; self.modeControl.tintColor = MSAccentColor();
        self.modeControl.accessibilityLabel = @"Library category";
        [self.modeControl.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        [self.modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
        [self.collectionView addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(libraryActions:)]];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadLibrary:) name:MSLibraryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontSizeChanged:) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil]; [self reloadItems];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.visible = YES; [self reloadItems]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.visible = NO; [self cancelPosters]; [self cancelMetadata]; }
- (void)cancelPosters { for (MSPosterCell *cell in self.collectionView.visibleCells) [cell cancelPoster]; }
- (void)cancelMetadata { self.metadataGeneration++; [self.metadataRequest cancel]; self.metadataRequest = nil; }
- (void)inactive:(NSNotification *)notification { (void)notification; [self cancelPosters]; [self cancelMetadata]; }
- (void)active:(NSNotification *)notification { (void)notification; if (self.visible) [self reloadItems]; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (void)reloadLibrary:(NSNotification *)notification { (void)notification; if (self.isViewLoaded && self.visible) [self reloadItems]; }
- (void)fontSizeChanged:(NSNotification *)notification { (void)notification; [self.collectionView.collectionViewLayout invalidateLayout]; [self.collectionView reloadData]; }
- (void)modeChanged { [self reloadItems]; [self.collectionView setContentOffset:CGPointMake(0, -self.collectionView.adjustedContentInset.top) animated:NO]; }
- (void)reloadItems {
    MSLibraryStore *store = MSLibraryStore.sharedStore;
    if (self.libraryOnly) self.visibleRecords = self.modeControl.selectedSegmentIndex == 1 ? store.favoriteRecords : self.modeControl.selectedSegmentIndex == 2 ? store.recentRecords : store.continueWatchingRecords;
    else { NSMutableArray *records = [NSMutableArray array]; for (MSMedia *media in self.catalog) { NSDictionary *record = [store recordForIdentifier:media.identifier]; if (record) [records addObject:record]; } self.visibleRecords = records; }
    // Retire the bundled test film from regular UI without deleting saved data.
    self.visibleRecords = [self.visibleRecords filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, NSDictionary *bindings) { (void)bindings; return ![record[@"videoID"] isEqualToString:@"demo:big-buck-bunny"]; }]];
    UILabel *empty = MSLabel(UIFontTextStyleBody, MSSecondaryColor()); empty.textAlignment = NSTextAlignmentCenter;
    if (!self.libraryOnly) empty.text = @"Find a movie or series in Browse.";
    else if (self.modeControl.selectedSegmentIndex == 1) empty.text = @"Save a movie or series from its details.\nYour saved titles will appear here.";
    else if (self.modeControl.selectedSegmentIndex == 2) empty.text = @"Titles you play will appear here.\nYour history stays on this iPad.";
    else empty.text = @"Pick up where you left off.\nStart a movie or episode in Browse.";
    self.collectionView.backgroundView = self.visibleRecords.count ? nil : empty; [self.collectionView reloadData]; [self enrichLegacyMetadata];
}
- (void)enrichLegacyMetadata {
    // Migration has only an ID and time. A bounded, serial public-catalog lookup
    // restores artwork/title while leaving source resolution behind Play.
    if (!self.libraryOnly || !self.visible || self.metadataRequest || self.metadataAttempts.count >= 10 || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSDictionary *candidate = nil;
    for (NSDictionary *record in self.visibleRecords) {
        NSString *identifier = record[@"videoID"], *parent = record[@"metadataID"];
        if ([self.metadataAttempts containsObject:identifier] || ![record[@"title"] isEqualToString:@"Saved playback"] || ![parent hasPrefix:@"tt"] || parent.length <= 2) continue;
        if ([[parent substringFromIndex:2] rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) continue;
        candidate = record; break;
    }
    if (!candidate) return;
    NSString *identifier = candidate[@"videoID"]; [self.metadataAttempts addObject:identifier];
    NSUInteger generation = self.metadataGeneration; __weak typeof(self) weakSelf = self;
    self.metadataRequest = [MSCatalogClient.sharedClient loadMetadataType:candidate[@"type"] identifier:candidate[@"metadataID"] completion:^(MSMetadata *metadata, NSError *error) {
        (void)error; typeof(self) self = weakSelf; if (!self || !self.visible || generation != self.metadataGeneration) return;
        self.metadataRequest = nil;
        NSDictionary *current = [MSLibraryStore.sharedStore recordForIdentifier:identifier];
        if (metadata && [current[@"title"] isEqualToString:@"Saved playback"]) {
            NSMutableDictionary *fields = [@{@"metadataID":metadata.identifier, @"type":metadata.type, @"title":metadata.title, @"releaseInfo":metadata.releaseInfo} mutableCopy];
            if (metadata.posterURL) fields[@"posterURL"] = metadata.posterURL.absoluteString;
            for (MSEpisode *episode in metadata.episodes) if ([episode.identifier isEqualToString:identifier]) {
                fields[@"episodeTitle"] = episode.title; fields[@"season"] = @(episode.season); fields[@"episode"] = @(episode.episode); break;
            }
            [MSLibraryStore.sharedStore registerMetadata:fields forVideoIdentifier:identifier];
        }
        [self enrichLegacyMetadata];
    }];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { (void)collectionView; (void)section; return self.visibleRecords.count; }
- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    MSPosterCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"poster" forIndexPath:indexPath]; NSDictionary *record = self.visibleRecords[indexPath.item];
    [cell configureRecord:record]; return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath { (void)collectionView; (void)indexPath; [(MSPosterCell *)cell cancelPoster]; }
- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    MSBrowseHeader *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"header" forIndexPath:indexPath];
    header.category = self.libraryOnly ? self.modeControl : nil;
    header.label.hidden = self.libraryOnly; header.label.text = self.libraryOnly ? nil : @"Recently watched"; return header;
}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout referenceSizeForHeaderInSection:(NSInteger)section {
    (void)layout; (void)section; return CGSizeMake(collectionView.bounds.size.width, (self.libraryOnly ? 44 : [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].lineHeight) + 16);
}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)layout; (void)indexPath;
    CGFloat available = collectionView.bounds.size.width - collectionView.adjustedContentInset.left - collectionView.adjustedContentInset.right - 40;
    CGFloat minimum = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? 260 : 160;
    NSInteger columns = MAX(1, (NSInteger)((available + 16) / (minimum + 16))); CGFloat width = floor((available - (columns - 1) * 16) / columns);
    CGFloat text = 2 * [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline].lineHeight + 2 * [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].lineHeight + 30;
    return CGSizeMake(width, width * 1.5 + text);
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO]; NSDictionary *record = self.visibleRecords[indexPath.item];
    NSMutableDictionary *raw = [@{@"id":record[@"metadataID"], @"name":record[@"title"], @"type":record[@"type"]} mutableCopy];
    if (record[@"posterURL"]) raw[@"poster"] = record[@"posterURL"]; if (record[@"releaseInfo"]) raw[@"releaseInfo"] = record[@"releaseInfo"];
    MSMetadata *metadata = [MSMetadata metadataWithDictionary:raw fallbackType:record[@"type"]]; if (!metadata) return;
    MSCatalogDetailViewController *detail = [[MSCatalogDetailViewController alloc] initWithMetadata:metadata catalogClient:MSCatalogClient.sharedClient videoSelection:self.videoSelection];
    detail.preferredVideoIdentifier = record[@"videoID"];
    [self.navigationController pushViewController:detail animated:YES];
}
- (void)libraryActions:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || self.presentedViewController) return;
    NSIndexPath *path = [self.collectionView indexPathForItemAtPoint:[gesture locationInView:self.collectionView]]; if (!path || (NSUInteger)path.item >= self.visibleRecords.count) return;
    NSDictionary *record = self.visibleRecords[path.item]; NSString *identifier = record[@"videoID"];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:record[@"title"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (self.modeControl.selectedSegmentIndex == 1) [sheet addAction:[UIAlertAction actionWithTitle:@"Remove from Saved" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { (void)action; if ([MSLibraryStore.sharedStore isFavorite:identifier]) [MSLibraryStore.sharedStore toggleFavorite:identifier]; }]];
    else [sheet addAction:[UIAlertAction actionWithTitle:@"Remove from History" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { (void)action; [MSLibraryStore.sharedStore removeHistoryForIdentifier:identifier]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.collectionView; sheet.popoverPresentationController.sourceRect = [self.collectionView cellForItemAtIndexPath:path].frame;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator { [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator]; [self.collectionView.collectionViewLayout invalidateLayout]; }
- (void)dealloc { [self.metadataRequest cancel]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
