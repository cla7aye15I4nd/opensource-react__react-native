/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RCTPausedInDebuggerOverlayController.h"

#import <React/RCTDevLoadingView.h>

@implementation RCTPausedInDebuggerOverlayController {
  // A dedicated banner, so the paused state neither replaces nor is replaced by the module's loading messages.
  RCTDevLoadingView *_banner;
}

- (void)showWithMessage:(NSString *)message onResume:(void (^)(void))onResume
{
  if (_banner == nil) {
    _banner = [RCTDevLoadingView new];
  }
  [_banner showPausedInDebuggerMessage:message onResume:onResume];
}

- (void)hide
{
  [_banner hidePausedInDebuggerMessage];
}

@end
