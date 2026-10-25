#import "MSPlaybackViewController.h"
#import "MSMedia.h"
#import "MSTheme.h"
#import "MSLibraryStore.h"
#import "MSPlaybackPolicy.h"
#import "MSSubtitleController.h"
#import "MSPlaybackPreferences.h"
#import "MSAudioSessionOwnership.h"
#import "MSPlaybackChromeView.h"
#import "MSPlayerControls.h"
#import "MSVideoGeometry.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>

static void *MSItemStatusContext = &MSItemStatusContext;
static void *MSItemDurationContext = &MSItemDurationContext;
static void *MSPlayerStatusContext = &MSPlayerStatusContext;
static void *MSPlayerTimeControlContext = &MSPlayerTimeControlContext;

static NSString *MSSafeErrorDomain(NSString *domain) {
    // Error descriptions and arbitrary domains can contain a stream URL.
    for (NSString *known in @[@"AVFoundationErrorDomain", @"CoreMediaErrorDomain",
                              @"NSURLErrorDomain", @"NSOSStatusErrorDomain",
                              @"NSCocoaErrorDomain", @"NSPOSIXErrorDomain",
                              @"kCFErrorDomainCFNetwork"]) {
        if ([domain isEqualToString:known]) return known;
    }
    return @"OtherErrorDomain";
}

static NSString *MSSafeWaitingReason(AVPlayerWaitingReason reason) {
    if ([reason isEqualToString:AVPlayerWaitingToMinimizeStallsReason]) return @"minimize-stalls";
    if ([reason isEqualToString:AVPlayerWaitingWhileEvaluatingBufferingRateReason]) return @"evaluating-buffer";
    if ([reason isEqualToString:AVPlayerWaitingWithNoItemToPlayReason]) return @"no-item";
    return reason ? @"other" : @"none";
}

@interface MSPlaybackViewController () <UIGestureRecognizerDelegate, UIPopoverPresentationControllerDelegate>
@property (nonatomic, strong) MSMedia *media;
@property (nonatomic) BOOL resume;
@property (nonatomic) BOOL closing;
@property (nonatomic) BOOL observingItem;
@property (nonatomic) BOOL observingDuration;
@property (nonatomic) BOOL observingPlayer;
@property (nonatomic) BOOL observingTimeControl;
@property (nonatomic) BOOL ownsAudioSession;
@property (nonatomic, strong) NSObject *audioSessionToken;
@property (nonatomic) BOOL mediaServicesUnavailable;
@property (nonatomic) BOOL prepared;
@property (nonatomic) BOOL pendingAutoplay;
@property (nonatomic) BOOL initialSeekStarted;
@property (nonatomic) BOOL readyPlaybackStarted;
@property (nonatomic) BOOL hasAdvanceBaseline;
@property (nonatomic) BOOL advanceRecorded;
@property (nonatomic) NSTimeInterval advanceBaseline;
@property (nonatomic) BOOL startupPending;
@property (nonatomic) BOOL bufferingRetryOffered;
@property (nonatomic) BOOL hasPlaybackProgress, showingBufferingStatus;
@property (nonatomic) NSTimeInterval lastPlaybackProgressAt, lastProgressMediaTime, bufferingBeganAt;
@property (nonatomic) NSInteger lastTimeControlStatus;
@property (nonatomic) NSUInteger stallNotificationCount;
@property (nonatomic) NSUInteger playbackGeneration;
@property (nonatomic, strong) NSTimer *startupTimer;
@property (nonatomic, strong) NSTimer *bufferingTimer;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *item;
@property (nonatomic, strong) AVPlayerViewController *nativePlayer;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIButton *subtitleButton;
@property (nonatomic, strong) MSSubtitleController *subtitleController;
@property (nonatomic, strong) UIView *statusPanel;
@property (nonatomic, strong) UIButton *audioButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) AVMediaSelectionGroup *audioGroup;
@property (nonatomic, copy) NSArray<AVMediaSelectionOption *> *audioOptions;
@property (nonatomic, weak) UIAlertController *audioPicker;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UIButton *displayButton;
@property (nonatomic, strong) MSPlaybackChromeView *chrome;
@property (nonatomic, strong) UIView *videoViewport, *videoView, *subtitleOverlay, *footer;
@property (nonatomic, strong) UILabel *titleLabel, *timeLabel;
@property (nonatomic, strong) UIButton *playButton, *backButton, *forwardButton, *fullscreenButton;
@property (nonatomic, strong) UIActivityIndicatorView *statusSpinner;
@property (nonatomic, strong) UISlider *seekSlider;
@property (nonatomic, strong) NSLayoutConstraint *captionTop, *captionBottom, *statusBottom;
@property (nonatomic, strong) NSTimer *hideTimer;
@property (nonatomic, copy) NSString *displayMode;
@property (nonatomic) CGFloat zoomFactor, pinchStartZoom;
@property (nonatomic) CGSize sourceVideoSize, appliedVideoSize;
@property (nonatomic) BOOL controlsVisible, scrubbing, userSeekPending;
@property (nonatomic) NSTimeInterval userSeekTarget, lastUIPersistedAt;
@property (nonatomic) NSUInteger userSeekGeneration;
@property (nonatomic) BOOL fullScreen;
@end

