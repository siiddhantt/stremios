#import "MSVLCPlaybackViewController.h"
#import "MSMedia.h"
#import "MSTheme.h"
#import "MSPlayerControls.h"
#import "MSPlaybackChromeView.h"
#import "MSVideoGeometry.h"
#import "MSVLCSubtitleStyle.h"
#import "MSLibraryStore.h"
#import "MSPlaybackPreferences.h"
#import "MSSubtitleController.h"
#import "MSAudioSessionOwnership.h"
#import <MobileVLCKit/MobileVLCKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>

static NSString *MSVLCTrackText(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = [value length] > limit ? [value substringToIndex:limit] : value;
    static NSRegularExpression *addresses; static dispatch_once_t once;
    dispatch_once(&once, ^{ addresses = [NSRegularExpression regularExpressionWithPattern:@"(?i)(?:https?://|stremio://)\\S+" options:0 error:nil]; });
    return [addresses stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"[private link]"];
}

// libvlc stop is asynchronous. Keep its player/library alive until Stopped;
// releasing an active player can assert inside the framework destructor.
@interface MSVLCRetirement : NSObject <VLCMediaPlayerDelegate>
@property(nonatomic,strong) VLCMediaPlayer *player;
@property(nonatomic,strong) NSTimer *deadline;
@property(nonatomic,copy) void (^completion)(BOOL);
@property(nonatomic) BOOL stopReturned;
@property(nonatomic) NSUInteger diagnosticStage, callbackCount;
@property(nonatomic) NSInteger lastObservedState;
@property(nonatomic) BOOL deadlineExpired;
+ (NSUInteger)pendingCount;
+ (NSDictionary *)diagnosticSnapshot;
+ (void)retire:(VLCMediaPlayer *)player completion:(void (^)(BOOL stopped))completion;
@end
@implementation MSVLCRetirement
static NSDictionary *MSVLCLastRetirementDiagnostic;
+ (NSMutableSet *)retirements { static NSMutableSet *items; static dispatch_once_t once; dispatch_once(&once,^{items=[NSMutableSet set];}); return items; }
+ (NSUInteger)pendingCount { return self.retirements.count; }
// Main-thread-only, numeric diagnostics. Stages: 1 waiting for Stopped,
// 2 player release in progress, 4 library release in progress, 3 released.
// No media or connection data.
+ (NSDictionary *)diagnosticSnapshot {
    NSUInteger waiting=0, releasing=0;
    for(MSVLCRetirement *retirement in self.retirements) { if(retirement.diagnosticStage==1)waiting++; if(retirement.diagnosticStage==2 || retirement.diagnosticStage==4)releasing++; }
    NSMutableDictionary *snapshot=[(MSVLCLastRetirementDiagnostic ?: @{@"stage":@0,@"callbackCount":@0,@"lastObservedState":@(-1),@"deadlineExpired":@NO}) mutableCopy];
    snapshot[@"pendingCount"]=@(self.pendingCount); snapshot[@"waitingStoppedCount"]=@(waiting); snapshot[@"releasingCount"]=@(releasing);
    return snapshot;
}
- (void)recordDiagnosticStage:(NSUInteger)stage {
    self.diagnosticStage=stage;
    MSVLCLastRetirementDiagnostic=@{@"stage":@(stage),@"callbackCount":@(self.callbackCount),@"lastObservedState":@(self.lastObservedState),@"deadlineExpired":@(self.deadlineExpired)};
}
+ (void)retire:(VLCMediaPlayer *)player completion:(void (^)(BOOL))completion {
    MSVLCRetirement *retirement=[self new]; retirement.player=player; retirement.completion=completion; [self.retirements addObject:retirement];
    retirement.lastObservedState=-1; [retirement recordDiagnosticStage:1];
    player.delegate=retirement; player.drawable=nil; [player stop]; retirement.stopReturned=YES;
    __weak MSVLCRetirement *weakRetirement=retirement;
    retirement.deadline=[NSTimer scheduledTimerWithTimeInterval:8 repeats:NO block:^(NSTimer *timer) {
        MSVLCRetirement *retirement=weakRetirement; if(!retirement)return; retirement.deadline=nil; retirement.deadlineExpired=YES; [retirement recordDiagnosticStage:retirement.diagnosticStage];
        if(retirement.completion) retirement.completion(NO);
        // A late Stopped event still releases it. Do not repeatedly poll or
        // destroy a live decoder merely because the wait deadline expired.
    }];
}
- (void)mediaPlayerStateChanged:(NSNotification *)notification {
    if(notification.object!=self.player)return;
    // VLCKit sets cached state immediately before this delegate call. Capture
    // this event now: another queued event can change the cache before our
    // next main turn, which is still needed to let VLC's UIKit work finish.
    VLCMediaPlayerState observedState=self.player.state;
    dispatch_async(dispatch_get_main_queue(),^{
        if(!self.player)return;
        self.callbackCount++; self.lastObservedState=observedState; [self recordDiagnosticStage:self.diagnosticStage];
        if(self.stopReturned && observedState==VLCMediaPlayerStateStopped)[self finish];
    });
}
- (void)finish {
    if(!self.player)return;
    [self recordDiagnosticStage:2];
    self.player.delegate=nil; self.player.drawable=nil;
    // Stopped is published before libVLC's asynchronous input-close worker has
    // necessarily finished. Its final release joins that worker; keep that
    // potentially blocking destruction off the UIKit thread.
    __block VLCLibrary *retiringLibrary=self.player.libraryInstance;
    __block VLCMediaPlayer *retiringPlayer=self.player; self.player=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        retiringPlayer=nil;
        dispatch_async(dispatch_get_main_queue(),^{ [self recordDiagnosticStage:4]; });
        retiringLibrary=nil;
        dispatch_async(dispatch_get_main_queue(),^{
            [self recordDiagnosticStage:3];
            [self.deadline invalidate]; self.deadline=nil;
            void (^completion)(BOOL)=self.completion; self.completion=nil;
            [[self.class retirements] removeObject:self]; if(completion)completion(YES);
        });
    });
}
@end

