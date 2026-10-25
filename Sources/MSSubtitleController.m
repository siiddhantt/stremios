#import "MSSubtitleController.h"
#import "MSSubtitles.h"
#import "MSAddons.h"
#import "MSHTTPClient.h"
#import "MSTheme.h"
#import "MSPlaybackPreferences.h"
#import "MSSubtitleSettingsViewController.h"
#import "MSLibraryStore.h"
#import <math.h>

static const NSUInteger MSSubtitleProviderLimit = 8;
static const NSUInteger MSSubtitleChoiceLimit = 200;
static NSString *const MSUnidentifiedSource = @"source:unidentified";

static NSString *MSCaptionString(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length > limit ? [[text substringToIndex:limit] stringByAppendingString:@"…"] : text;
}

@interface MSCaptionChoice : NSObject
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *language;
@property(nonatomic, copy) NSString *providerID;
@property(nonatomic, copy) NSString *subtitleID;
@end
@implementation MSCaptionChoice
@end

@class MSSubtitlePickerViewController;
@interface MSSubtitleController ()
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, weak) id<MSSubtitlePlaybackSource> playbackSource;
@property(nonatomic) BOOL usesPlaybackSource;
@property(nonatomic, strong) NSTimer *clockTimer, *embeddedRestoreTimer;
@property(nonatomic) BOOL embeddedRestoreExpired;
@property(nonatomic, copy) NSArray<NSDictionary *> *sourceEmbeddedTracks;
- (NSUInteger)embeddedChoiceCount;
- (NSString *)embeddedTitleAtIndex:(NSUInteger)index;
- (BOOL)embeddedSelectedAtIndex:(NSUInteger)index;
- (void)selectEmbeddedAtIndex:(NSUInteger)index;
- (void)selectSourceEmbedded:(NSDictionary *)track;
@property(nonatomic, strong) AVPlayerItem *item;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, strong) UIView *captionCanvas;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *extras;
@property(nonatomic, strong) MSSubtitleTrack *track;
@property(nonatomic, copy) NSString *selectedTitle;
@property(nonatomic) NSTimeInterval delay;
@property(nonatomic, strong) id timeObserver;
@property(nonatomic, strong) AVMediaSelectionGroup *embeddedGroup;
@property(nonatomic, copy) NSArray<AVMediaSelectionOption *> *embeddedOptions;
@property(nonatomic) BOOL embeddedLoading;
@property(nonatomic, copy) NSArray<MSAddon *> *providers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<MSCaptionChoice *> *> *providerChoices;
@property(nonatomic, copy) NSArray<MSCaptionChoice *> *choices;
@property(nonatomic, copy) NSArray<MSCaptionChoice *> *sourceChoices;
@property(nonatomic, copy) NSString *sourceSubtitleProviderID;
@property(nonatomic, strong) NSMutableArray<id<MSCancellable>> *requests;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger nextProvider;
@property(nonatomic) NSUInteger activeProviders;
@property(nonatomic) NSUInteger completedProviders;
@property(nonatomic) NSUInteger failedProviders;
@property(nonatomic) BOOL downloadPending;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL backgrounded;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, weak) MSSubtitlePickerViewController *picker;
@property(nonatomic, weak) UINavigationController *pickerNavigation;
@property(nonatomic, strong) NSLayoutConstraint *positionConstraint;
@property(nonatomic, copy) NSString *contentIdentifier;
@property(nonatomic, copy) NSDictionary *desiredSelection;
@property(nonatomic, copy) NSDictionary *selectedSelection;
@property(nonatomic, strong) MSCaptionChoice *pendingChoice;
@property(nonatomic) BOOL restoring;
@property(nonatomic) BOOL restorationAttempted;
@property(nonatomic) NSTimeInterval savedDelay;
@property(nonatomic) BOOL previousSelectionUnavailable;
- (void)pickerDidClose;
- (void)selectOff;
- (void)selectEmbedded:(AVMediaSelectionOption *)option;
- (void)selectChoice:(MSCaptionChoice *)choice;
- (void)changeDelay:(NSTimeInterval)change reset:(BOOL)reset;
- (void)reloadPicker;
- (BOOL)requiresEmbeddedTrack;
@end

@interface MSSubtitlePickerViewController : UITableViewController
@property(nonatomic, weak) MSSubtitleController *owner;
@end