@implementation MSPlaybackViewController
- (instancetype)initWithMedia:(MSMedia *)media resume:(BOOL)resume {
    if ((self = [super init])) {
        _media = media; _resume = resume; _controlsVisible=YES; _zoomFactor=1; _displayMode=@"fit";
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.chrome=[[MSPlaybackChromeView alloc] initWithTitle:self.media.title target:self];
    self.view=self.chrome;
    self.videoViewport=self.chrome.videoViewport; self.videoView=self.chrome.videoView; self.subtitleOverlay=self.chrome.subtitleOverlay;
    self.header=self.chrome.header; self.footer=self.chrome.footer; self.statusPanel=self.chrome.statusPanel;
    self.titleLabel=self.chrome.titleLabel; self.timeLabel=self.chrome.timeLabel; self.statusLabel=self.chrome.statusLabel;
    self.playButton=self.chrome.playButton; self.audioButton=self.chrome.audioButton; self.subtitleButton=self.chrome.subtitleButton;
    self.retryButton=self.chrome.retryButton; self.nextButton=self.chrome.nextButton; self.displayButton=self.chrome.displayButton;
    self.fullscreenButton=self.chrome.fullscreenButton; self.backButton=self.chrome.backButton; self.forwardButton=self.chrome.forwardButton;
    self.statusSpinner=self.chrome.statusSpinner; self.seekSlider=self.chrome.seekSlider;
    self.captionTop=self.chrome.captionTop; self.captionBottom=self.chrome.captionBottom; self.statusBottom=self.chrome.statusBottom;
    self.nativePlayer=[AVPlayerViewController new];
    self.nativePlayer.allowsPictureInPicturePlayback=NO; self.nativePlayer.showsPlaybackControls=NO;
    self.nativePlayer.videoGravity=AVLayerVideoGravityResizeAspect;
    [self addChildViewController:self.nativePlayer];
    self.nativePlayer.view.frame=self.videoView.bounds;
    self.nativePlayer.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.nativePlayer.view.userInteractionEnabled=NO;
    [self.videoView addSubview:self.nativePlayer.view]; [self.nativePlayer didMoveToParentViewController:self];
    NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(pauseForBackground:) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(enteredBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:self selector:@selector(audioRouteChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(mediaServicesLost:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
    [center addObserver:self selector:@selector(mediaServicesReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [center addObserver:self selector:@selector(voiceOverStatusChanged:) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
    [self updateTransportControls];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.prepared && !self.closing) { self.prepared = YES; [self beginPlayback]; }
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || !self.presentingViewController) [self tearDownSaving:YES];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    (void)gesture; for(UIView *view=touch.view;view;view=view.superview)if([view isKindOfClass:UIControl.class])return NO; return YES;
}
- (BOOL)voiceOverIsRunning { return UIAccessibilityIsVoiceOverRunning(); }
- (void)voiceOverStatusChanged:(NSNotification *)notification {
    (void)notification;
    if(!NSThread.isMainThread) { __weak typeof(self) weakSelf=self; dispatch_async(dispatch_get_main_queue(),^{ [weakSelf voiceOverStatusChanged:nil]; }); return; }
    if(self.closing)return;
    if([self voiceOverIsRunning])[self setControlsVisible:YES];else[self scheduleHide];
}
- (void)toggleControls { [self setControlsVisible:!self.controlsVisible]; }
- (void)revealVideoControls { [self setControlsVisible:YES]; }
- (void)setVideoFullScreen:(BOOL)full { [self setControlsVisible:!full]; }
- (void)enterFullscreen { [self setControlsVisible:NO]; }
- (void)setControlsVisible:(BOOL)visible {
    if(!visible && [self voiceOverIsRunning])visible=YES;
    _controlsVisible=visible; self.fullScreen=!visible; self.header.hidden=!visible; self.footer.hidden=!visible;
    [self updateCaptionInsets]; [self setNeedsStatusBarAppearanceUpdate];
    if(visible)[self scheduleHide];else{[self.hideTimer invalidate];self.hideTimer=nil;}
}
- (void)updateCaptionInsets {
    self.captionTop.constant=0;
    self.captionBottom.constant=0;
    self.statusBottom.constant=self.controlsVisible?-self.footer.bounds.size.height-12:-20;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];[self updateCaptionInsets];
    if(!CGSizeEqualToSize(self.appliedVideoSize,self.videoViewport.bounds.size)||!CGSizeEqualToSize(self.sourceVideoSize,[self naturalVideoSize]))[self applyVideoLayout];
    [self updateStatusAppearance];
}
- (CGSize)naturalVideoSize {
    CGSize size=self.item.presentationSize;
    return size.width>0&&size.height>0&&isfinite(size.width)&&isfinite(size.height)?size:CGSizeMake(16,9);
}
- (void)applyVideoLayout {
    CGSize viewport=self.videoViewport.bounds.size;if(viewport.width<=0||viewport.height<=0)return;
    CGSize natural=[self naturalVideoSize];CGRect base=MSVideoPictureRect(viewport,natural,@"fit",1);
    if(!CGSizeEqualToSize(self.videoView.bounds.size,base.size))self.videoView.bounds=(CGRect){CGPointZero,base.size};
    self.videoView.center=CGPointMake(viewport.width/2,viewport.height/2);
    self.nativePlayer.view.frame=self.videoView.bounds;
    CGRect picture=MSVideoPictureRect(viewport,natural,self.displayMode?:@"fit",self.zoomFactor);
    self.videoView.transform=CGAffineTransformMakeScale(picture.size.width/base.size.width,picture.size.height/base.size.height);
    self.appliedVideoSize=viewport;self.sourceVideoSize=natural;
    CGRect visible=CGRectIntersection(picture,(CGRect){CGPointZero,viewport});
    if(!CGRectIsNull(visible)&&!CGRectIsEmpty(visible))[self.subtitleController updateVideoRect:[self.videoViewport convertRect:visible toView:self.subtitleOverlay]];
}
- (void)selectDisplayMode:(NSString *)mode {
    if(![@[@"fit",@"fill",@"stretch",@"16:9",@"4:3",@"1:1",@"2.35:1"] containsObject:mode])return;
    self.displayMode=mode;self.zoomFactor=1;[self applyVideoLayout];[self scheduleHide];
}
- (void)setVideoZoom:(CGFloat)zoom { self.zoomFactor=MSVideoBoundedZoom(zoom);[self applyVideoLayout]; }
- (void)pinchedVideo:(UIPinchGestureRecognizer *)gesture {
    if(!self.readyPlaybackStarted)return;
    if(gesture.state==UIGestureRecognizerStateBegan){self.pinchStartZoom=self.zoomFactor;[self.hideTimer invalidate];self.hideTimer=nil;}
    else if(gesture.state==UIGestureRecognizerStateChanged||gesture.state==UIGestureRecognizerStateEnded){[self setVideoZoom:self.pinchStartZoom*gesture.scale];if(gesture.state==UIGestureRecognizerStateEnded)[self scheduleHide];}
    else if(gesture.state==UIGestureRecognizerStateCancelled||gesture.state==UIGestureRecognizerStateFailed){[self setVideoZoom:self.pinchStartZoom];[self scheduleHide];}
}
- (void)showDisplayOptions {
    if(self.presentedViewController)return;[self.hideTimer invalidate];self.hideTimer=nil;
    __weak typeof(self) weakSelf=self;
    MSVideoOptionsViewController *options=[[MSVideoOptionsViewController alloc] initWithMode:self.displayMode?:@"fit" zoom:self.zoomFactor change:^(NSString *mode,CGFloat zoom){typeof(self) self=weakSelf;if(!self||self.closing)return;self.displayMode=mode;[self setVideoZoom:zoom];}];
    options.popoverPresentationController.sourceView=self.displayButton;options.popoverPresentationController.sourceRect=self.displayButton.bounds;options.popoverPresentationController.delegate=self;
    [self presentViewController:options animated:YES completion:nil];
}
- (void)popoverPresentationControllerDidDismissPopover:(UIPopoverPresentationController *)popover { (void)popover;[self scheduleHide]; }
- (void)scheduleHide {
    [self.hideTimer invalidate];self.hideTimer=nil;
    if(!self.controlsVisible||!self.readyPlaybackStarted||self.player.timeControlStatus!=AVPlayerTimeControlStatusPlaying||self.scrubbing||self.userSeekPending||self.presentedViewController||!self.statusPanel.hidden||[self voiceOverIsRunning])return;
    __weak typeof(self) weakSelf=self;
    self.hideTimer=[NSTimer scheduledTimerWithTimeInterval:4 repeats:NO block:^(NSTimer *timer){
        typeof(self) self=weakSelf;if(!self||self.hideTimer!=timer)return;self.hideTimer=nil;
        if([self voiceOverIsRunning]){[self setControlsVisible:YES];return;}
        if(!self.readyPlaybackStarted||self.player.timeControlStatus!=AVPlayerTimeControlStatusPlaying||self.scrubbing||self.userSeekPending||self.presentedViewController||!self.statusPanel.hidden)return;
        [self setControlsVisible:NO];
    }];
}
- (void)updateStatusAppearance {
    self.statusLabel.numberOfLines=self.statusLabel.text.length<=48?1:0;
    if(!self.statusPanel.hidden&&self.retryButton.hidden&&self.nextButton.hidden&&!self.closing)[self.statusSpinner startAnimating];else[self.statusSpinner stopAnimating];
}
- (NSTimeInterval)currentTime { double time=CMTimeGetSeconds(self.player.currentTime);return isfinite(time)&&time>=0?time:0; }
- (NSTimeInterval)duration { double duration=CMTimeGetSeconds(self.item.duration);return isfinite(duration)&&duration>0?duration:0; }
- (BOOL)canSeek { return self.readyPlaybackStarted&&self.duration>0&&self.item.seekableTimeRanges.count>0; }
- (void)updateTransportControls {
    BOOL ready=self.readyPlaybackStarted&&self.player!=nil;
    BOOL playing=ready&&self.player.timeControlStatus!=AVPlayerTimeControlStatusPaused;
    [self.playButton setImage:MSPlayerIcon(playing?@"pause":@"play") forState:UIControlStateNormal];self.playButton.accessibilityLabel=playing?@"Pause":@"Play";self.playButton.enabled=ready;
    self.seekSlider.enabled=self.backButton.enabled=self.forwardButton.enabled=self.canSeek;
    if(!self.scrubbing) { NSTimeInterval current=self.userSeekPending?self.userSeekTarget:self.currentTime,duration=self.duration;self.seekSlider.value=duration>0?fmin(1,current/duration):0;[self displayTime:current duration:duration]; }
    if(!CGSizeEqualToSize(self.sourceVideoSize,[self naturalVideoSize]))[self applyVideoLayout];
    [self updateStatusAppearance];
    if(self.controlsVisible&&!self.hideTimer)[self scheduleHide];
}
- (void)displayTime:(NSTimeInterval)time duration:(NSTimeInterval)duration { self.timeLabel.text=duration>0?[NSString stringWithFormat:@"%@ / %@",MSTimeDescription(time),MSTimeDescription(duration)]:MSTimeDescription(time);self.seekSlider.accessibilityValue=self.timeLabel.text; }
- (void)togglePlayback {
    if(!self.readyPlaybackStarted||!self.player||self.closing)return;
    if(self.player.timeControlStatus==AVPlayerTimeControlStatusPaused){if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive)[self.player play];}
    else{[self.player pause];[self persistProgress];}
    [self updateTransportControls];[self scheduleHide];
}
- (void)seekBegan:(UISlider *)slider { (void)slider;self.scrubbing=YES;[self.hideTimer invalidate];self.hideTimer=nil; }
- (void)seekChanged:(UISlider *)slider { if(self.canSeek){[self displayTime:slider.value*self.duration duration:self.duration];if(!slider.isTracking&&!self.scrubbing)[self seekEnded:slider];} }
- (void)seekTapped:(UITapGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateEnded||!self.seekSlider.enabled)return;
    CGRect track=[self.seekSlider trackRectForBounds:self.seekSlider.bounds];CGFloat x=[gesture locationInView:self.seekSlider].x;if(track.size.width>0)[self seekToFraction:(x-track.origin.x)/track.size.width];
}
- (void)seekToFraction:(CGFloat)fraction {
    self.scrubbing=NO;if(!isfinite(fraction)||!self.canSeek||self.closing)return;
    fraction=MAX(0,MIN(1,fraction));self.userSeekTarget=fraction*self.duration;self.userSeekPending=YES;
    NSUInteger generation=self.playbackGeneration,seekGeneration=++self.userSeekGeneration;AVPlayerItem *item=self.item;
    __weak typeof(self) weakSelf=self;[self updateTransportControls];
    [self.player seekToTime:CMTimeMakeWithSeconds(self.userSeekTarget,600) toleranceBefore:CMTimeMakeWithSeconds(0.5,600) toleranceAfter:CMTimeMakeWithSeconds(0.5,600) completionHandler:^(BOOL finished){
        dispatch_async(dispatch_get_main_queue(),^{typeof(self) self=weakSelf;if(!self||self.closing||self.playbackGeneration!=generation||self.item!=item||self.userSeekGeneration!=seekGeneration)return;
            self.userSeekPending=NO;self.hasAdvanceBaseline=YES;self.advanceBaseline=self.currentTime;self.lastProgressMediaTime=self.currentTime;
            if(finished)[self persistProgress];[self updateTransportControls];[self scheduleHide];
        });
    }];
}
- (void)seekEnded:(UISlider *)slider { [self seekToFraction:slider.value]; }
- (void)seekCancelled:(UISlider *)slider { (void)slider;self.scrubbing=NO;[self updateTransportControls];[self scheduleHide]; }
- (void)skipBackward { if(self.duration>0)[self seekToFraction:((self.userSeekPending?self.userSeekTarget:self.currentTime)-15)/self.duration]; }
- (void)skipForward { if(self.duration>0)[self seekToFraction:((self.userSeekPending?self.userSeekTarget:self.currentTime)+15)/self.duration]; }
- (void)showAudio { [self showAudioTracks]; }
- (void)beginPlayback {
    if (self.closing || self.mediaServicesUnavailable || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    self.playbackGeneration += 1;
    self.initialSeekStarted = NO;
    self.pendingAutoplay = YES;
    self.scrubbing=NO;self.userSeekPending=NO;self.userSeekGeneration++;self.lastUIPersistedAt=NSProcessInfo.processInfo.systemUptime;
    [self setControlsVisible:YES];
    self.readyPlaybackStarted = NO;
    self.hasAdvanceBaseline = NO;
    self.advanceRecorded = NO;
    self.advanceBaseline = 0;
    self.bufferingRetryOffered = NO;
    self.hasPlaybackProgress = NO; self.showingBufferingStatus = NO;
    self.lastPlaybackProgressAt = 0; self.lastProgressMediaTime = NAN; self.bufferingBeganAt = 0;
    self.lastTimeControlStatus = -1;
    self.stallNotificationCount = 0;
    self.nativePlayer.showsPlaybackControls = NO;
    self.statusPanel.hidden = NO; self.nextButton.hidden = YES;
    self.statusLabel.text = @"Loading video…"; self.retryButton.hidden = YES; self.retryButton.enabled = YES;
    NSError *audioError = nil;
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    NSUInteger activationGeneration = self.playbackGeneration;
    BOOL configured = [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&audioError];
    if (self.closing || self.mediaServicesUnavailable || self.playbackGeneration != activationGeneration) return;
    BOOL activated = configured && [audio setActive:YES error:&audioError];
    NSObject *activationToken = activated ? MSClaimAudioSession() : nil;
    if (self.closing || self.mediaServicesUnavailable || self.playbackGeneration != activationGeneration) {
        // A reentrant loss/reset/interruption may have invalidated this start.
        // Never replace its recovery UI or allocate a stale player afterward.
        if (self.mediaServicesUnavailable) MSAbandonAudioSession(activationToken);
        else MSReleaseAudioSession(activationToken);
        return;
    }
    if (!activated) {
        BOOL mediaFailure = [audioError.domain isEqualToString:NSOSStatusErrorDomain] && audioError.code == AVAudioSessionErrorCodeMediaServicesFailed;
        [self failAtStage:@"audio-failed" message:mediaFailure ? @"The iPad’s media service is unavailable. When it recovers, tap Resume playback." : @"Audio could not start. Close any other player and retry." error:audioError];
        if (mediaFailure) { self.resume = YES; [self.retryButton setTitle:@"Resume playback" forState:UIControlStateNormal]; self.retryButton.enabled = !self.mediaServicesUnavailable; }
        return;
    }
    self.ownsAudioSession = YES;
    self.audioSessionToken = activationToken;
    // A URL item with an early play request was verified on this iOS 12 device.
    // This network path is still reached only after explicit Play.
    self.item = [AVPlayerItem playerItemWithURL:self.media.streamURL];
    NSString *quality = MSPlaybackPreferences.sharedPreferences.playbackQuality;
    if ([quality isEqual:@"720p"]) { self.item.preferredMaximumResolution = CGSizeMake(1280, 720); self.item.preferredPeakBitRate = 2200000; }
    else if ([quality isEqual:@"1080p"]) { self.item.preferredMaximumResolution = CGSizeMake(1920, 1080); self.item.preferredPeakBitRate = 5000000; }
    // These are adaptive-stream preferences; fixed files are never transcoded here.
    self.player = [AVPlayer playerWithPlayerItem:self.item];
    // Priming must not play audio from the beginning before a saved-position seek.
    self.player.muted = YES;
    self.player.allowsExternalPlayback = NO;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    self.nativePlayer.player = self.player;
    self.subtitleButton.enabled = NO;
    self.subtitleController = [[MSSubtitleController alloc] initWithPlayer:self.player overlayView:self.subtitleOverlay type:self.media.mediaType ?: @"movie" videoID:[self.media.identifier isEqualToString:@"demo:big-buck-bunny"] ? @"tt1254207" : self.media.identifier extras:self.media.subtitleExtras ?: @{}];
    [self.subtitleController setStreamSourceFingerprint:self.media.sourceFingerprint];
    [self.subtitleController setStreamSubtitles:self.media.streamSubtitles ?: @[]];
    [self applyVideoLayout];
    [self.item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:MSItemStatusContext];
    self.observingItem = YES;
    [self.item addObserver:self forKeyPath:@"duration" options:NSKeyValueObservingOptionNew context:MSItemDurationContext];
    self.observingDuration = YES;
    [self.player addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:MSPlayerStatusContext];
    self.observingPlayer = YES;
    [self.player addObserver:self forKeyPath:@"timeControlStatus" options:NSKeyValueObservingOptionNew context:MSPlayerTimeControlContext];
    self.observingTimeControl = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(playbackEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:self.item];
    [center addObserver:self selector:@selector(playbackFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.item];
    [center addObserver:self selector:@selector(playbackStalled:) name:AVPlayerItemPlaybackStalledNotification object:self.item];
    __weak typeof(self) weakSelf = self;
    NSUInteger generation = self.playbackGeneration;
    __weak AVPlayerItem *expectedItem = self.item;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        (void)time;
        typeof(self) self = weakSelf;
        if (!self || self.closing || self.playbackGeneration != generation || self.item != expectedItem || !self.readyPlaybackStarted) return;
        // Reconcile the UI with the real clock even if iOS retains Waiting.
        [self handleTimeControl:self.player];
        NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        if(now-self.lastUIPersistedAt>=5){[self persistProgress];self.lastUIPersistedAt=now;}
        [self recordPlaybackAdvanceIfNeeded];[self updateTransportControls];
    }];
    [self startStartupDeadline];
    [self recordStage:@"preparing"];
    // Status may already have transitioned while the observer was being installed.
    [self handlePlayerStatus:self.player];
    [self handleItemStatus:self.item];
    if (self.player && self.pendingAutoplay && !self.initialSeekStarted && !self.closing &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        // Waiting for ready before requesting playback stalled on iOS 12. Start
        // muted loading now; readiness and the optional seek still gate audio.
        [self recordStage:@"priming-playback"];
        [self.player play];
    }
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    __weak typeof(self) weakSelf = self;
    if (context == MSItemStatusContext || context == MSItemDurationContext) {
        AVPlayerItem *observedItem = object;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handleItemStatus:observedItem]; });
    } else if (context == MSPlayerStatusContext) {
        AVPlayer *observedPlayer = object;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handlePlayerStatus:observedPlayer]; });
    } else if (context == MSPlayerTimeControlContext) {
        AVPlayer *observedPlayer = object;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handleTimeControl:observedPlayer]; });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}
