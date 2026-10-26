#pragma once

#import <GameController/GameController.h>

/*
 * Controller rumble through CoreHaptics, modeled on MeloNX's RumbleController.
 *
 * Two continuous haptic players per channel (a soft, low-frequency one and a
 * sharp, high-frequency one) run all the time at zero intensity; rumble just
 * changes their intensity. Controllers with separate left/right handle
 * actuators (Xbox, DualShock 4, DualSense) put the strong motor on the left
 * handle and the weak motor on the right, like the real hardware; others use
 * one channel for both. Players are restarted shortly before their 20 s event
 * ends, and rumble stops by itself if not refreshed for a few seconds.
 */
@interface GamepadRumble : NSObject

/// nil if the controller has no usable haptics. Call on the main thread.
+ (instancetype)rumbleForController:(GCController *)controller;

/// strong = low-frequency motor, weak = high-frequency motor, both 0..1.
/// Safe to call from any thread.
- (void)setStrong:(float)strong weak:(float)weak;

/// Stop and release the haptic engines.
- (void)invalidate;

@end