@implementation MSSubtitlePickerViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Subtitles";
    self.tableView.backgroundColor = MSBackgroundColor();
    self.tableView.separatorColor = MSSurfaceColor();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(done)];
}
- (void)done {
    [self.owner pickerDidClose];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.navigationController.isBeingDismissed || !self.navigationController.presentingViewController) [self.owner pickerDidClose];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 5;
    if (section == 1) return MAX((NSUInteger)1, [self.owner embeddedChoiceCount]);
    return MAX((NSUInteger)1, self.owner.choices.count);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return @[@"Selection and timing", @"Embedded in the video", @"From add-ons"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return [NSString stringWithFormat:@"%@\nExternal subtitle delay: %+.1f s. Positive values show text later. Timing controls apply to add-on subtitles.", self.owner.selectedTitle ?: @"Using the video's subtitle setting", self.owner.delay];
    if (section == 2) return self.owner.statusText;
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CaptionChoice"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"CaptionChoice"];
    cell.backgroundColor = MSSurfaceColor();
    cell.textLabel.textColor = MSPrimaryColor(); cell.detailTextLabel.textColor = MSSecondaryColor();
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.numberOfLines = 2; cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.text = nil; cell.userInteractionEnabled = YES;
    if (indexPath.section == 0) {
        cell.textLabel.text = @[@"Off", @"Show 0.5 s earlier", @"Show 0.5 s later", @"Reset timing", @"Subtitle appearance"][indexPath.row];
        if (indexPath.row > 0 && indexPath.row < 4 && !self.owner.track) { cell.textLabel.textColor = MSSecondaryColor(); cell.userInteractionEnabled = NO; }
        if (indexPath.row == 0 && [self.owner.selectedTitle isEqualToString:@"Subtitles off"]) cell.accessoryType = UITableViewCellAccessoryCheckmark;
        if (indexPath.row == 0 && (self.owner.embeddedLoading || [self.owner requiresEmbeddedTrack])) {
            cell.textLabel.textColor = MSSecondaryColor(); cell.userInteractionEnabled = NO;
            cell.detailTextLabel.text = self.owner.embeddedLoading ? @"Checking the video's subtitle requirements…" : @"This video requires an embedded subtitle track.";
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    } else if (indexPath.section == 1) {
        if ([self.owner embeddedChoiceCount]) {
            cell.textLabel.text = [self.owner embeddedTitleAtIndex:(NSUInteger)indexPath.row];
            if ([self.owner embeddedSelectedAtIndex:(NSUInteger)indexPath.row]) cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.textLabel.text = self.owner.embeddedLoading ? @"Checking embedded subtitles…" : @"No embedded subtitles available";
            cell.userInteractionEnabled = NO; cell.textLabel.textColor = MSSecondaryColor();
        }
    } else if (self.owner.choices.count) {
        MSCaptionChoice *choice = self.owner.choices[(NSUInteger)indexPath.row];
        cell.textLabel.text = choice.title; cell.detailTextLabel.text = choice.detail;
        if (self.owner.embeddedLoading || [self.owner requiresEmbeddedTrack]) {
            cell.textLabel.textColor = MSSecondaryColor(); cell.userInteractionEnabled = NO;
            cell.detailTextLabel.text = self.owner.embeddedLoading ? @"Checking embedded subtitles…" : @"Unavailable while this video requires embedded subtitles.";
        }
    } else {
        cell.textLabel.text = self.owner.statusText.length ? self.owner.statusText : @"No add-on subtitles available";
        cell.userInteractionEnabled = NO; cell.textLabel.textColor = MSSecondaryColor();
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) [self.owner selectOff];
        else if (indexPath.row == 4) [self.navigationController pushViewController:[MSSubtitleSettingsViewController new] animated:YES];
        else [self.owner changeDelay:indexPath.row == 1 ? -0.5 : 0.5 reset:indexPath.row == 3];
    } else if (indexPath.section == 1 && (NSUInteger)indexPath.row < [self.owner embeddedChoiceCount]) {
        [self.owner selectEmbeddedAtIndex:(NSUInteger)indexPath.row];
    } else if (indexPath.section == 2 && (NSUInteger)indexPath.row < self.owner.choices.count) {
        [self.owner selectChoice:self.owner.choices[(NSUInteger)indexPath.row]];
    }
}
@end