- (void)handleItemStatus:(AVPlayerItem *)item {
    if (!item || item != self.item || self.closing) return;
    if (item.status == AVPlayerItemStatusFailed) { [self showPlaybackFailure]; return; }
    if (item.status != AVPlayerItemStatusReadyToPlay || self.initialSeekStarted) return;
    NSTimeInterval duration = CMTimeGetSeconds(item.duration);
    if (!isfinite(duration) || duration <= 0) duration = self.media.duration;
    double savedPosition = [[MSLibraryStore.sharedStore recordForIdentifier:self.media.identifier][@"position"] doubleValue];
    if (self.resume && savedPosition >= 5 && (!isfinite(duration) || duration <= 0)) {
        // ReadyToPlay can precede a finite duration. Keep priming muted and
        // progress writes disabled until duration KVO can validate the seek.
        // The existing startup deadline handles a permanently indefinite item.
        self.statusLabel.text = @"Waiting to restore your place…";
        [self recordStage:@"waiting-for-duration"];
        return;
    }
    self.initialSeekStarted = YES;
    [self recordStage:@"item-ready"];
    NSTimeInterval start = self.resume ? [MSLibraryStore.sharedStore resumeFor:self.media.identifier duration:duration] : 0;
    if (!self.resume) [MSLibraryStore.sharedStore clearPositionFor:self.media.identifier];
    NSUInteger generation = self.playbackGeneration;
    if (start <= 0) {
        [self startReadyItem:item generation:generation];
        return;
    }
    [self.player pause];
    self.statusLabel.text = @"Restoring your place…";
    [self recordStage:@"initial-seek"];
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:CMTimeMakeWithSeconds(start, 600) toleranceBefore:CMTimeMakeWithSeconds(0.5, 600) toleranceAfter:CMTimeMakeWithSeconds(0.5, 600) completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.closing || self.item != item || self.playbackGeneration != generation) return;
            if (!finished) {
                [self failAtStage:@"initial-seek-failed" message:@"The saved position could not be loaded. Retry playback or return with Done." error:nil];
                return;
            }
            [self startReadyItem:item generation:generation];
        });
    }];
}
- (void)startReadyItem:(AVPlayerItem *)item generation:(NSUInteger)generation {
    if (self.closing || self.item != item || self.playbackGeneration != generation || !self.pendingAutoplay || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.pendingAutoplay = NO;
    self.readyPlaybackStarted = YES;
    double current = CMTimeGetSeconds(self.player.currentTime);
    self.hasAdvanceBaseline = isfinite(current) && current >= 0;
    if (self.hasAdvanceBaseline) self.advanceBaseline = current;
    self.lastProgressMediaTime = current;
    self.player.muted = NO;
    self.nativePlayer.showsPlaybackControls = NO; self.subtitleButton.enabled = YES; [self applyVideoLayout]; [self updateTransportControls];
    MSLibraryStore *store = MSLibraryStore.sharedStore;
    [store registerMetadata:self.media.libraryMetadata ?: @{} forVideoIdentifier:self.media.identifier];
    [self loadAudioTracksForItem:item generation:generation];
    [self.subtitleController restoreSelectionForContentIdentifier:self.media.identifier];
    [self recordStage:@"play-requested"];
    [self.player play];
    [self handleTimeControl:self.player];
}
- (void)handlePlayerStatus:(AVPlayer *)player {
    if (!player || player != self.player || self.closing) return;
    if (player.status == AVPlayerStatusFailed) {
        [self failAtStage:@"player-failed" message:@"The player could not continue. Retry playback or return with Done." error:player.error];
    } else if (self.startupPending) {
        [self recordStage:player.status == AVPlayerStatusReadyToPlay ? @"player-ready" : @"player-preparing"];
    }
}
- (void)samplePlaybackProgress {
    if (!self.player || !self.readyPlaybackStarted || self.closing) return;
    double current = CMTimeGetSeconds(self.player.currentTime);
    if (!isfinite(current) || current < 0) return;
    if (!isfinite(self.lastProgressMediaTime)) { self.lastProgressMediaTime = current; return; }
    if (current > self.lastProgressMediaTime + 0.1) {
        self.hasPlaybackProgress = YES;
        self.lastPlaybackProgressAt = NSProcessInfo.processInfo.systemUptime;
        self.lastProgressMediaTime = current;
    } else if (current < self.lastProgressMediaTime - 0.1) {
        // A backward seek establishes a new baseline, not a permanent stall.
        self.lastProgressMediaTime = current;
    }
}
- (void)hideBufferingStatus {
    if (self.showingBufferingStatus || self.bufferingRetryOffered) {
        self.showingBufferingStatus = NO; self.bufferingRetryOffered = NO;
        self.statusPanel.hidden = YES; self.retryButton.hidden = YES;
    }
}
- (void)handleTimeControl:(AVPlayer *)player {
    if (!player || player != self.player || self.closing) return;
    // Early muted playback cannot complete startup before readiness/seek.
    if (!self.readyPlaybackStarted) return;
    [self updateTransportControls];
    [self samplePlaybackProgress];
    BOOL recentProgress = self.hasPlaybackProgress && NSProcessInfo.processInfo.systemUptime - self.lastPlaybackProgressAt < 8;
    AVPlayerTimeControlStatus status = player.timeControlStatus;
    if ((status == AVPlayerTimeControlStatusPlaying || (recentProgress && self.nativePlayer.readyForDisplay)) && self.startupPending) {
        self.pendingAutoplay = NO;
        [self invalidateStartupDeadline];
        self.statusPanel.hidden = YES;
    }
    BOOL changed = self.lastTimeControlStatus != status;
    self.lastTimeControlStatus = status;
    if (status == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
        if (!self.bufferingBeganAt) self.bufferingBeganAt = NSProcessInfo.processInfo.systemUptime;
        if (!self.startupPending) [self startBufferingDeadlineIfNeeded];
        if (recentProgress && !self.startupPending) { [self hideBufferingStatus]; return; }
        if (changed) {
            self.statusPanel.hidden = NO;
            self.showingBufferingStatus = !self.startupPending;
            self.statusLabel.text = self.startupPending ? @"Loading video…" : @"Buffering…";
            [self recordStage:self.startupPending ? @"waiting-for-playback" : @"buffering"];
        }
        return;
    }
    [self cancelBufferingDeadline];
    self.bufferingBeganAt = 0;
    [self hideBufferingStatus];
    if (self.bufferingRetryOffered) {
        self.bufferingRetryOffered = NO;
        self.retryButton.hidden = YES;
    }
    if (changed) {
        self.statusPanel.hidden = YES;
        self.statusLabel.text = nil;
        [self recordStage:status == AVPlayerTimeControlStatusPlaying ? @"playing" : @"paused"];
    }
}
- (void)startBufferingDeadlineIfNeeded {
    if (self.bufferingTimer || self.bufferingRetryOffered || self.startupPending || !self.readyPlaybackStarted ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSUInteger generation = self.playbackGeneration;
    __weak typeof(self) weakSelf = self;
    __weak AVPlayerItem *expectedItem = self.item;
    NSTimeInterval anchor = MAX(self.bufferingBeganAt, self.lastPlaybackProgressAt);
    NSTimeInterval wait = anchor > 0 ? MAX(1, 30 - (NSProcessInfo.processInfo.systemUptime - anchor)) : 30;
    self.bufferingTimer = [NSTimer timerWithTimeInterval:wait repeats:NO block:^(NSTimer *timer) {
        typeof(self) self = weakSelf;
        if (!self || self.bufferingTimer != timer) return;
        self.bufferingTimer = nil;
        if (self.closing || self.playbackGeneration != generation || self.item != expectedItem || !self.readyPlaybackStarted ||
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            self.player.timeControlStatus != AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) return;
        [self samplePlaybackProgress];
        NSTimeInterval sinceProgress = NSProcessInfo.processInfo.systemUptime - MAX(self.bufferingBeganAt, self.lastPlaybackProgressAt);
        if (sinceProgress < 30) {
            if (self.hasPlaybackProgress && NSProcessInfo.processInfo.systemUptime-self.lastPlaybackProgressAt < 8) [self hideBufferingStatus];
            [self startBufferingDeadlineIfNeeded];
            return;
        }
        // Keep AVPlayer's own recovery running; only the user can request a restart.
        self.bufferingRetryOffered = YES;
        self.showingBufferingStatus = YES; self.statusPanel.hidden = NO;
        self.statusLabel.text = @"Playback has stalled.";
        [self.retryButton setTitle:@"Retry playback" forState:UIControlStateNormal];
        self.retryButton.hidden = NO;
        [self recordStage:@"buffering-retry-offered"];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.bufferingTimer forMode:NSRunLoopCommonModes];
}
- (void)cancelBufferingDeadline {
    [self.bufferingTimer invalidate];
    self.bufferingTimer = nil;
}
- (void)startStartupDeadline {
    [self invalidateStartupDeadline];
    self.startupPending = YES;
    NSUInteger generation = self.playbackGeneration;
    __weak typeof(self) weakSelf = self;
    __weak AVPlayerItem *expectedItem = self.item;
    self.startupTimer = [NSTimer timerWithTimeInterval:30 repeats:NO block:^(NSTimer *timer) {
        typeof(self) self = weakSelf;
        if (!self || timer != self.startupTimer || !self.startupPending || self.closing || self.playbackGeneration != generation || self.item != expectedItem) return;
        // Playback may have started before its queued KVO callback runs.
        if (self.readyPlaybackStarted) {
            [self handleTimeControl:self.player];
            if (!self.startupPending) return;
        }
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            [self invalidateStartupDeadline];
            return;
        }
        [self failAtStage:@"startup-timeout" message:@"Video did not start within 30 seconds. Retry playback or return with Done." error:nil];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.startupTimer forMode:NSRunLoopCommonModes];
}
- (void)invalidateStartupDeadline {
    [self.startupTimer invalidate];
    self.startupTimer = nil;
    self.startupPending = NO;
}
- (NSDictionary *)diagnosticStateForStage:(NSString *)stage error:(NSError *)error {
    NSMutableDictionary *state = [@{@"schemaVersion":@1, @"stage":stage,
        @"recordedAt":@(NSDate.date.timeIntervalSince1970), @"generation":@(self.playbackGeneration),
        @"itemStatus":@(self.item ? self.item.status : -1),
        @"playerStatus":@(self.player ? self.player.status : -1),
        @"timeControlStatus":@(self.player ? self.player.timeControlStatus : -1),
        @"startupPending":@(self.startupPending), @"pendingAutoplay":@(self.pendingAutoplay),
        @"readyPlaybackStarted":@(self.readyPlaybackStarted), @"playbackAdvanceRecorded":@(self.advanceRecorded),
        @"mediaServicesUnavailable":@(self.mediaServicesUnavailable),
        @"readyForDisplay":@(self.nativePlayer.readyForDisplay), @"bufferingRetryOffered":@(self.bufferingRetryOffered),
        @"stallNotificationCount":@(self.stallNotificationCount)} mutableCopy];
    if (self.player) {
        state[@"muted"] = @(self.player.muted);
        state[@"rate"] = @(self.player.rate);
        state[@"waitingReason"] = MSSafeWaitingReason(self.player.reasonForWaitingToPlay);
    }
    if (self.item) {
        state[@"bufferEmpty"] = @(self.item.playbackBufferEmpty);
        state[@"bufferFull"] = @(self.item.playbackBufferFull);
        state[@"likelyToKeepUp"] = @(self.item.playbackLikelyToKeepUp);
        AVPlayerItemAccessLog *accessLog = self.item.accessLog;
        state[@"accessEventCount"] = @(accessLog.events.count);
        AVPlayerItemAccessLogEvent *access = accessLog.events.lastObject;
        if (access) {
            NSMutableDictionary *metrics = [@{@"stalls":@(access.numberOfStalls),
                @"droppedVideoFrames":@(access.numberOfDroppedVideoFrames),
                @"bytesTransferred":@(access.numberOfBytesTransferred),
                @"mediaRequests":@(access.numberOfMediaRequests)} mutableCopy];
            if (isfinite(access.observedBitrate)) metrics[@"observedBitrate"] = @(access.observedBitrate);
            if (isfinite(access.indicatedBitrate)) metrics[@"indicatedBitrate"] = @(access.indicatedBitrate);
            if (isfinite(access.segmentsDownloadedDuration)) metrics[@"segmentsDownloadedDuration"] = @(access.segmentsDownloadedDuration);
            state[@"lastAccess"] = metrics;
        }
    }
    double currentTime = self.player ? CMTimeGetSeconds(self.player.currentTime) : NAN;
    if (isfinite(currentTime)) {
        state[@"currentTimeSeconds"] = @(currentTime);
        if (self.hasAdvanceBaseline) {
            state[@"advanceBaselineSeconds"] = @(self.advanceBaseline);
            state[@"playbackAdvanceSeconds"] = @(currentTime - self.advanceBaseline);
        }
    }
    NSMutableArray *errors = [NSMutableArray array];
    NSError *current = error ?: self.item.error ?: self.player.error;
    for (NSUInteger depth = 0; current && depth < 3; depth++) {
        [errors addObject:@{@"domain":MSSafeErrorDomain(current.domain), @"code":@(current.code)}];
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:NSError.class] ? underlying : nil;
    }
    state[@"errors"] = errors;
    AVPlayerItemErrorLogEvent *event = self.item.errorLog.events.lastObject;
    if (event) state[@"lastMediaError"] = @{@"domain":MSSafeErrorDomain(event.errorDomain), @"code":@(event.errorStatusCode)};
    return state;
}
- (void)writeDiagnosticState:(NSDictionary *)state {
    // One bounded snapshot, only during foreground interaction; never append logs.
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (!data || data.length > 4096) return;
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    if (!cache) return;
    [NSFileManager.defaultManager createDirectoryAtURL:cache withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToURL:[cache URLByAppendingPathComponent:@"MiniStreamPlaybackState.json"] options:NSDataWritingAtomic error:nil];
}
- (void)recordStage:(NSString *)stage {
    [self writeDiagnosticState:[self diagnosticStateForStage:stage error:nil]];
}
- (void)recordPlaybackAdvanceIfNeeded {
    if (self.advanceRecorded || !self.readyPlaybackStarted || self.pendingAutoplay || self.userSeekPending || !self.player ||
        self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    double current = CMTimeGetSeconds(self.player.currentTime);
    if (!isfinite(current) || current < 0) return;
    if (!self.hasAdvanceBaseline) {
        self.hasAdvanceBaseline = YES;
        self.advanceBaseline = current;
        return;
    }
    if (current - self.advanceBaseline > 2.0) {
        self.advanceRecorded = YES;
        // An item becoming ready is not evidence that its source works.
        // Keep the last working source if this attempt stalls before advancing.
        [MSLibraryStore.sharedStore saveSourceFingerprint:self.media.sourceFingerprint forIdentifier:self.media.identifier];
        [self recordStage:@"playback-advanced"];
    }
}
- (void)persistProgress {
    // Never overwrite a saved resume position with the muted priming position.
    if (!self.readyPlaybackStarted || self.userSeekPending || !self.player || !self.item || self.item.status != AVPlayerItemStatusReadyToPlay) return;
    double duration = CMTimeGetSeconds(self.item.duration);
    if (!isfinite(duration) || duration <= 0) duration = self.media.duration;
    [MSLibraryStore.sharedStore savePosition:CMTimeGetSeconds(self.player.currentTime) duration:duration for:self.media.identifier];
}
- (void)pauseForBackground:(NSNotification *)notification {
    self.pendingAutoplay = NO;
    [self.hideTimer invalidate];self.hideTimer=nil;
    [self cancelBufferingDeadline];
    if (!self.player) return;
    if (self.startupPending) {
        [self tearDownSaving:YES]; self.resume = YES;
        self.statusPanel.hidden = NO; self.statusLabel.text = @"Playback paused before it started. Tap Resume playback to continue.";
        [self.retryButton setTitle:@"Resume playback" forState:UIControlStateNormal]; self.retryButton.hidden = NO;
        [self recordStage:@"startup-paused"];
        return;
    }
    [self.player pause]; [self persistProgress];
    self.statusPanel.hidden = YES;
}
- (void)enteredBackground:(NSNotification *)notification {
    if (!self.player) return;
    [self tearDownSaving:YES];
    self.resume = YES;
    self.statusPanel.hidden = NO; self.statusLabel.text = @"Paused while StremIOS was in the background.";
    [self.retryButton setTitle:@"Resume playback" forState:UIControlStateNormal];
    self.retryButton.hidden = NO;
}
- (void)audioInterrupted:(NSNotification *)notification {
    if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self pauseForBackground:notification]; });
    }
}
- (void)audioRouteChanged:(NSNotification *)notification {
    if ([notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self pauseForBackground:notification]; });
    }
}
- (void)mediaServicesLost:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf mediaServicesLost:notification]; });
        return;
    }
    (void)notification;
    if (self.closing) return;
    self.mediaServicesUnavailable = YES;
    // The session is no longer ours to deactivate. Discard orphaned players and
    // leave the last valid saved position intact until the user resumes.
    MSAbandonAudioSession(self.audioSessionToken); self.audioSessionToken = nil;
    self.ownsAudioSession = NO; [self tearDownSaving:YES]; self.resume = YES; self.prepared = YES;
    self.statusPanel.hidden = NO; self.nextButton.hidden = YES;
    self.statusLabel.text = @"The iPad’s media service stopped. Waiting for it to restart…";
    [self.retryButton setTitle:@"Waiting for media service" forState:UIControlStateNormal]; self.retryButton.hidden = NO; self.retryButton.enabled = NO;
    [self recordStage:@"media-services-lost"];
}
- (void)mediaServicesReset:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf mediaServicesReset:notification]; });
        return;
    }
    (void)notification;
    if (self.closing) return;
    self.mediaServicesUnavailable = NO;
    MSAbandonAudioSession(self.audioSessionToken); self.audioSessionToken = nil;
    self.ownsAudioSession = NO; [self tearDownSaving:YES]; self.resume = YES; self.prepared = YES;
    self.statusPanel.hidden = NO; self.nextButton.hidden = YES;
    self.statusLabel.text = @"The iPad’s media service restarted. Tap Resume playback to continue.";
    [self.retryButton setTitle:@"Resume playback" forState:UIControlStateNormal]; self.retryButton.hidden = NO; self.retryButton.enabled = YES;
    // User action calls beginPlayback, which reconfigures the shared audio
    // session and creates fresh AVPlayer/AVPlayerItem instances. No autoplay.
    [self recordStage:@"media-services-reset"];
}
- (void)playbackEnded:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self.item || self.closing) return;
        [MSLibraryStore.sharedStore clearPositionFor:self.media.identifier];
        [self tearDownSaving:NO];
        self.resume = NO; self.statusPanel.hidden = NO; self.statusLabel.text = [NSString stringWithFormat:@"Finished · %@", self.media.title];
        self.nextButton.hidden = !self.nextEpisodeHandler;
        [self.nextButton setTitle:self.nextEpisodeTitle.length ? [NSString stringWithFormat:@"Next · %@", self.nextEpisodeTitle] : @"Next episode" forState:UIControlStateNormal];
        [self.retryButton setTitle:@"Play again" forState:UIControlStateNormal]; self.retryButton.hidden = NO;
    });
}
- (void)playbackFailed:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ if (notification.object == self.item && !self.closing) [self showPlaybackFailure]; });
}
- (void)playbackStalled:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (notification.object != self.item || self.closing) return;
        self.stallNotificationCount += 1;
        [self handleTimeControl:self.player];
        [self recordStage:@"stall-notification"];
    });
}
- (void)showPlaybackFailure {
    [self failAtStage:@"item-failed" message:@"This video could not play. Retry playback or return with Done." error:nil];
}
- (void)failAtStage:(NSString *)stage message:(NSString *)message error:(NSError *)error {
    NSDictionary *state = [self diagnosticStateForStage:stage error:error];
    [self writeDiagnosticState:state];
    NSData *failureData = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    if (cache && failureData.length && failureData.length <= 4096) [failureData writeToURL:[cache URLByAppendingPathComponent:@"MiniStreamLastPlaybackFailure.json"] options:NSDataWritingAtomic error:nil];
    NSMutableArray *details = [NSMutableArray array];
    for (NSDictionary *entry in state[@"errors"]) [details addObject:[NSString stringWithFormat:@"%@ %@", entry[@"domain"], entry[@"code"]]];
    NSDictionary *mediaError = state[@"lastMediaError"];
    if (mediaError) [details addObject:[NSString stringWithFormat:@"Media status %@", mediaError[@"code"]]];
    [self tearDownSaving:YES];
    self.statusPanel.hidden = NO;
    self.statusLabel.text = details.count ? [NSString stringWithFormat:@"%@\n%@", message, [details componentsJoinedByString:@" · "]] : message;
    [self.retryButton setTitle:@"Retry playback" forState:UIControlStateNormal]; self.retryButton.hidden = NO;
}
- (NSString *)languageForAudioOption:(AVMediaSelectionOption *)option {
    return option.extendedLanguageTag ?: [option.locale objectForKey:NSLocaleLanguageCode] ?: @"";
}
- (BOOL)language:(NSString *)actual matches:(NSString *)desired {
    NSString *a = [[actual lowercaseString] componentsSeparatedByString:@"-"].firstObject;
    NSString *b = [[desired lowercaseString] componentsSeparatedByString:@"-"].firstObject;
    NSDictionary *codes = @{@"en":@"eng", @"hi":@"hin"}; a = codes[a] ?: a; b = codes[b] ?: b;
    return a.length && [a isEqual:b];
}
- (void)loadAudioTracksForItem:(AVPlayerItem *)item generation:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    [item.asset loadValuesAsynchronouslyForKeys:@[@"availableMediaCharacteristicsWithMediaSelectionOptions"] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.closing || self.item != item || self.playbackGeneration != generation) return;
            if ([item.asset statusOfValueForKey:@"availableMediaCharacteristicsWithMediaSelectionOptions" error:nil] != AVKeyValueStatusLoaded) return;
            self.audioGroup = [item.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
            self.audioOptions = [AVMediaSelectionGroup playableMediaSelectionOptionsFromArray:self.audioGroup.options ?: @[]];
            self.audioButton.enabled = self.audioOptions.count > 0;
            NSDictionary *saved = [MSLibraryStore.sharedStore playbackSelectionsForIdentifier:self.media.identifier][@"audio"];
            NSString *language = saved[@"language"] ?: MSPlaybackPreferences.sharedPreferences.preferredAudioLanguage;
            AVMediaSelectionOption *match = nil;
            for (AVMediaSelectionOption *option in self.audioOptions) {
                BOOL sameLanguage = [self language:[self languageForAudioOption:option] matches:language];
                if ([option.displayName isEqual:saved[@"displayName"]] && (sameLanguage || ![language length])) { match = option; break; }
                if (!match && sameLanguage) match = option;
            }
            if (match) [item selectMediaOption:match inMediaSelectionGroup:self.audioGroup];
        });
    }];
}
- (void)showAudioTracks {
    if (!self.audioOptions.count || !self.item || self.presentedViewController) return;
    [self setControlsVisible:YES];[self.hideTimer invalidate];self.hideTimer=nil;
    AVPlayerItem *item = self.item; NSUInteger generation = self.playbackGeneration;
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Audio track" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    AVMediaSelectionOption *selected = [item.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:self.audioGroup];
    __weak typeof(self) weakSelf = self;
    for (AVMediaSelectionOption *option in self.audioOptions) {
        NSString *name = option.displayName.length ? option.displayName : @"Audio track";
        if (name.length > 100) name = [name substringToIndex:100];
        [picker addAction:[UIAlertAction actionWithTitle:option == selected ? [@"✓ " stringByAppendingString:name] : name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action; typeof(self) self = weakSelf;
            if (!self || self.closing || self.item != item || self.playbackGeneration != generation) return;
            [item selectMediaOption:option inMediaSelectionGroup:self.audioGroup];
            NSMutableDictionary *selections = [[MSLibraryStore.sharedStore playbackSelectionsForIdentifier:self.media.identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
            selections[@"audio"] = @{@"language":[self languageForAudioOption:option], @"displayName":option.displayName ?: @""};
            [MSLibraryStore.sharedStore savePlaybackSelections:selections forIdentifier:self.media.identifier];
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    picker.popoverPresentationController.sourceView = self.audioButton;
    picker.popoverPresentationController.sourceRect = self.audioButton.bounds; picker.popoverPresentationController.delegate=self; self.audioPicker = picker;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)showSubtitles { if(!self.readyPlaybackStarted||self.presentedViewController)return;[self setControlsVisible:YES];[self.hideTimer invalidate];self.hideTimer=nil;[self.subtitleController setStreamSubtitles:self.media.streamSubtitles ?: @[]]; [self.subtitleController presentFromViewController:self]; }
- (void)retryPlayback {
    if (self.closing || self.mediaServicesUnavailable) return;
    [self tearDownSaving:YES]; self.resume = YES; [self beginPlayback];
}
- (void)tearDownSaving:(BOOL)save {
    if (self.isViewLoaded) [self setVideoFullScreen:NO];
    [self.hideTimer invalidate];self.hideTimer=nil;self.scrubbing=NO;self.userSeekGeneration++;
    [self.subtitleController invalidate]; self.subtitleController = nil; self.subtitleButton.enabled = NO;
    [self.audioPicker dismissViewControllerAnimated:NO completion:nil]; self.audioPicker = nil;
    self.audioGroup = nil; self.audioOptions = @[]; self.audioButton.enabled = NO;
    self.playbackGeneration += 1;
    [self invalidateStartupDeadline];
    [self cancelBufferingDeadline];
    self.pendingAutoplay = NO;
    if (save) [self persistProgress];
    self.userSeekPending=NO;
    self.readyPlaybackStarted = NO;
    self.playButton.enabled=NO;self.seekSlider.enabled=NO;self.backButton.enabled=NO;self.forwardButton.enabled=NO;[self.statusSpinner stopAnimating];
    self.nativePlayer.showsPlaybackControls = NO;
    [self.player pause];
    if (self.timeObserver && self.player) [self.player removeTimeObserver:self.timeObserver];
    self.timeObserver = nil;
    if (self.observingItem && self.item) [self.item removeObserver:self forKeyPath:@"status" context:MSItemStatusContext];
    if (self.observingDuration && self.item) [self.item removeObserver:self forKeyPath:@"duration" context:MSItemDurationContext];
    self.observingItem = NO;
    self.observingDuration = NO;
    if (self.observingPlayer && self.player) [self.player removeObserver:self forKeyPath:@"status" context:MSPlayerStatusContext];
    if (self.observingTimeControl && self.player) [self.player removeObserver:self forKeyPath:@"timeControlStatus" context:MSPlayerTimeControlContext];
    self.observingPlayer = NO; self.observingTimeControl = NO;
    if (self.item) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.item];
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.item];
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:self.item];
        [self.item cancelPendingSeeks]; [self.item.asset cancelLoading];
    }
    self.nativePlayer.player = nil;
    [self.player replaceCurrentItemWithPlayerItem:nil]; self.player = nil; self.item = nil;
    if (self.ownsAudioSession) {
        MSReleaseAudioSession(self.audioSessionToken); self.audioSessionToken = nil;
        self.ownsAudioSession = NO;
    }
}
- (void)playNextEpisode {
    dispatch_block_t handler = self.nextEpisodeHandler;
    if (!handler || self.nextButton.hidden || self.closing) return;
    self.closing = YES; [self tearDownSaving:NO];
    [self dismissViewControllerAnimated:YES completion:handler];
}
- (void)closePlayer {
    self.closing = YES; [self tearDownSaving:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self tearDownSaving:YES];
}
@end
