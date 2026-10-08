/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <React/RCTBridgeModule.h>
#import <React/RCTDevLoadingViewProtocol.h>

@interface RCTDevLoadingView : NSObject <RCTDevLoadingViewProtocol, RCTBridgeModule>

/**
 * Shows the banner in its paused-in-debugger state: a capsule with a leading pause icon and a "Tap to resume" line,
 * over a dimmed app that takes no touches, with a tap on the banner calling `onResume`. The banner stays until
 * `hidePausedInDebuggerMessage`, and a loading banner stacks below it while both are visible. Unlike the loading
 * messages, this state ignores `RCTDevLoadingViewSetEnabled`. Meant for a dedicated instance, kept apart from the
 * module's own.
 */
- (void)showPausedInDebuggerMessage:(NSString *)message onResume:(dispatch_block_t)onResume;
- (void)hidePausedInDebuggerMessage;

@end
