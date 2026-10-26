#import <CoreHaptics/CoreHaptics.h>

#import "GamepadRumble.h"
#import "../utils.h"

// Same timing as MeloNX: long continuous events, restarted just before they end
static const NSTimeInterval kHapticEventDuration = 20;
static const NSTimeInterval kRestartGracePeriod = 1;
// Controlify asks SDL for 5 s rumbles and refreshes them; stop if not refreshed
static const NSTimeInterval kRumbleTimeout = 5;

static float clamp01(float value) {
    return value < 0 ? 0 : (value > 1 ? 1 : value);
}

#pragma mark - One actuator group

/// Two continuous players on one haptic engine: low (soft) and high (sharp).
/// Used only on the owning GamepadRumble's serial queue.
@interface GamepadHapticChannel : NSObject
@property(nonatomic) CHHapticEngine *engine;
@property(nonatomic) id<CHHapticPatternPlayer> lowPlayer, highPlayer;
@property(nonatomic) BOOL stopped;
@end

@implementation GamepadHapticChannel

- (instancetype)initWithEngine:(CHHapticEngine *)engine queue:(dispatch_queue_t)queue {
    if (!engine) return nil;
    self = [super init];
    self.engine = engine;
    // The system can reset the engine (e.g. audio server restart); rebuild the
    // players on our queue rather than the engine's callback thread
    __weak GamepadHapticChannel *weakSelf = self;
    engine.resetHandler = ^{
        dispatch_async(queue, ^{
            [weakSelf restart];
        });
    };
    NSError *error;
    if (![engine startAndReturnError:&error] || ![self createPlayers:&error]) {
        NSLog(@"[GamepadRumble] Couldn't start haptics: %@", error.localizedDescription);
        return nil;
    }
    return self;
}

- (id<CHHapticPatternPlayer>)makePlayerWithSharpness:(float)sharpness error:(NSError **)error {
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:sharpness],
    ] relativeTime:0 duration:kHapticEventDuration];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:error];
    if (!pattern) return nil;
    return [self.engine createPlayerWithPattern:pattern error:error];
}

- (BOOL)createPlayers:(NSError **)error {
    self.lowPlayer = [self makePlayerWithSharpness:0 error:error];
    self.highPlayer = [self makePlayerWithSharpness:1 error:error];
    if (!self.lowPlayer || !self.highPlayer) return NO;
    // Start silent; rumble only changes intensity
    return [self sendLow:0 high:0 error:error] &&
        [self.lowPlayer startAtTime:CHHapticTimeImmediate error:error] &&
        [self.highPlayer startAtTime:CHHapticTimeImmediate error:error];
}

- (BOOL)sendLow:(float)low high:(float)high error:(NSError **)error {
    CHHapticDynamicParameter *lowIntensity = [[CHHapticDynamicParameter alloc]
        initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:clamp01(low) relativeTime:0];
    CHHapticDynamicParameter *highIntensity = [[CHHapticDynamicParameter alloc]
        initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:clamp01(high) relativeTime:0];
    return [self.lowPlayer sendParameters:@[lowIntensity] atTime:CHHapticTimeImmediate error:error] &&
        [self.highPlayer sendParameters:@[highIntensity] atTime:CHHapticTimeImmediate error:error];
}

- (void)updateLow:(float)low high:(float)high {
    if (![self sendLow:low high:high error:nil]) {
        // Players died (engine reset, event ran out); rebuild and retry once
        [self restart];
        [self sendLow:low high:high error:nil];
    }
}

- (void)restart {
    if (self.stopped) return;
    [self.lowPlayer stopAtTime:CHHapticTimeImmediate error:nil];
    [self.highPlayer stopAtTime:CHHapticTimeImmediate error:nil];
    NSError *error;
    if (![self.engine startAndReturnError:&error] || ![self createPlayers:&error]) {
        self.lowPlayer = self.highPlayer = nil;
    }
}

- (void)stop {
    self.stopped = YES;
    [self.lowPlayer stopAtTime:CHHapticTimeImmediate error:nil];
    [self.highPlayer stopAtTime:CHHapticTimeImmediate error:nil];
    [self.engine stopWithCompletionHandler:nil];
}

@end

#pragma mark - Controller rumble

@interface GamepadRumble ()
// All state below is only touched on `queue`, except during construction
@property(nonatomic) GamepadHapticChannel *leftChannel, *rightChannel, *singleChannel;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t restartTimer;
@property(nonatomic) dispatch_source_t timeoutTimer;
@property(nonatomic) BOOL invalidated;
@end