@interface MSVLCPlaybackViewController () <VLCMediaPlayerDelegate, MSSubtitlePlaybackSource, UIGestureRecognizerDelegate, UIPopoverPresentationControllerDelegate>
@property(nonatomic,strong) MSMedia *media;
@property(nonatomic,strong) VLCMediaPlayer *player;
@property(nonatomic,strong) MSSubtitleController *subtitles;
@property(nonatomic,strong) NSObject *audioOwner;
@property(nonatomic,strong) UIView *videoView, *videoViewport, *subtitleOverlay, *header, *footer, *statusPanel;
@property(nonatomic,strong) UILabel *titleLabel, *timeLabel, *statusLabel;
@property(nonatomic,strong) UIButton *playButton, *audioButton, *subtitleButton, *retryButton, *nextButton, *displayButton, *fullscreenButton, *backButton, *forwardButton;
@property(nonatomic,strong) UIActivityIndicatorView *statusSpinner;
@property(nonatomic) CGFloat zoomFactor, pinchStartZoom;
@property(nonatomic) CGSize sourceVideoSize;
@property(nonatomic,strong) UISlider *seekSlider;
@property(nonatomic,strong) NSLayoutConstraint *captionBottom, *captionTop, *statusBottom;
@property(nonatomic,copy) NSString *displayMode;
@property(nonatomic) CGSize appliedVideoSize;
@property(nonatomic,strong) NSTimer *tickTimer, *startupTimer, *hideTimer;
@property(nonatomic,weak) UIAlertController *audioPicker;
@property(nonatomic) BOOL resume, prepared, closing, ready, seekPending, controlsVisible, scrubbing, ownsAudioSession, interrupted, mediaServicesUnavailable, sourceSaved, restoredAudio, retryFromBeginning;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSTimeInterval initialSeekTarget, advanceBaseline, lastAdvanceTime, lastObservedTime, lastPersistedAt, lastDiagnosticAt;
@property(nonatomic) NSTimeInterval lastTrackRefreshAt;
@property(nonatomic) NSTimeInterval audioRestoreDeadline;
@property(nonatomic) NSTimeInterval sourceAdvanceSeconds, sourceObservationStartedAt;
@property(nonatomic) BOOL userSeekPending;
@property(nonatomic) NSTimeInterval userSeekTarget, userSeekStartedAt;
@property(nonatomic) NSInteger lastDisplayedPictures;
@property(nonatomic) NSTimeInterval lastProgressMediaTime;
@property(nonatomic) NSInteger lastProgressPictures;
@property(nonatomic) BOOL showingBuffering;
@property(nonatomic) NSInteger lastEngineState;
@property(nonatomic) BOOL waitingForStop, restartAfterStop, stopTimedOut;
@property(nonatomic,copy) dispatch_block_t afterStopAction;
@property(nonatomic,copy) NSArray<NSDictionary *> *knownAudioTracks, *knownSubtitleTracks;
@end