@implementation MSSubtitleController
- (instancetype)initWithPlayer:(AVPlayer *)player overlayView:(UIView *)overlay type:(NSString *)type
    videoID:(NSString *)videoID extras:(NSDictionary<NSString *,NSString *> *)extras {
    self = [super init];
    if (self) {
        _player = player; _item = player.currentItem; _overlay = overlay; _type = [type copy]; _videoID = [videoID copy];
        NSMutableDictionary *safeExtras = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"filename", @"videoHash", @"videoSize"]) {
            id value = extras[key];
            if ([value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 1024) safeExtras[key] = value;
        }
        _extras = [safeExtras copy]; _requests = [NSMutableArray array];
        _providerChoices = [NSMutableDictionary dictionary]; _choices = @[]; _sourceChoices = @[]; _embeddedOptions = @[];
        _label = [UILabel new]; _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.textColor = UIColor.whiteColor; _label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        _label.font = [UIFont systemFontOfSize:25 weight:UIFontWeightSemibold]; _label.textAlignment = NSTextAlignmentCenter;
        _label.numberOfLines = 4; _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _label.userInteractionEnabled = NO; _label.hidden = YES;
        _label.layer.cornerRadius = 5; _label.clipsToBounds = YES;
        _captionCanvas = [[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(32,overlay.bounds.size.width),MAX(32,overlay.bounds.size.height))];
        _captionCanvas.userInteractionEnabled = NO; _captionCanvas.hidden = YES; _captionCanvas.clipsToBounds = YES;
        [overlay addSubview:_captionCanvas]; [_captionCanvas addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintGreaterThanOrEqualToAnchor:_captionCanvas.leadingAnchor constant:8],
            [_label.trailingAnchor constraintLessThanOrEqualToAnchor:_captionCanvas.trailingAnchor constant:-8],
            [_label.centerXAnchor constraintEqualToAnchor:_captionCanvas.centerXAnchor],
            [_label.widthAnchor constraintLessThanOrEqualToAnchor:_captionCanvas.widthAnchor multiplier:0.9],
            [_label.topAnchor constraintGreaterThanOrEqualToAnchor:_captionCanvas.topAnchor constant:8],
            [_label.bottomAnchor constraintLessThanOrEqualToAnchor:_captionCanvas.bottomAnchor constant:-8]
        ]];
        _positionConstraint = [_label.bottomAnchor constraintEqualToAnchor:_captionCanvas.bottomAnchor constant:-12];
        _positionConstraint.priority = 999; _positionConstraint.active = YES;
        [self applyAppearance];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(preferencesChanged:) name:MSPlaybackPreferencesDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(applicationInactive:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(applicationActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}


- (instancetype)initWithPlaybackSource:(id<MSSubtitlePlaybackSource>)source overlayView:(UIView *)overlay type:(NSString *)type videoID:(NSString *)videoID extras:(NSDictionary<NSString *,NSString *> *)extras {
    self = [self initWithPlayer:nil overlayView:overlay type:type videoID:videoID extras:extras];
    if (self) { _usesPlaybackSource = YES; _playbackSource = source; _sourceEmbeddedTracks = @[]; [self applyAppearance]; }
    return self;
}
- (NSUInteger)embeddedChoiceCount { return self.usesPlaybackSource ? self.sourceEmbeddedTracks.count : self.embeddedOptions.count; }
- (NSString *)embeddedTitleAtIndex:(NSUInteger)index {
    if (index >= [self embeddedChoiceCount]) return @"";
    return MSCaptionString(self.usesPlaybackSource ? self.sourceEmbeddedTracks[index][@"name"] : self.embeddedOptions[index].displayName,100);
}
- (BOOL)embeddedSelectedAtIndex:(NSUInteger)index {
    if (self.track || index >= [self embeddedChoiceCount]) return NO;
    if (self.usesPlaybackSource) return [self.sourceEmbeddedTracks[index][@"id"] integerValue] == [self.playbackSource subtitleSelectedEmbeddedTrackID];
    return [self.item.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:self.embeddedGroup] == self.embeddedOptions[index];
}
- (void)selectEmbeddedAtIndex:(NSUInteger)index {
    if (index >= [self embeddedChoiceCount]) return;
    if (self.usesPlaybackSource) [self selectSourceEmbedded:self.sourceEmbeddedTracks[index]];
    else [self selectEmbedded:self.embeddedOptions[index]];
}
- (void)selectSourceEmbedded:(NSDictionary *)track {
    if (![self isCurrent] || ![self.sourceEmbeddedTracks containsObject:track]) return;
    [self cancelRequests]; [self clearExternalTrack]; self.previousSelectionUnavailable=NO;
    [self.playbackSource subtitleSelectEmbeddedTrackID:[track[@"id"] integerValue]];
    self.selectedSelection=@{@"kind":@"embedded",@"language":track[@"language"],@"displayName":track[@"name"]};
    [self saveSelection]; self.selectedTitle=[NSString stringWithFormat:@"Embedded: %@",track[@"name"]]; [self closePicker];
}
- (void)refreshEmbeddedTracks {
    if (!self.usesPlaybackSource || ![self isCurrent]) return;
    [self applyAppearance];
    NSMutableArray *tracks=[NSMutableArray array];
    for (id raw in [self.playbackSource subtitleEmbeddedTracks]) {
        if (tracks.count>=200) break;
        if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"id"] isKindOfClass:NSNumber.class] || [raw[@"id"] integerValue]<0) continue;
        [tracks addObject:@{@"id":raw[@"id"],@"name":MSCaptionString(raw[@"name"],160),@"language":MSCaptionString(raw[@"language"],30)}];
    }
    self.sourceEmbeddedTracks=tracks; self.embeddedLoading=NO;
    if (self.track || [self.selectedSelection[@"kind"] isEqual:@"off"]) [self.playbackSource subtitleSelectEmbeddedTrackID:-1];
    [self updateProviderStatus]; [self reloadPicker]; [self tryRestoreSelection];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (id<MSCancellable> request in _requests) [request cancel];
    if (_timeObserver) [_player removeTimeObserver:_timeObserver];
    [_clockTimer invalidate]; [_embeddedRestoreTimer invalidate];
    [_label removeFromSuperview];
}

- (BOOL)isCurrent { return !self.invalidated && (self.usesPlaybackSource ? self.playbackSource && [self.playbackSource subtitlePlaybackActive] : self.item && self.player.currentItem == self.item); }
- (BOOL)requiresEmbeddedTrack { return self.embeddedGroup && !self.embeddedGroup.allowsEmptySelection; }