@implementation GamepadRumble

+ (instancetype)rumbleForController:(GCController *)controller {
    GCDeviceHaptics *haptics = controller.haptics;
    if (!haptics) return nil;
    GamepadRumble *rumble = [[GamepadRumble alloc] init];
    dispatch_queue_t queue = rumble.queue;
    NSSet<GCHapticsLocality> *localities = haptics.supportedLocalities;

    // Same locality preference as MeloNX: separate handles, then any single actuator group
    if ([localities containsObject:GCHapticsLocalityLeftHandle] && [localities containsObject:GCHapticsLocalityRightHandle]) {
        rumble.leftChannel = [[GamepadHapticChannel alloc] initWithEngine:[haptics createEngineWithLocality:GCHapticsLocalityLeftHandle] queue:queue];
        rumble.rightChannel = [[GamepadHapticChannel alloc] initWithEngine:[haptics createEngineWithLocality:GCHapticsLocalityRightHandle] queue:queue];
        if (!rumble.leftChannel || !rumble.rightChannel) {
            [rumble.leftChannel stop];
            [rumble.rightChannel stop];
            rumble.leftChannel = rumble.rightChannel = nil;
        }
    }
    if (!rumble.leftChannel) {
        for (GCHapticsLocality locality in @[GCHapticsLocalityHandles, GCHapticsLocalityDefault, GCHapticsLocalityAll]) {
            if (![localities containsObject:locality]) continue;
            rumble.singleChannel = [[GamepadHapticChannel alloc] initWithEngine:[haptics createEngineWithLocality:locality] queue:queue];
            if (rumble.singleChannel) break;
        }
    }
    if (!rumble.leftChannel && !rumble.singleChannel) {
        NSLog(@"[GamepadRumble] \"%@\" has no usable haptics", controller.vendorName);
        return nil;
    }
    [rumble startRestartTimer];
    NSLog(@"[GamepadRumble] Rumble ready for \"%@\" (%@)", controller.vendorName,
        rumble.leftChannel ? @"left/right handles" : @"single actuator");
    return rumble;
}

- (instancetype)init {
    self = [super init];
    self.queue = dispatch_queue_create("org.angelauramc.amethyst.rumble", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)startRestartTimer {
    // Continuous events end after kHapticEventDuration; restart players before that
    self.restartTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    uint64_t interval = (uint64_t)((kHapticEventDuration - kRestartGracePeriod) * NSEC_PER_SEC);
    dispatch_source_set_timer(self.restartTimer, dispatch_time(DISPATCH_TIME_NOW, interval), interval, NSEC_PER_SEC / 10);
    __weak GamepadRumble *weakSelf = self;
    dispatch_source_set_event_handler(self.restartTimer, ^{
        GamepadRumble *rumble = weakSelf;
        [rumble.leftChannel restart];
        [rumble.rightChannel restart];
        [rumble.singleChannel restart];
    });
    dispatch_resume(self.restartTimer);
}

- (void)applyStrong:(float)strong weak:(float)weak {
    if (self.leftChannel) {
        // Like the real motors: strong/low-frequency on the left, weak/high-frequency on the right
        [self.leftChannel updateLow:strong high:0];
        [self.rightChannel updateLow:0 high:weak];
    } else {
        [self.singleChannel updateLow:strong high:weak];
    }
}

- (void)setStrong:(float)strong weak:(float)weak {
    dispatch_async(self.queue, ^{
        if (self.invalidated) return;
        [self applyStrong:strong weak:weak];

        if (self.timeoutTimer) {
            dispatch_source_cancel(self.timeoutTimer);
            self.timeoutTimer = nil;
        }
        if (strong <= 0 && weak <= 0) return;
        self.timeoutTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(self.timeoutTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRumbleTimeout * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
        __weak GamepadRumble *weakSelf = self;
        dispatch_source_set_event_handler(self.timeoutTimer, ^{
            [weakSelf applyStrong:0 weak:0];
        });
        dispatch_resume(self.timeoutTimer);
    });
}

- (void)invalidate {
    dispatch_async(self.queue, ^{
        if (self.invalidated) return;
        self.invalidated = YES;
        if (self.restartTimer) dispatch_source_cancel(self.restartTimer);
        if (self.timeoutTimer) dispatch_source_cancel(self.timeoutTimer);
        self.restartTimer = self.timeoutTimer = nil;
        [self.leftChannel stop];
        [self.rightChannel stop];
        [self.singleChannel stop];
    });
}

@end
