/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.facebook.react.devsupport

import com.facebook.react.devsupport.interfaces.DevSupportManager
import com.facebook.react.devsupport.interfaces.PausedInDebuggerOverlayManager

internal class DefaultPausedInDebuggerOverlayManager(
    reactInstanceDevHelper: ReactInstanceDevHelper,
) : PausedInDebuggerOverlayManager {
  // A dedicated banner, so the paused state neither replaces nor is replaced by the loading
  // messages.
  private val banner = DefaultDevLoadingViewImplementation(reactInstanceDevHelper)

  override fun showPausedInDebuggerOverlay(
      message: String,
      listener: DevSupportManager.PausedInDebuggerOverlayCommandListener,
  ) {
    banner.showPausedInDebuggerMessage(message) { listener.onResume() }
  }

  override fun hidePausedInDebuggerOverlay() {
    banner.hidePausedInDebuggerMessage()
  }
}