- (void)setStreamSourceFingerprint:(NSString *)fingerprint {
    if (self.restorationAttempted) return;
    BOOL valid = [fingerprint isKindOfClass:NSString.class] && fingerprint.length == 71 && [fingerprint hasPrefix:@"sha256:"] && [[fingerprint substringFromIndex:7] rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location == NSNotFound;
    self.sourceSubtitleProviderID = valid ? [@"source:" stringByAppendingString:fingerprint] : MSUnidentifiedSource;
    for (MSCaptionChoice *choice in self.sourceChoices) choice.providerID = self.sourceSubtitleProviderID;
    [self rebuildChoices];
}

- (void)setStreamSubtitles:(NSArray<NSDictionary *> *)subtitles {
    NSMutableArray<MSCaptionChoice *> *choices = [NSMutableArray array];
    NSUInteger inspected = 0;
    for (id raw in [subtitles isKindOfClass:NSArray.class] ? subtitles : @[]) {
        if (++inspected > MSSubtitleChoiceLimit) break;
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = [raw[@"id"] isKindOfClass:NSString.class] ? raw[@"id"] : nil;
        NSString *lang = [raw[@"lang"] isKindOfClass:NSString.class] ? raw[@"lang"] : nil;
        NSString *address = [raw[@"url"] isKindOfClass:NSString.class] ? raw[@"url"] : nil;
        if (!identifier.length || identifier.length > 256 || !lang.length || lang.length > 50 || !address.length || address.length > 16384) continue;
        NSURL *URL = [NSURL URLWithString:address]; if (!MSIsSafeRemoteURL(URL)) continue;
        NSString *language = [NSLocale.currentLocale displayNameForKey:NSLocaleLanguageCode value:lang];
        NSString *title = MSCaptionString(raw[@"label"], 120);
        if (!title.length) title = language.length ? MSCaptionString(language, 120) : MSCaptionString(lang, 50);
        NSString *release = MSCaptionString(raw[@"movieReleaseName"], 100);
        if (!release.length) release = MSCaptionString(raw[@"releaseName"], 100);
        if (!release.length) release = MSCaptionString(raw[@"subtitleFileName"], 100);
        if (!release.length) release = MSCaptionString(raw[@"filename"], 100);
        MSCaptionChoice *choice = [MSCaptionChoice new]; choice.URL = URL; choice.title = title;
        choice.language = lang; choice.providerID = self.sourceSubtitleProviderID ?: MSUnidentifiedSource; choice.subtitleID = identifier;
        choice.detail = release.length ? [NSString stringWithFormat:@"From source · %@", release] : @"From source";
        [choices addObject:choice];
    }
    self.sourceChoices = choices;
    [self rebuildChoices];
}

- (void)cancelRequests {
    [self.embeddedRestoreTimer invalidate]; self.embeddedRestoreTimer=nil;
    ++self.generation;
    for (id<MSCancellable> request in self.requests) [request cancel];
    [self.requests removeAllObjects]; self.activeProviders = 0; self.downloadPending = NO;
}

- (void)stopObserving {
    [self.clockTimer invalidate]; self.clockTimer=nil;
    if (self.timeObserver) { [self.player removeTimeObserver:self.timeObserver]; self.timeObserver = nil; }
}

- (void)updateText {
    if (![self isCurrent] || self.backgrounded || !self.track) { self.label.hidden = YES; return; }
    NSTimeInterval time = self.usesPlaybackSource ? [self.playbackSource subtitlePlaybackTime] : CMTimeGetSeconds(self.player.currentTime);
    NSString *text = [self.track textAtTime:time - self.delay];
    if (![self.label.text isEqualToString:text]) { self.label.text = text; [self updateCaptionLayout]; }
    self.label.hidden = text.length == 0;
}

- (void)startObserving {
    [self stopObserving];
    if (![self isCurrent] || !self.track || self.backgrounded) return;
    __weak typeof(self) weakSelf = self;
    if (self.usesPlaybackSource) {
        self.clockTimer=[NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer){ (void)timer; [weakSelf updateText]; }];
        self.clockTimer.tolerance=0.02; [NSRunLoop.mainRunLoop addTimer:self.clockTimer forMode:NSRunLoopCommonModes];
    } else self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 5) queue:dispatch_get_main_queue()
        usingBlock:^(CMTime time) { (void)time; [weakSelf updateText]; }];
    [self updateText];
}

- (void)clearExternalTrack {
    [self stopObserving]; self.track = nil; self.label.text = nil; self.label.hidden = YES;
}

- (void)applicationInactive:(NSNotification *)notification {
    (void)notification;
    self.backgrounded = YES; self.restoring = NO; [self cancelRequests]; [self stopObserving]; self.label.hidden = YES;
    if (self.picker) { self.statusText = @"Loading stopped. Reopen Subtitles to refresh."; [self reloadPicker]; }
}

- (void)applicationActive:(NSNotification *)notification {
    (void)notification;
    self.backgrounded = NO;
    if ([self isCurrent] && self.track) [self startObserving];
}

- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES; [self cancelRequests]; [self clearExternalTrack];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.captionCanvas removeFromSuperview];
    [self.pickerNavigation dismissViewControllerAnimated:NO completion:nil];
    self.picker = nil; self.pickerNavigation = nil;
}

- (void)reloadPicker { [self.picker.tableView reloadData]; }

- (void)pickerDidClose {
    self.restoring = NO; [self cancelRequests]; self.picker = nil; self.pickerNavigation = nil;
}

- (void)closePicker {
    UINavigationController *navigation = self.pickerNavigation;
    [self pickerDidClose];
    [navigation dismissViewControllerAnimated:YES completion:nil];
}

- (void)presentFromViewController:(UIViewController *)viewController {
    if (![self isCurrent] || self.pickerNavigation || viewController.presentedViewController) return;
    self.restoring = NO; [self cancelRequests];
    self.backgrounded = UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
    [self prepareProviderChoices];
    MSSubtitlePickerViewController *picker = [[MSSubtitlePickerViewController alloc] initWithStyle:UITableViewStyleGrouped];
    picker.owner = self;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
    MSApplyNavigationStyle(navigation); navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    navigation.preferredContentSize = CGSizeMake(580, 650);
    self.picker = picker; self.pickerNavigation = navigation;
    [viewController presentViewController:navigation animated:YES completion:nil];
    [self loadEmbeddedChoices];
    [self startNextProviders];
}