@implementation MSVLCPlaybackViewController
- (instancetype)initWithMedia:(MSMedia *)media resume:(BOOL)resume {
    if ((self = [super init])) { _media = media; _resume = resume; _controlsVisible = YES; _lastEngineState = -1; _zoomFactor=1; _displayMode=@"fit"; self.modalPresentationStyle = UIModalPresentationFullScreen; }
    return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)viewDidLoad {
    [super viewDidLoad];
    MSPlaybackChromeView *chrome=[[MSPlaybackChromeView alloc] initWithTitle:self.media.title target:self];
    self.view=chrome;
    self.videoViewport=chrome.videoViewport;
    self.videoView=chrome.videoView;
    self.subtitleOverlay=chrome.subtitleOverlay;
    self.header=chrome.header;
    self.footer=chrome.footer;
    self.statusPanel=chrome.statusPanel;
    self.titleLabel=chrome.titleLabel;
    self.timeLabel=chrome.timeLabel;
    self.statusLabel=chrome.statusLabel;
    self.playButton=chrome.playButton;
    self.audioButton=chrome.audioButton;
    self.subtitleButton=chrome.subtitleButton;
    self.retryButton=chrome.retryButton;
    self.nextButton=chrome.nextButton;
    self.displayButton=chrome.displayButton;
    self.fullscreenButton=chrome.fullscreenButton;
    self.backButton=chrome.backButton;
    self.forwardButton=chrome.forwardButton;
    self.statusSpinner=chrome.statusSpinner;
    self.seekSlider=chrome.seekSlider;
    self.captionBottom=chrome.captionBottom;
    self.captionTop=chrome.captionTop;
    self.statusBottom=chrome.statusBottom;
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(servicesLost:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
    [center addObserver:self selector:@selector(servicesReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [center addObserver:self selector:@selector(voiceOverStatusChanged:) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
    [self updateStatusAppearance];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!self.prepared && !self.closing) { self.prepared = YES; [self beginPlayback]; } }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; if (self.isBeingDismissed || !self.presentingViewController) [self tearDownSaving:YES]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch { (void)gesture; for (UIView *view=touch.view;view;view=view.superview) if ([view isKindOfClass:UIControl.class]) return NO; return YES; }
- (BOOL)voiceOverIsRunning { return UIAccessibilityIsVoiceOverRunning(); }
- (void)voiceOverStatusChanged:(NSNotification *)notification {
    (void)notification;
    if(!NSThread.isMainThread) { __weak typeof(self) weakSelf=self; dispatch_async(dispatch_get_main_queue(),^{ [weakSelf voiceOverStatusChanged:nil]; }); return; }
    if(self.closing)return;
    if([self voiceOverIsRunning]) [self setControlsVisible:YES]; else [self scheduleHide];
}
- (void)toggleControls { [self setControlsVisible:!self.controlsVisible]; }
- (void)setControlsVisible:(BOOL)visible {
    if(!visible && [self voiceOverIsRunning])visible=YES;
    _controlsVisible = visible; self.header.hidden = !visible; self.footer.hidden = !visible;
    [self updateCaptionInsets]; [self setNeedsStatusBarAppearanceUpdate];
    if (visible) [self scheduleHide]; else { [self.hideTimer invalidate]; self.hideTimer = nil; }
}
- (void)updateCaptionInsets {
    self.captionTop.constant = self.controlsVisible ? self.header.bounds.size.height + 4 : 12;
    self.captionBottom.constant = self.controlsVisible ? -self.footer.bounds.size.height - 4 : -12;
    self.statusBottom.constant=self.controlsVisible?-self.footer.bounds.size.height-12:-20;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];[self updateCaptionInsets];
    if(!CGSizeEqualToSize(self.appliedVideoSize,self.videoViewport.bounds.size))[self applyVideoLayout];
    [self updateStatusAppearance];
}
- (CGSize)naturalVideoSize {
    CGSize size=self.player.videoSize;
    for(NSDictionary *track in self.player.media.tracksInformation) {
        if(![track[VLCMediaTracksInformationType] isEqual:VLCMediaTracksInformationTypeVideo])continue;
        double w=[track[VLCMediaTracksInformationVideoWidth] doubleValue],h=[track[VLCMediaTracksInformationVideoHeight] doubleValue];
        double numerator=[track[VLCMediaTracksInformationSourceAspectRatio] doubleValue],denominator=[track[VLCMediaTracksInformationSourceAspectRatioDenominator] doubleValue];
        if(w>0 && h>0) { if(numerator>0 && denominator>0)w*=numerator/denominator; size=CGSizeMake(w,h);NSInteger orientation=[track[VLCMediaTracksInformationVideoOrientation] integerValue];if(orientation>=4 && orientation<=7)size=CGSizeMake(h,w); }
        break;
    }
    return size.width>0 && size.height>0 && isfinite(size.width) && isfinite(size.height)?size:CGSizeMake(16,9);
}
- (void)applyVideoLayout {
    CGSize viewport=self.videoViewport.bounds.size;if(viewport.width<=0 || viewport.height<=0)return;
    CGSize natural=self.player && self.ready?[self naturalVideoSize]:CGSizeMake(16,9);
    CGRect base=MSVideoPictureRect(viewport,natural,@"fit",1);
    // Stable drawable bounds keep the decoder's backing buffer unchanged during
    // a pinch. Only compositor transforms change; captions/controls never zoom.
    if(!CGSizeEqualToSize(self.videoView.bounds.size,base.size))self.videoView.bounds=(CGRect){CGPointZero,base.size};
    self.videoView.center=CGPointMake(viewport.width/2,viewport.height/2);
    CGRect picture=MSVideoPictureRect(viewport,natural,self.displayMode ?: @"fit",self.zoomFactor);
    self.videoView.transform=CGAffineTransformMakeScale(picture.size.width/base.size.width,picture.size.height/base.size.height);
    self.appliedVideoSize=viewport;self.sourceVideoSize=natural;
}
- (void)selectDisplayMode:(NSString *)mode {
    if(![@[@"fit",@"fill",@"stretch",@"16:9",@"4:3",@"1:1",@"2.35:1"] containsObject:mode])return;
    self.displayMode=mode;self.zoomFactor=1;[self applyVideoLayout];[self scheduleHide];
}
- (void)setVideoZoom:(CGFloat)zoom { self.zoomFactor=MSVideoBoundedZoom(zoom);[self applyVideoLayout]; }
- (void)pinchedVideo:(UIPinchGestureRecognizer *)gesture {
    if(!self.ready)return;
    if(gesture.state==UIGestureRecognizerStateBegan){self.pinchStartZoom=self.zoomFactor;[self.hideTimer invalidate];self.hideTimer=nil;}
    else if(gesture.state==UIGestureRecognizerStateChanged || gesture.state==UIGestureRecognizerStateEnded){[self setVideoZoom:self.pinchStartZoom*gesture.scale];if(gesture.state==UIGestureRecognizerStateEnded)[self scheduleHide];}
    else if(gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed){[self setVideoZoom:self.pinchStartZoom];[self scheduleHide];}
}
- (void)enterFullscreen { [self setControlsVisible:NO]; }
- (void)showDisplayOptions {
    if(self.presentedViewController)return;[self.hideTimer invalidate];self.hideTimer=nil;
    __weak typeof(self) weakSelf=self;
    MSVideoOptionsViewController *options=[[MSVideoOptionsViewController alloc] initWithMode:self.displayMode ?: @"fit" zoom:self.zoomFactor change:^(NSString *mode,CGFloat zoom){typeof(self) self=weakSelf;if(!self || self.closing)return;self.displayMode=mode;[self setVideoZoom:zoom];}];
    options.popoverPresentationController.sourceView=self.displayButton;options.popoverPresentationController.sourceRect=self.displayButton.bounds;options.popoverPresentationController.delegate=self;
    [self presentViewController:options animated:YES completion:nil];
}
- (void)popoverPresentationControllerDidDismissPopover:(UIPopoverPresentationController *)popover { (void)popover;[self scheduleHide]; }
- (void)updatePlayAppearance {
    BOOL playing=self.player && self.player.isPlaying;
    [self.playButton setImage:MSPlayerIcon(playing?@"pause":@"play") forState:UIControlStateNormal];self.playButton.accessibilityLabel=playing?@"Pause":@"Play";
}
- (void)updateStatusAppearance {
    self.statusLabel.numberOfLines=self.statusLabel.text.length<=48?1:0;
    BOOL waiting=!self.statusPanel.hidden && self.retryButton.hidden && self.nextButton.hidden && !self.closing;
    if(waiting)[self.statusSpinner startAnimating];else[self.statusSpinner stopAnimating];
}
- (void)scheduleHide {
    [self.hideTimer invalidate]; self.hideTimer = nil;
    if (!self.controlsVisible || !self.ready || !self.player.isPlaying || self.scrubbing || self.presentedViewController || !self.statusPanel.hidden || [self voiceOverIsRunning]) return;
    __weak typeof(self) weakSelf = self; self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:4 repeats:NO block:^(NSTimer *timer) {
        typeof(self) self=weakSelf; if (!self || self.hideTimer!=timer)return;
        self.hideTimer=nil;
        if([self voiceOverIsRunning]) { [self setControlsVisible:YES]; return; }
        if(!self.ready || !self.player.isPlaying || self.presentedViewController || self.scrubbing || !self.statusPanel.hidden)return;
        [self setControlsVisible:NO];
    }];
}
- (void)beginPlayback {
    if (self.closing || self.player || self.mediaServicesUnavailable || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if(self.waitingForStop) { self.restartAfterStop=YES; self.statusPanel.hidden=NO; self.statusLabel.text=@"Stopping the previous video…"; self.retryButton.hidden=YES; return; }
    if(MSVLCRetirement.pendingCount>=2) { [self fail:@"A previous video has not stopped. Close StremIOS from the app switcher before trying again." code:5]; return; }
    self.generation++; self.ready=NO; self.seekPending=NO; self.sourceSaved=NO; self.restoredAudio=NO; self.retryFromBeginning=NO; self.interrupted=NO; self.lastEngineState=-1;
    self.knownAudioTracks=@[]; self.knownSubtitleTracks=@[]; self.lastObservedTime=0; self.lastAdvanceTime=NSProcessInfo.processInfo.systemUptime; self.lastPersistedAt=0; self.lastDiagnosticAt=0;
    self.statusPanel.hidden=NO; self.statusLabel.text=@"Loading…"; self.retryButton.hidden=YES; self.nextButton.hidden=YES; [self setControlsVisible:YES];
    AVAudioSession *audio=AVAudioSession.sharedInstance; NSError *error=nil;
    if (![audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&error] || ![audio setActive:YES error:&error]) { [self fail:@"Audio could not start. Retry when the iPad is ready." code:1]; return; }
    self.ownsAudioSession=YES; self.audioOwner=MSClaimAudioSession();
    // Never install a console/file logger: engine messages can contain private URLs.
    NSArray *options=[@[@"--quiet",@"--no-video-title-show",@"--no-osd"] arrayByAddingObjectsFromArray:MSVLCSubtitleOptions(MSPlaybackPreferences.sharedPreferences)];
    options=[options arrayByAddingObjectsFromArray:MSVLCAdaptiveOptions(MSPlaybackPreferences.sharedPreferences)];
    self.player=[[VLCMediaPlayer alloc] initWithOptions:options];
    self.player.libraryInstance.loggers=nil; self.player.delegate=self; self.player.drawable=self.videoView;
    self.player.scaleFactor=0;self.player.videoAspectRatio=NULL;self.player.videoCropGeometry=NULL;
    VLCMedia *input=[VLCMedia mediaWithURL:self.media.streamURL]; [input addOption:@":network-caching=1500"]; self.player.media=input; self.player.audio.muted=YES;
    self.subtitles=[[MSSubtitleController alloc] initWithPlaybackSource:self overlayView:self.subtitleOverlay type:self.media.mediaType ?: @"movie" videoID:self.media.identifier extras:self.media.subtitleExtras ?: @{}];
    [self.subtitles setStreamSourceFingerprint:self.media.sourceFingerprint]; [self.subtitles setStreamSubtitles:self.media.streamSubtitles ?: @[]];
    __weak typeof(self) weakSelf=self; NSUInteger generation=self.generation;
    self.startupTimer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *timer) { typeof(self) self=weakSelf; if (!self || self.startupTimer!=timer || self.generation!=generation || self.ready) return; [self fail:@"Video did not start within 30 seconds. Retry playback or return with Done." code:2]; }];
    [self startTickTimer];
    [self recordStage:@"preparing" code:0]; [self.player play];
}
- (NSTimeInterval)duration { double seconds=self.player.media.length.value.doubleValue/1000.0; return isfinite(seconds)&&seconds>0 ? seconds : 0; }
- (NSTimeInterval)currentTime { double seconds=self.player.time.value.doubleValue/1000.0; return isfinite(seconds)&&seconds>=0 ? seconds : 0; }
- (void)mediaPlayerStateChanged:(NSNotification *)notification {
    VLCMediaPlayer *player=notification.object; __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{ typeof(self) self=weakSelf; if(self && !self.closing && self.player==player) [self handleState]; });
}
- (void)mediaPlayerTimeChanged:(NSNotification *)notification {
    VLCMediaPlayer *player=notification.object; __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{ typeof(self) self=weakSelf; if(self && !self.closing && self.player==player) [self tick]; });
}
- (void)handleState {
    if (!self.player || self.closing) return;
    VLCMediaPlayerState state=self.player.state;
    if (self.lastEngineState!=state) { self.lastEngineState=state; [self recordStage:@"state" code:0]; }
    if (state==VLCMediaPlayerStateError) { [self fail:@"This source could not play. Try another source or retry playback." code:3]; return; }
    if (state==VLCMediaPlayerStateEnded) { [self ended]; return; }
    // VLC 3 can retain its Buffering enum after a successful seek while
    // frames and the timeline advance. Readiness must follow actual output.
    BOOL producingVideo = self.player.isPlaying && self.player.hasVideoOut && self.currentTime > 0 && self.player.media.statistics.displayedPictures > 0;
    if (!self.ready && producingVideo) [self prepareReady];
    if (state==VLCMediaPlayerStateESAdded || (self.ready && NSProcessInfo.processInfo.systemUptime-self.lastTrackRefreshAt>2)) [self refreshTracks];
    if(self.ready && state==VLCMediaPlayerStatePaused) { [self.tickTimer invalidate]; self.tickTimer=nil; }
    else if(state==VLCMediaPlayerStatePlaying || state==VLCMediaPlayerStateBuffering) [self startTickTimer];
    if (self.ready) [self updatePlayAppearance];
}
- (void)startTickTimer {
    if(self.tickTimer || !self.player || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    __weak typeof(self) weakSelf=self; NSUInteger generation=self.generation;
    self.tickTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { typeof(self) self=weakSelf; if(self && self.tickTimer==timer && self.generation==generation)[self tick]; }];
}
- (void)prepareReady {
    if (!self.player || self.ready || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    NSTimeInterval duration=self.duration;
    double saved=[[MSLibraryStore.sharedStore recordForIdentifier:self.media.identifier][@"position"] doubleValue];
    if (self.resume && saved>=5 && duration<=0) { self.statusLabel.text=@"Waiting to restore your place…"; return; }
    if (!self.seekPending) {
        NSTimeInterval target=self.resume ? [MSLibraryStore.sharedStore resumeFor:self.media.identifier duration:duration] : 0;
        if (target>0) {
            if (!self.player.isSeekable) { [self fail:@"This source cannot restore the saved position. You can play from the beginning." code:4]; self.retryFromBeginning=YES; [self.retryButton setTitle:@"Play from beginning" forState:UIControlStateNormal]; return; }
            self.initialSeekTarget=target; self.seekPending=YES; self.statusLabel.text=@"Restoring your place…"; self.player.time=[VLCTime timeWithNumber:@(llround(target*1000))]; return;
        }
    } else if (fabs(self.currentTime-self.initialSeekTarget)>3) return;
    self.seekPending=NO; self.ready=YES; [self.startupTimer invalidate]; self.startupTimer=nil;
    self.advanceBaseline=self.currentTime; self.lastObservedTime=self.currentTime; self.lastAdvanceTime=NSProcessInfo.processInfo.systemUptime;
    self.sourceAdvanceSeconds=0; self.sourceObservationStartedAt=self.lastAdvanceTime; self.lastDisplayedPictures=self.player.media.statistics.displayedPictures;
    self.lastProgressMediaTime=self.currentTime; self.lastProgressPictures=self.lastDisplayedPictures; self.showingBuffering=NO;
    self.audioRestoreDeadline=self.lastAdvanceTime+5;
    [MSLibraryStore.sharedStore registerMetadata:self.media.libraryMetadata ?: @{} forVideoIdentifier:self.media.identifier];
    if (!self.resume) [MSLibraryStore.sharedStore clearPositionFor:self.media.identifier];
    self.player.audio.muted=NO; self.playButton.enabled=YES; self.subtitleButton.enabled=YES; self.statusPanel.hidden=YES;
    [self applyVideoLayout];
    [self refreshTracks]; [self.subtitles restoreSelectionForContentIdentifier:self.media.identifier]; [self recordStage:@"ready" code:0]; [self scheduleHide];
}
- (void)tick {
    if (!self.player || self.closing || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    [self handleState]; if(!self.player)return;
    NSTimeInterval current=self.currentTime,duration=self.duration,now=NSProcessInfo.processInfo.systemUptime;
    // A paused decoder can report the preceding keyframe after a seek. Keep
    // the requested position in the UI until playback is advancing again.
    if(self.userSeekPending && self.player.isPlaying && (fabs(current-self.userSeekTarget)<1.5 || now-self.userSeekStartedAt>5)) self.userSeekPending=NO;
    NSTimeInterval displayedTime=self.userSeekPending ? self.userSeekTarget : current;
    if (!self.scrubbing) { self.seekSlider.value=duration>0 ? fmin(1,displayedTime/duration) : 0; [self displayTime:displayedTime duration:duration]; }
    self.seekSlider.enabled=self.ready && duration>0 && self.player.isSeekable;self.backButton.enabled=self.seekSlider.enabled;self.forwardButton.enabled=self.seekSlider.enabled;
    [self updateStatusAppearance];
    if(self.ready && !CGSizeEqualToSize(self.sourceVideoSize,[self naturalVideoSize]))[self applyVideoLayout];
    if (!self.ready)return;
    NSInteger pictures=self.player.media.statistics.displayedPictures;
    NSTimeInterval delta=current-self.lastObservedTime;
    // Time and picture statistics arrive on different VLC callbacks. Accumulate
    // continuous media time independently, then require output and wall time.
    if(!self.sourceSaved && !self.scrubbing && delta>0 && delta<2.5) self.sourceAdvanceSeconds+=delta;
    // The state enum can stay Buffering while output advances. Detect real
    // progress from cumulative clock/frame observations instead of that enum
    // or a per-callback threshold (callbacks can arrive very close together).
    BOOL advancing=current>self.lastProgressMediaTime+0.1 || pictures>self.lastProgressPictures;
    if (advancing) {
        self.lastAdvanceTime=now;
        self.lastProgressMediaTime=current; self.lastProgressPictures=pictures;
        if(self.showingBuffering) { self.showingBuffering=NO; self.statusPanel.hidden=YES; self.retryButton.hidden=YES; [self scheduleHide]; }
    } else if (self.player.isPlaying && now-self.lastAdvanceTime>10 && !self.scrubbing && !self.userSeekPending) {
        self.showingBuffering=YES; self.statusPanel.hidden=NO; self.statusLabel.text=@"Buffering…";
        self.retryButton.hidden=now-self.lastAdvanceTime<=30;
        if(!self.retryButton.hidden) { self.statusLabel.text=@"Playback has stalled."; [self.retryButton setTitle:@"Retry playback" forState:UIControlStateNormal]; }
    } else if (!self.player.isPlaying && self.showingBuffering) {
        self.showingBuffering=NO; self.statusPanel.hidden=YES; self.retryButton.hidden=YES;
    }
    if (!self.sourceSaved && self.sourceAdvanceSeconds>2 && now-self.sourceObservationStartedAt>2 && pictures>self.lastDisplayedPictures) { self.sourceSaved=YES; [MSLibraryStore.sharedStore saveSourceFingerprint:self.media.sourceFingerprint forIdentifier:self.media.identifier]; [self recordStage:@"playback-advanced" code:0]; }
    self.lastObservedTime=current;
    if(now-self.lastPersistedAt>=5) { [self persistProgress]; self.lastPersistedAt=now; }
    if(now-self.lastDiagnosticAt>=5) { [self recordStage:self.player.isPlaying ? @"playing" : @"paused" code:0]; self.lastDiagnosticAt=now; }
    // Menu dismissal paths differ on iOS 12. Rearm only a missing timer;
    // scheduleHide keeps menus, paused playback and VoiceOver visible.
    if(self.controlsVisible && !self.hideTimer.isValid)[self scheduleHide];
}
- (void)displayTime:(NSTimeInterval)time duration:(NSTimeInterval)duration { self.timeLabel.text=duration>0 ? [NSString stringWithFormat:@"%@ / %@",MSTimeDescription(time),MSTimeDescription(duration)] : MSTimeDescription(time); self.seekSlider.accessibilityValue=self.timeLabel.text; }
- (void)togglePlayback {
    if(!self.player || !self.ready)return;
    if(self.player.isPlaying) { [self.player pause]; [self persistProgress]; [self setControlsVisible:YES]; }
    else { self.lastAdvanceTime=NSProcessInfo.processInfo.systemUptime; if(self.userSeekPending)self.userSeekStartedAt=self.lastAdvanceTime; [self.player play]; [self scheduleHide]; }
    [self updatePlayAppearance];
}
- (void)seekBegan:(UISlider *)slider { (void)slider; self.scrubbing=YES; [self.hideTimer invalidate]; self.hideTimer=nil; }
- (void)seekChanged:(UISlider *)slider { if(self.ready && self.player.isSeekable) { [self displayTime:slider.value*self.duration duration:self.duration]; if(!slider.isTracking && !self.scrubbing)[self seekEnded:slider]; } }
- (void)seekTapped:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateEnded || !self.seekSlider.enabled)return;
    CGRect track=[self.seekSlider trackRectForBounds:self.seekSlider.bounds];CGFloat x=[gesture locationInView:self.seekSlider].x;
    if(track.size.width>0)[self seekToFraction:(x-track.origin.x)/track.size.width];
}
- (void)seekToFraction:(CGFloat)fraction {
    if(!isfinite(fraction))return;self.scrubbing=NO;
    if(self.ready && self.player.isSeekable && self.duration>0){
        fraction=MAX(0,MIN(1,fraction));self.seekSlider.value=fraction;
        self.userSeekTarget=llround(fraction*self.duration*1000)/1000.0;self.userSeekPending=YES;
        self.player.time=[VLCTime timeWithNumber:@(llround(self.userSeekTarget*1000))];
        self.lastAdvanceTime=NSProcessInfo.processInfo.systemUptime;self.userSeekStartedAt=self.lastAdvanceTime;
        self.sourceAdvanceSeconds=0;self.sourceObservationStartedAt=self.lastAdvanceTime;self.lastDisplayedPictures=self.player.media.statistics.displayedPictures;
        [self displayTime:self.userSeekTarget duration:self.duration];
    }[self scheduleHide];
}
- (void)seekEnded:(UISlider *)slider { [self seekToFraction:slider.value]; }
- (void)skipBackward { if(self.duration>0)[self seekToFraction:((self.userSeekPending?self.userSeekTarget:self.currentTime)-15)/self.duration]; }
- (void)skipForward { if(self.duration>0)[self seekToFraction:((self.userSeekPending?self.userSeekTarget:self.currentTime)+15)/self.duration]; }
- (void)seekCancelled:(UISlider *)slider { (void)slider; self.scrubbing=NO; [self tick]; [self scheduleHide]; }
- (NSArray<NSDictionary *> *)tracksAudio:(BOOL)audio {
    if(!self.ready || !self.player)return @[];
    NSArray *indexes=audio ? self.player.audioTrackIndexes : self.player.videoSubTitlesIndexes;
    NSArray *names=audio ? self.player.audioTrackNames : self.player.videoSubTitlesNames;
    NSMutableArray *tracks=[NSMutableArray array];
    for(NSUInteger i=0;i<MIN((NSUInteger)200,indexes.count);i++) {
        NSNumber *identifier=[indexes[i] isKindOfClass:NSNumber.class] ? indexes[i] : nil; if(!identifier || identifier.integerValue<0)continue;
        NSString *name=i<names.count ? MSVLCTrackText(names[i],160) : @""; if(!name.length)name=audio ? @"Audio track" : @"Subtitle track";
        NSString *language=@"";
        for(NSDictionary *info in self.player.media.tracksInformation) if([info isKindOfClass:NSDictionary.class] && [info[VLCMediaTracksInformationId] integerValue]==identifier.integerValue && [info[VLCMediaTracksInformationType] isEqual:audio ? VLCMediaTracksInformationTypeAudio : VLCMediaTracksInformationTypeText]) { language=MSVLCTrackText(info[VLCMediaTracksInformationLanguage],30); break; }
        [tracks addObject:@{@"id":identifier,@"name":name,@"language":language}];
    } return tracks;
}
- (BOOL)language:(NSString *)actual matches:(NSString *)desired {
    NSDictionary *codes=@{@"en":@"eng",@"hi":@"hin"}; NSString *a=[[actual lowercaseString] componentsSeparatedByString:@"-"].firstObject, *b=[[desired lowercaseString] componentsSeparatedByString:@"-"].firstObject; return a.length && [(codes[a] ?: a) isEqual:(codes[b] ?: b)];
}
- (void)refreshTracks {
    if(!self.ready || !self.player)return;
    self.lastTrackRefreshAt=NSProcessInfo.processInfo.systemUptime;
    NSArray *audio=[self tracksAudio:YES], *subtitles=[self tracksAudio:NO]; self.audioButton.enabled=audio.count>0;
    BOOL subtitleChanged=![subtitles isEqual:self.knownSubtitleTracks]; self.knownAudioTracks=audio; self.knownSubtitleTracks=subtitles;
    if(!self.restoredAudio && audio.count) {
        NSDictionary *saved=[MSLibraryStore.sharedStore playbackSelectionsForIdentifier:self.media.identifier][@"audio"];
        NSString *language=saved[@"language"] ?: MSPlaybackPreferences.sharedPreferences.preferredAudioLanguage;
        NSDictionary *match=nil; for(NSDictionary *track in audio) { BOOL same=[self language:track[@"language"] matches:language]; if([track[@"name"] isEqual:saved[@"displayName"]] && (same || !language.length)) { match=track; break; } if(!match && same)match=track; }
        if(match)self.player.currentAudioTrackIndex=[match[@"id"] intValue];
        self.restoredAudio=match!=nil || NSProcessInfo.processInfo.systemUptime>=self.audioRestoreDeadline;
    }
    if(subtitleChanged) [self.subtitles refreshEmbeddedTracks];
}
- (void)showAudio {
    [self refreshTracks]; if(!self.ready || !self.knownAudioTracks.count || self.presentedViewController)return; [self setControlsVisible:YES];
    UIAlertController *picker=[UIAlertController alertControllerWithTitle:@"Audio" message:nil preferredStyle:UIAlertControllerStyleActionSheet]; NSUInteger generation=self.generation; __weak typeof(self) weakSelf=self;
    for(NSDictionary *track in self.knownAudioTracks) { NSString *title=[track[@"id"] integerValue]==self.player.currentAudioTrackIndex ? [@"✓ " stringByAppendingString:track[@"name"]] : track[@"name"];
        [picker addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; typeof(self) self=weakSelf; if(!self || !self.ready || self.generation!=generation)return; self.restoredAudio=YES; self.player.currentAudioTrackIndex=[track[@"id"] intValue]; NSMutableDictionary *selections=[[MSLibraryStore.sharedStore playbackSelectionsForIdentifier:self.media.identifier] mutableCopy] ?: [NSMutableDictionary dictionary]; selections[@"audio"]=@{@"language":track[@"language"],@"displayName":track[@"name"]}; [MSLibraryStore.sharedStore savePlaybackSelections:selections forIdentifier:self.media.identifier]; [self scheduleHide]; }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]]; picker.popoverPresentationController.sourceView=self.audioButton; picker.popoverPresentationController.sourceRect=self.audioButton.bounds; picker.popoverPresentationController.delegate=self; self.audioPicker=picker; [self presentViewController:picker animated:YES completion:nil];
}
- (void)showSubtitles { if(!self.ready || self.presentedViewController)return; [self refreshTracks]; [self setControlsVisible:YES]; [self.subtitles setStreamSubtitles:self.media.streamSubtitles ?: @[]]; [self.subtitles presentFromViewController:self]; }
- (NSTimeInterval)subtitlePlaybackTime { return self.currentTime; }
- (BOOL)subtitlePlaybackActive { return self.ready && self.player && !self.closing && UIApplication.sharedApplication.applicationState==UIApplicationStateActive; }
- (NSArray<NSDictionary *> *)subtitleEmbeddedTracks { return self.ready ? [self tracksAudio:NO] : @[]; }
- (NSInteger)subtitleSelectedEmbeddedTrackID { return self.ready && self.player ? self.player.currentVideoSubTitleIndex : -1; }
- (void)subtitleSelectEmbeddedTrackID:(NSInteger)identifier { if(!self.ready || !self.player)return; if(identifier==-1) { self.player.currentVideoSubTitleIndex=-1; return; } for(NSDictionary *track in [self tracksAudio:NO])if([track[@"id"] integerValue]==identifier) { self.player.currentVideoSubTitleIndex=(int)identifier; return; } }
- (void)persistProgress { if(!self.ready || self.seekPending || !self.player)return; [MSLibraryStore.sharedStore savePosition:self.userSeekPending ? self.userSeekTarget : self.currentTime duration:self.duration for:self.media.identifier]; }
- (void)inactive:(NSNotification *)note {
    (void)note; if(self.closing || (!self.player && !self.waitingForStop))return; self.interrupted=YES; self.restartAfterStop=NO; [self tearDownSaving:YES]; self.resume=YES;
    self.statusPanel.hidden=NO; self.statusLabel.text=@"Playback paused. Tap Resume playback when you return."; [self.retryButton setTitle:@"Resume playback" forState:UIControlStateNormal]; self.retryButton.hidden=NO; [self setControlsVisible:YES]; [self recordStage:@"inactive" code:0];
}
- (void)active:(NSNotification *)note { (void)note; if(!self.closing && self.interrupted) { self.retryButton.enabled=!self.mediaServicesUnavailable; [self setControlsVisible:YES]; } }
- (void)audioInterrupted:(NSNotification *)note { if([note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]!=AVAudioSessionInterruptionTypeBegan)return; dispatch_async(dispatch_get_main_queue(),^{ [self inactive:note]; }); }
- (void)routeChanged:(NSNotification *)note { if([note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue]!=AVAudioSessionRouteChangeReasonOldDeviceUnavailable)return; dispatch_async(dispatch_get_main_queue(),^{ [self inactive:note]; }); }
- (void)servicesLost:(NSNotification *)note { dispatch_async(dispatch_get_main_queue(),^{ if(self.closing)return; self.mediaServicesUnavailable=YES; MSAbandonAudioSession(self.audioOwner); self.audioOwner=nil; self.ownsAudioSession=NO; [self inactive:note]; self.retryButton.enabled=NO; self.statusLabel.text=@"Waiting for the iPad’s media service to recover…"; }); }
- (void)servicesReset:(NSNotification *)note { dispatch_async(dispatch_get_main_queue(),^{ if(self.closing)return; self.mediaServicesUnavailable=NO; MSAbandonAudioSession(self.audioOwner); self.audioOwner=nil; self.ownsAudioSession=NO; [self inactive:note]; self.retryButton.enabled=YES; self.statusLabel.text=@"The media service restarted. Tap Resume playback."; }); }
- (void)fail:(NSString *)message code:(NSInteger)code { [self recordStage:@"failed" code:code]; [self tearDownSaving:YES]; self.statusPanel.hidden=NO; self.statusLabel.text=message; self.nextButton.hidden=YES; [self.retryButton setTitle:@"Retry playback" forState:UIControlStateNormal]; self.retryButton.hidden=NO; self.retryButton.enabled=!self.mediaServicesUnavailable; [self setControlsVisible:YES]; }
- (void)ended { [MSLibraryStore.sharedStore clearPositionFor:self.media.identifier]; [self recordStage:@"ended" code:0]; [self tearDownSaving:NO]; self.resume=NO; self.statusPanel.hidden=NO; self.statusLabel.text=@"Finished"; [self.retryButton setTitle:@"Play again" forState:UIControlStateNormal]; self.retryButton.hidden=NO; self.nextButton.hidden=!self.nextEpisodeHandler; [self.nextButton setTitle:self.nextEpisodeTitle.length ? [NSString stringWithFormat:@"Next · %@",self.nextEpisodeTitle] : @"Next episode" forState:UIControlStateNormal]; [self setControlsVisible:YES]; }
- (void)retryPlayback { if(self.closing || self.mediaServicesUnavailable)return; BOOL fromBeginning=self.retryFromBeginning; [self tearDownSaving:YES]; self.resume=!fromBeginning; [self beginPlayback]; }
- (void)recordStage:(NSString *)stage code:(NSInteger)code {
    NSMutableDictionary *report=[@{@"schemaVersion":@2,@"engine":@"vlc",@"stage":stage,@"recordedAt":@(NSDate.date.timeIntervalSince1970),@"generation":@(self.generation),@"engineState":@(self.player ? self.player.state : -1),@"errorClass":@(code),@"ready":@(self.ready),@"seeking":@(self.seekPending),@"currentTimeSeconds":@(self.currentTime),@"durationSeconds":@(self.duration),@"sourceAdvanceRecorded":@(self.sourceSaved)} mutableCopy];
    if(self.player) { VLCMediaStats stats=self.player.media.statistics; report[@"decodedVideo"]=@(stats.decodedVideo); report[@"displayedPictures"]=@(stats.displayedPictures); report[@"lostPictures"]=@(stats.lostPictures); report[@"decodedAudio"]=@(stats.decodedAudio); report[@"playedAudioBuffers"]=@(stats.playedAudioBuffers); report[@"videoWidth"]=@(self.player.videoSize.width); report[@"videoHeight"]=@(self.player.videoSize.height); }
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:0 error:nil]; NSURL *cache=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    if(cache && data.length && data.length<=4096) { [NSFileManager.defaultManager createDirectoryAtURL:cache withIntermediateDirectories:YES attributes:nil error:nil]; [data writeToURL:[cache URLByAppendingPathComponent:@"MiniStreamPlaybackState.json"] options:NSDataWritingAtomic error:nil]; if(code)[data writeToURL:[cache URLByAppendingPathComponent:@"MiniStreamLastPlaybackFailure.json"] options:NSDataWritingAtomic error:nil]; }
}
- (void)tearDownSaving:(BOOL)save {
    if(save)[self persistProgress]; self.generation++; self.ready=NO; self.seekPending=NO; self.scrubbing=NO; self.userSeekPending=NO; self.showingBuffering=NO;
    [self.startupTimer invalidate]; self.startupTimer=nil; [self.tickTimer invalidate]; self.tickTimer=nil; [self.hideTimer invalidate]; self.hideTimer=nil;
    [self.subtitles invalidate]; self.subtitles=nil; [self.audioPicker dismissViewControllerAnimated:NO completion:nil]; self.audioPicker=nil;
    VLCMediaPlayer *old=self.player; self.player=nil;
    if(old) {
        NSObject *retiredAudioOwner=self.audioOwner; self.audioOwner=nil; self.ownsAudioSession=NO;
        self.waitingForStop=YES; self.stopTimedOut=NO; __weak typeof(self) weakSelf=self;
        [MSVLCRetirement retire:old completion:^(BOOL stopped) {
            if(stopped)MSReleaseAudioSession(retiredAudioOwner);
            typeof(self) self=weakSelf; if(!self)return;
            if(stopped) {
                self.waitingForStop=NO; self.stopTimedOut=NO;
                dispatch_block_t action=self.afterStopAction; self.afterStopAction=nil; if(action)action();
                BOOL restart=self.restartAfterStop; self.restartAfterStop=NO; if(restart && !self.closing)[self beginPlayback];
            }
            else {
                self.stopTimedOut=YES;
                if(self.closing) { dispatch_block_t action=self.afterStopAction; self.afterStopAction=nil; if(action)action(); }
                else { self.restartAfterStop=NO; self.statusPanel.hidden=NO; self.statusLabel.text=@"The previous video is taking too long to stop. Return with Done and try again."; self.retryButton.hidden=YES; [self setControlsVisible:YES]; }
            }
        }];
    }
    self.knownAudioTracks=@[]; self.knownSubtitleTracks=@[]; self.playButton.enabled=NO; self.audioButton.enabled=NO; self.subtitleButton.enabled=NO; self.seekSlider.enabled=NO;
    if(!old && !self.waitingForStop && self.ownsAudioSession) { MSReleaseAudioSession(self.audioOwner); self.audioOwner=nil; self.ownsAudioSession=NO; }
}
- (void)closePlayer {
    if(self.closing)return; self.closing=YES; __weak typeof(self) weakSelf=self;
    self.afterStopAction=^{ [weakSelf dismissViewControllerAnimated:YES completion:nil]; }; [self tearDownSaving:YES];
    if(!self.waitingForStop || self.stopTimedOut) { dispatch_block_t action=self.afterStopAction; self.afterStopAction=nil; if(action)action(); }
}
- (void)playNextEpisode {
    if(self.closing || !self.nextEpisodeHandler || self.nextButton.hidden)return; dispatch_block_t handler=self.nextEpisodeHandler; self.closing=YES; __weak typeof(self) weakSelf=self;
    self.afterStopAction=^{ [weakSelf dismissViewControllerAnimated:YES completion:handler]; }; [self tearDownSaving:NO];
    if(!self.waitingForStop || self.stopTimedOut) { dispatch_block_t action=self.afterStopAction; self.afterStopAction=nil; if(action)action(); }
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self tearDownSaving:YES]; }
@end
