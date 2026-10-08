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
    banner.showPausedInDebuggerMessage(PAUSED_MESSAGE) { listener.onResume() }
  }

  override fun hidePausedInDebuggerOverlay() {
    banner.hidePausedInDebuggerMessage()
  }

  private companion object {
    // The debugger frontend sends a generic message with each pause; the banner shows React
    // Native's own wording, which also tells someone who is not debugging what happened to the app.
    private const val PAUSED_MESSAGE = "App paused in debugger"
  }
}