- (void)updateProviderStatus {
    if (self.downloadPending) return;
    if (self.previousSelectionUnavailable) { self.statusText = @"Previous subtitle unavailable. Choose another track below; your saved choice has not been replaced."; return; }
    if ([self requiresEmbeddedTrack]) {
        self.statusText = @"This video requires an embedded subtitle track. Add-on subtitles are unavailable to avoid overlapping captions.";
        return;
    }
    if (self.completedProviders < self.providers.count) self.statusText = @"Loading subtitle choices…";
    else if (self.failedProviders) self.statusText = [NSString stringWithFormat:@"%lu provider%@ could not load. Reopen Subtitles to retry. Available choices are shown above.", (unsigned long)self.failedProviders, self.failedProviders == 1 ? @"" : @"s"];
    else if (self.choices.count == 0) self.statusText = self.providers.count ? @"No add-on subtitles found for this video." : @"No installed add-on supports subtitles for this video.";
    else self.statusText = @"Choose a language and release. If timing differs, use the timing controls. SRT and WebVTT are supported.";
}

- (void)rebuildChoices {
    NSMutableArray *all = [self.sourceChoices mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger index = 0; index < self.providers.count; ++index) {
        if (all.count == MSSubtitleChoiceLimit) break;
        for (MSCaptionChoice *choice in self.providerChoices[@(index)]) {
            [all addObject:choice]; if (all.count == MSSubtitleChoiceLimit) break;
        }
        if (all.count == MSSubtitleChoiceLimit) break;
    }
    self.choices = all; [self updateProviderStatus]; [self reloadPicker];
}

- (void)startNextProviders {
    while ([self isCurrent] && (self.picker || self.restoring) && !self.downloadPending && self.activeProviders < 2 && self.nextProvider < self.providers.count) {
        NSUInteger index = self.nextProvider++;
        MSAddon *addon = self.providers[index];
        NSURL *URL = [addon resourceURL:@"subtitles" type:self.type identifier:self.videoID extras:self.extras];
        if (!URL) { ++self.completedProviders; ++self.failedProviders; continue; }
        ++self.activeProviders;
        NSUInteger generation = self.generation;
        NSString *providerName = MSCaptionString(addon.name, 70);
        NSString *providerID = addon.identifier;
        __weak typeof(self) weakSelf = self;
        id<MSCancellable> request = [MSHTTPClient.sharedClient fetchDataURL:URL maximumBytes:1024 * 1024 completion:^(NSData *data, NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.generation != generation || (!strongSelf.picker && !strongSelf.restoring) || ![strongSelf isCurrent]) return;
            if (error) { [strongSelf providerFinished:index choices:nil generation:generation]; return; }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                NSArray *subtitles = [json isKindOfClass:NSDictionary.class] && [json[@"subtitles"] isKindOfClass:NSArray.class] ? json[@"subtitles"] : nil;
                NSMutableArray<MSCaptionChoice *> *choices = subtitles ? [NSMutableArray array] : nil;
                NSUInteger inspected = 0;
                for (id raw in subtitles) {
                    if (++inspected > MSSubtitleChoiceLimit) break;
                    if (![raw isKindOfClass:NSDictionary.class]) continue;
                    NSString *address = [raw[@"url"] isKindOfClass:NSString.class] ? raw[@"url"] : nil;
                    NSURL *URL = address.length <= 16384 ? [NSURL URLWithString:address ?: @""] : nil;
                    if (!MSIsSafeRemoteURL(URL)) continue;
                    NSString *lang = MSCaptionString(raw[@"lang"], 50);
                    NSString *languageName = lang.length ? [NSLocale.currentLocale displayNameForKey:NSLocaleLanguageCode value:lang] : nil;
                    NSString *title = MSCaptionString(raw[@"label"], 120);
                    if (!title.length) title = languageName.length ? languageName : (lang.length ? lang : @"Unknown language");
                    NSString *release = MSCaptionString(raw[@"movieReleaseName"], 100);
                    if (!release.length) release = MSCaptionString(raw[@"subtitleFileName"], 100);
                    MSCaptionChoice *choice = [MSCaptionChoice new]; choice.URL = URL; choice.title = title;
                    choice.language = lang; choice.providerID = providerID; choice.subtitleID = MSCaptionString(raw[@"id"], 256);
                    choice.detail = release.length ? [NSString stringWithFormat:@"%@ · %@", providerName, release] : providerName;
                    [choices addObject:choice];
                }
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf providerFinished:index choices:choices generation:generation]; });
            });
        }];
        [self.requests addObject:request];
    }
    [self updateProviderStatus]; [self reloadPicker];
}

- (void)providerFinished:(NSUInteger)index choices:(NSArray<MSCaptionChoice *> *)choices generation:(NSUInteger)generation {
    if (self.generation != generation || (!self.picker && !self.restoring) || ![self isCurrent]) return;
    if (self.activeProviders) --self.activeProviders;
    ++self.completedProviders;
    if (choices) self.providerChoices[@(index)] = choices; else ++self.failedProviders;
    [self rebuildChoices]; [self startNextProviders]; [self tryRestoreSelection];
}

