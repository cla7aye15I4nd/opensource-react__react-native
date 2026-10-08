/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTPausedInDebuggerOverlayController.h"

#import <React/RCTDevLoadingView.h>

// The debugger frontend sends a generic message with each pause; the banner shows React Native's own wording, which
// also tells someone who is not debugging what happened to the app.
static NSString *const RCTPausedInDebuggerMessage = @"App paused in debugger";

@implementation RCTPausedInDebuggerOverlayController {
  // A dedicated banner, so the paused state neither replaces nor is replaced by the module's loading messages.
  RCTDevLoadingView *_banner;
}

- (void)showWithMessage:(__unused NSString *)message onResume:(void (^)(void))onResume
{
  if (_banner == nil) {
    _banner = [RCTDevLoadingView new];
  }
  [_banner showPausedInDebuggerMessage:RCTPausedInDebuggerMessage onResume:onResume];
}

- (void)hide
{
  [_banner hidePausedInDebuggerMessage];
}

@end
