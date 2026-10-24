#import "MSAudioSessionOwnership.h"
#import <AVFoundation/AVFoundation.h>

static NSObject *MSCurrentAudioOwner;

NSObject *MSClaimAudioSession(void) {
    NSCAssert(NSThread.isMainThread, @"Audio-session ownership requires the main thread");
    MSCurrentAudioOwner = [NSObject new];
    return MSCurrentAudioOwner;
}

void MSReleaseAudioSession(NSObject *token) {
    NSCAssert(NSThread.isMainThread, @"Audio-session ownership requires the main thread");
    if (!token || token != MSCurrentAudioOwner) return;
    // Clear before entering AVFoundation, whose notifications may reenter us.
    MSCurrentAudioOwner = nil;
    [AVAudioSession.sharedInstance setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

void MSAbandonAudioSession(NSObject *token) {
    NSCAssert(NSThread.isMainThread, @"Audio-session ownership requires the main thread");
    if (token && token == MSCurrentAudioOwner) MSCurrentAudioOwner = nil;
}