- (void)selectOff {
    if (self.embeddedLoading || [self requiresEmbeddedTrack]) { [self updateProviderStatus]; [self reloadPicker]; return; }
    self.previousSelectionUnavailable = NO;
    [self cancelRequests]; [self clearExternalTrack]; self.selectedTitle = @"Subtitles off";
    self.selectedSelection = @{@"kind":@"off"}; [self saveSelection];
    if ([self isCurrent] && self.usesPlaybackSource) [self.playbackSource subtitleSelectEmbeddedTrackID:-1];
    else if ([self isCurrent] && self.embeddedGroup) [self.item selectMediaOption:nil inMediaSelectionGroup:self.embeddedGroup];
    [self closePicker];
}

- (void)selectEmbedded:(AVMediaSelectionOption *)option {
    if (![self isCurrent] || !self.embeddedGroup || ![self.embeddedOptions containsObject:option]) return;
    [self cancelRequests]; [self clearExternalTrack];
    self.previousSelectionUnavailable = NO;
    [self.item selectMediaOption:option inMediaSelectionGroup:self.embeddedGroup];
    self.selectedSelection = @{@"kind":@"embedded", @"language":option.extendedLanguageTag ?: [option.locale objectForKey:NSLocaleLanguageCode] ?: @"", @"displayName":option.displayName ?: @""}; [self saveSelection];
    self.selectedTitle = [NSString stringWithFormat:@"Embedded: %@", MSCaptionString(option.displayName, 100)];
    [self closePicker];
}

- (void)selectChoice:(MSCaptionChoice *)choice {
    if (![self isCurrent] || (!self.picker && !self.restoring)) return;
    if (self.embeddedLoading || [self requiresEmbeddedTrack]) { [self updateProviderStatus]; [self reloadPicker]; return; }
    [self cancelRequests];
    self.pendingChoice = choice;
    self.downloadPending = YES; self.statusText = @"Loading selected subtitle…"; [self reloadPicker];
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    id<MSCancellable> request = [MSHTTPClient.sharedClient fetchDataURL:choice.URL maximumBytes:2 * 1024 * 1024 completion:^(NSData *data, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.generation != generation || (!strongSelf.picker && !strongSelf.restoring) || ![strongSelf isCurrent]) return;
        if (error) { [strongSelf subtitleFinished:nil error:error title:choice.title generation:generation]; return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError *parseError = nil;
            MSSubtitleTrack *track = [[MSSubtitleTrack alloc] initWithData:data error:&parseError];
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf subtitleFinished:track error:parseError title:choice.title generation:generation]; });
        });
    }];
    [self.requests addObject:request];
}

- (void)subtitleFinished:(MSSubtitleTrack *)track error:(NSError *)error title:(NSString *)title generation:(NSUInteger)generation {
    if (self.generation != generation || (!self.picker && !self.restoring) || ![self isCurrent]) return;
    self.downloadPending = NO;
    if ([self requiresEmbeddedTrack]) { [self updateProviderStatus]; [self reloadPicker]; return; }
    if (!track) {
        self.statusText = @"Could not load this subtitle. Choose another track or reopen Subtitles to retry.";
        if (self.restoring && [self.desiredSelection[@"kind"] isEqual:@"external"]) [self markPreviousSelectionUnavailable];
        self.restoring = NO;
        [self reloadPicker];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Subtitle unavailable" message:self.statusText preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (self.picker && !self.picker.presentedViewController) [self.picker presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (self.usesPlaybackSource) [self.playbackSource subtitleSelectEmbeddedTrackID:-1];
    else if (self.embeddedGroup) [self.item selectMediaOption:nil inMediaSelectionGroup:self.embeddedGroup];
    self.previousSelectionUnavailable = NO;
    MSCaptionChoice *choice = self.pendingChoice;
    self.track = track; self.delay = self.restoring ? self.savedDelay : 0;
    self.selectedTitle = [choice.providerID isEqual:MSUnidentifiedSource] ? [NSString stringWithFormat:@"%@ · this session", title] : title;
    self.selectedSelection = @{@"kind":@"external", @"language":choice.language ?: @"", @"displayName":title ?: @"", @"providerID":choice.providerID ?: @"", @"subtitleID":choice.subtitleID ?: @""};
    [self saveSelection];
    [self startObserving]; [self closePicker];
}

- (void)preferencesChanged:(NSNotification *)notification {
    (void)notification; __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ if ([weakSelf isCurrent]) [weakSelf applyAppearance]; });
}
- (void)applyAppearance {
    if (![self isCurrent]) return;
    MSPlaybackPreferences *p = MSPlaybackPreferences.sharedPreferences;
    self.label.font = MSSubtitleFont(p);
    self.label.textColor = MSColorFromHex(p.effectiveSubtitleColorHex);
    BOOL shadow = p.subtitleShadowEnabled;
    self.label.backgroundColor = [p.style isEqual:@"white-shadow"] ? UIColor.clearColor : [UIColor colorWithWhite:0 alpha:0.8];
    self.label.shadowColor = shadow ? UIColor.blackColor : nil; self.label.shadowOffset = shadow ? CGSizeMake(1, 2) : CGSizeZero;
    [self updateCaptionLayout];
    // Keep native caption styling untouched on the older media runtime.
}
- (void)updateVideoRect:(CGRect)rect {
    if (self.invalidated || !isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height)) return;
    CGRect visible = CGRectIntersection(rect,self.overlay.bounds);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return;
    if (!CGRectEqualToRect(self.captionCanvas.frame,visible)) self.captionCanvas.frame = visible;
    self.captionCanvas.hidden = NO;
    [self updateCaptionLayout];
}
- (void)updateCaptionLayout {
    CGSize area = self.captionCanvas.bounds.size;
    if (area.width <= 16 || area.height <= 16) return;
    CGFloat textHeight = ceil([self.label sizeThatFits:CGSizeMake(area.width*0.9,CGFLOAT_MAX)].height);
    CGFloat inset = MAX(12,area.height*0.04) + MSPlaybackPreferences.sharedPreferences.subtitleVerticalOffset*area.height;
    inset = MIN(MAX(8,area.height-textHeight-8),MAX(8,inset));
    self.positionConstraint.constant = -inset;
    [self.captionCanvas setNeedsLayout];
}
- (void)saveSelection {
    if (!self.contentIdentifier.length || !self.selectedSelection) return;
    // Generic source IDs such as "0" only identify a track within one file.
    // Without a stable source identity, keep this choice and its delay in memory.
    if ([self.selectedSelection[@"kind"] isEqual:@"external"] && [self.selectedSelection[@"providerID"] isEqual:MSUnidentifiedSource]) return;
    NSMutableDictionary *saved = [[MSLibraryStore.sharedStore playbackSelectionsForIdentifier:self.contentIdentifier] mutableCopy] ?: [NSMutableDictionary dictionary];
    saved[@"subtitle"] = self.selectedSelection; saved[@"subtitleDelay"] = @(self.delay);
    [MSLibraryStore.sharedStore savePlaybackSelections:saved forIdentifier:self.contentIdentifier];
}
- (BOOL)language:(NSString *)actual matches:(NSString *)desired {
    NSString *a = [[actual lowercaseString] componentsSeparatedByString:@"-"].firstObject;
    NSString *b = [[desired lowercaseString] componentsSeparatedByString:@"-"].firstObject;
    NSDictionary *codes = @{@"en":@"eng", @"hi":@"hin"}; a = codes[a] ?: a; b = codes[b] ?: b;
    return a.length && [a isEqual:b];
}
- (void)restoreSelectionForContentIdentifier:(NSString *)identifier {
    if (self.restorationAttempted || ![self isCurrent] || !identifier.length) return;
    [self applyAppearance];
    self.restorationAttempted = YES; self.contentIdentifier = [identifier copy];
    NSDictionary *saved = [MSLibraryStore.sharedStore playbackSelectionsForIdentifier:identifier];
    self.desiredSelection = saved[@"subtitle"];
    self.savedDelay = [saved[@"subtitleDelay"] doubleValue];
    if (!isfinite(self.savedDelay)) self.savedDelay = 0;
    self.savedDelay = fmax(-60, fmin(60, self.savedDelay));
    NSString *preferred = MSPlaybackPreferences.sharedPreferences.preferredSubtitleLanguage;
    if (!self.desiredSelection.count && [preferred isEqual:@"system"]) return;
    if (!self.desiredSelection.count && [preferred isEqual:@"none"]) self.desiredSelection = @{@"kind":@"off"};
    self.restoring = YES; self.embeddedLoading = YES;
    [self prepareProviderChoices];
    // A saved external selection is re-queried only from its own provider.
    NSString *kind = self.desiredSelection[@"kind"];
    if ([kind isEqual:@"external"]) {
        NSString *providerID = self.desiredSelection[@"providerID"];
        NSPredicate *matching = [NSPredicate predicateWithBlock:^BOOL(MSAddon *addon, NSDictionary *bindings) { (void)bindings; return [addon.identifier isEqual:providerID]; }];
        self.providers = [self.providers filteredArrayUsingPredicate:matching];
    } else if (kind.length) self.providers = @[];
    [self loadEmbeddedChoices];
    [self startNextProviders];
}
- (void)tryRestoreSelection {
    if (!self.restoring || self.embeddedLoading || self.downloadPending || ![self isCurrent] || self.backgrounded) return;
    if ([self requiresEmbeddedTrack]) { self.restoring = NO; [self cancelRequests]; return; }
    NSString *kind = self.desiredSelection[@"kind"];
    if ([kind isEqual:@"off"]) { [self selectOff]; return; }
    NSString *language = self.desiredSelection[@"language"] ?: MSPlaybackPreferences.sharedPreferences.preferredSubtitleLanguage;
    if (([kind isEqual:@"embedded"] || !kind.length) && self.usesPlaybackSource) {
        NSDictionary *match=nil;
        for (NSDictionary *track in self.sourceEmbeddedTracks) {
            BOOL sameLanguage=[self language:track[@"language"] matches:language];
            if ([track[@"name"] isEqual:self.desiredSelection[@"displayName"]] && (sameLanguage || !language.length)) { match=track; break; }
            if (!match && sameLanguage) match=track;
        }
        if (match) { [self selectSourceEmbedded:match]; return; }
        // VLC may report Playing before ESAdded has delivered the desired
        // track. Give late discovery a bounded window; explicit choices and
        // teardown cancel the timer through cancelRequests.
        if (!self.embeddedRestoreExpired) {
            if (!self.embeddedRestoreTimer) {
                __weak typeof(self) weakSelf=self;
                self.embeddedRestoreTimer=[NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer) {
                    typeof(self) self=weakSelf; if(!self || self.embeddedRestoreTimer!=timer)return;
                    self.embeddedRestoreTimer=nil; self.embeddedRestoreExpired=YES; [self tryRestoreSelection];
                }];
            }
            return;
        }
        if (kind.length) { self.restoring=NO; return; }
    }
    if (([kind isEqual:@"embedded"] || !kind.length) && !self.usesPlaybackSource) {
        AVMediaSelectionOption *match = nil;
        for (AVMediaSelectionOption *option in self.embeddedOptions) {
            NSString *code = option.extendedLanguageTag ?: [option.locale objectForKey:NSLocaleLanguageCode] ?: @"";
            BOOL sameLanguage = [self language:code matches:language];
            if ([option.displayName isEqual:self.desiredSelection[@"displayName"]] && (sameLanguage || !language.length)) { match = option; break; }
            if (!match && sameLanguage) match = option;
        }
        if (match) { [self selectEmbedded:match]; return; }
        if (kind.length) { self.restoring = NO; return; }
    }
    // Wait for all bounded provider replies to keep language preference deterministic.
    if (self.completedProviders < self.providers.count) return;
    for (MSCaptionChoice *choice in self.choices) {
        BOOL matches = kind.length ? (![choice.providerID isEqual:MSUnidentifiedSource] && [choice.providerID isEqual:self.desiredSelection[@"providerID"]] && choice.subtitleID.length && [choice.subtitleID isEqual:self.desiredSelection[@"subtitleID"]]) : [self language:choice.language matches:language];
        if (matches) { [self selectChoice:choice]; return; }
    }
    if ([kind isEqual:@"external"]) [self markPreviousSelectionUnavailable];
    self.restoring = NO;
}
- (void)markPreviousSelectionUnavailable {
    self.previousSelectionUnavailable = YES;
    self.selectedTitle = @"Previous subtitle unavailable";
    [self updateProviderStatus]; [self reloadPicker];
}
- (void)prepareProviderChoices {
    self.providerChoices = [NSMutableDictionary dictionary]; self.choices = self.sourceChoices;
    self.nextProvider = 0; self.completedProviders = 0; self.failedProviders = 0;
    self.embeddedLoading = YES; self.embeddedOptions = @[]; self.sourceEmbeddedTracks = @[];
    NSMutableArray<MSAddon *> *providers = [NSMutableArray array];
    for (MSAddon *addon in MSAddonStore.sharedStore.addons) {
        if ([addon supportsResource:@"subtitles" type:self.type identifier:self.videoID]) [providers addObject:addon];
        if (providers.count == MSSubtitleProviderLimit) break;
    }
    self.providers = providers;
    self.statusText = providers.count ? @"Loading subtitle choices…" : (self.choices.count ? @"Choose a source subtitle. Its file loads only after selection." : @"No installed add-on supports subtitles for this video.");
    if (MSAddonStore.sharedStore.loadError) self.statusText = @"Some installed add-ons could not be read. Check Settings.";
}
- (void)loadEmbeddedChoices {
    if (self.usesPlaybackSource) { [self refreshEmbeddedTracks]; return; }
    AVPlayerItem *item = self.item;
    __weak typeof(self) weakSelf = self;
    [item.asset loadValuesAsynchronouslyForKeys:@[@"availableMediaCharacteristicsWithMediaSelectionOptions"] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            // This is the player's shared asset, not an add-on network task.
            // Keep its result after picker closure so a quick Off/external
            // selection can disable a native track that finishes loading later.
            // Cancelling asset loading here would also interrupt video playback.
            if (!strongSelf || ![strongSelf isCurrent] || strongSelf.item != item) return;
            strongSelf.embeddedLoading = NO;
            if ([item.asset statusOfValueForKey:@"availableMediaCharacteristicsWithMediaSelectionOptions" error:NULL] == AVKeyValueStatusLoaded) {
                strongSelf.embeddedGroup = [item.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
                strongSelf.embeddedOptions = [AVMediaSelectionGroup playableMediaSelectionOptionsFromArray:strongSelf.embeddedGroup.options ?: @[]];
                if ([strongSelf requiresEmbeddedTrack]) {
                    [strongSelf clearExternalTrack];
                    strongSelf.selectedTitle = @"This video requires an embedded subtitle track";
                } else if (strongSelf.embeddedGroup && (strongSelf.track || [strongSelf.selectedTitle isEqualToString:@"Subtitles off"])) {
                    [item selectMediaOption:nil inMediaSelectionGroup:strongSelf.embeddedGroup];
                }
            }
            [strongSelf updateProviderStatus];
            [strongSelf reloadPicker];
            [strongSelf tryRestoreSelection];
        });
    }];
}
- (void)changeDelay:(NSTimeInterval)change reset:(BOOL)reset {
    if (!self.track || ![self isCurrent]) return;
    self.delay = reset ? 0 : fmax(-60, fmin(60, self.delay + change));
    [self saveSelection]; [self updateText]; [self reloadPicker];
}
@end
