/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

package com.facebook.react.devsupport

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.SystemClock
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.AbsoluteSizeSpan
import android.text.style.AlignmentSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.util.TypedValue
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.PopupWindow
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.facebook.common.logging.FLog
import com.facebook.react.R
import com.facebook.react.bridge.UiThreadUtil
import com.facebook.react.common.ReactConstants
import com.facebook.react.devsupport.interfaces.DevLoadingViewManager
import java.util.Locale

/**
 * Default implementation of Dev Loading View Manager to display loading messages in a capsule at
 * the top of the screen. All methods are thread safe.
 */
public class DefaultDevLoadingViewImplementation(
    private val reactInstanceDevHelper: ReactInstanceDevHelper,
) : DevLoadingViewManager {
  private var devLoadingView: TextView? = null
  private var devLoadingPopup: PopupWindow? = null
  private var pill: View? = null
  private var hideAnimator: Animator? = null
  private var showTimeMs = 0L
  // The capsule's own top offset, before any banner stacked above it pushes it down.
  private var topOffsetPx = 0
  // Set in the paused-in-debugger state, where a tap on the banner resumes instead of hiding it.
  private var resumeAction: (() -> Unit)? = null

  override fun showMessage(message: String) {
    showMessage(message, color = null, backgroundColor = null, dismissButton = false)
  }

  override fun showMessage(
      message: String,
      color: Double?,
      backgroundColor: Double?,
      dismissButton: Boolean?,
  ) {
    if (!isEnabled) {
      return
    }
    UiThreadUtil.runOnUiThread {
      showInternal(
          message,
          color?.toInt() ?: Color.WHITE,
          backgroundColor?.toInt() ?: Color.rgb(64, 64, 64), // Default grey
          dismissButton ?: false,
          resumeAction = null,
      )
    }
  }

  override fun updateProgress(status: String?, done: Int?, total: Int?, percent: Int?) {
    if (!isEnabled) {
      return
    }
    UiThreadUtil.runOnUiThread {
      val percentage =
          if (percent != null) String.format(Locale.getDefault(), " %d%%", percent)
          else if (done != null && total != null && total > 0)
              String.format(Locale.getDefault(), " %.1f%%", done.toFloat() / total * 100)
          else ""
      devLoadingView?.text = "${status ?: "Loading"}${percentage}…" // `...` character at the end
    }
  }

  public override fun hide() {
    if (isEnabled) {
      UiThreadUtil.runOnUiThread { hideInternal() }
    }
  }

  /**
   * Shows the banner in its paused-in-debugger state: a capsule with a leading pause icon and a
   * "Tap to resume" line, over a dimmed app that takes no touches, with a tap on the banner calling
   * [onResume]. The banner stays until [hidePausedInDebuggerMessage], and a loading banner stacks
   * below it while both are visible. Unlike the loading messages, this state ignores
   * [setDevLoadingEnabled]. Meant for a dedicated instance, kept apart from the dev support
   * manager's own.
   */
  public fun showPausedInDebuggerMessage(message: String, onResume: () -> Unit) {
    UiThreadUtil.runOnUiThread {
      showInternal(message, Color.BLACK, PAUSED_BACKGROUND_COLOR, dismissButton = false, onResume)
    }
  }

  public fun hidePausedInDebuggerMessage() {
    UiThreadUtil.runOnUiThread { hideInternal() }
  }

  private fun showInternal(
      message: String,
      textColor: Int,
      bgColor: Int,
      dismissButton: Boolean,
      resumeAction: (() -> Unit)?,
  ) {
    // A new message replaces one that is still animating out.
    hideAnimator?.cancel()
    showTimeMs = SystemClock.uptimeMillis()
    this.resumeAction = resumeAction

    val existingPopup = devLoadingPopup
    val existingPill = pill
    if (existingPopup?.isShowing == true && existingPill != null) {
      applyContent(existingPill, message, textColor, bgColor, dismissButton)
      return
    }

    val currentActivity = reactInstanceDevHelper.currentActivity
    if (currentActivity == null) {
      FLog.e(
          ReactConstants.TAG,
          "Unable to display loading message because react " + "activity isn't available",
      )
      return
    }

    try {
      val decorView = currentActivity.window.decorView
      val inflater = LayoutInflater.from(currentActivity)
      val pill = inflater.inflate(R.layout.dev_loading_view, null) as ViewGroup
      applyContent(pill, message, textColor, bgColor, dismissButton)

      // Sits 12dp below a top inset such as the status bar, or 16dp from the top edge without one,
      // centered and kept clear of the side insets with a 16dp margin.
      val insets =
          ViewCompat.getRootWindowInsets(decorView)
              ?.getInsets(
                  WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout()
              )
      val topInset = insets?.top ?: 0
      val sideInset = maxOf(insets?.left ?: 0, insets?.right ?: 0) + dpToPx(pill, 16f)
      val textView = pill.findViewById<TextView>(R.id.loading_text)
      val dismissButtonView = pill.findViewById<View>(R.id.dismiss_button)
      val pausedIconView = pill.findViewById<View>(R.id.paused_icon)
      val dismissButtonWidth =
          if (dismissButton) {
            (dismissButtonView.layoutParams as ViewGroup.MarginLayoutParams).let {
              it.width + it.marginStart
            }
          } else {
            0
          }
      val pausedIconWidth =
          if (resumeAction != null) {
            (pausedIconView.layoutParams as ViewGroup.MarginLayoutParams).let {
              it.width + it.marginEnd
            }
          } else {
            0
          }
      textView.maxWidth =
          decorView.width -
              2 * sideInset -
              pill.paddingStart -
              pill.paddingEnd -
              dismissButtonWidth -
              pausedIconWidth

      pill.setOnClickListener { handleTap() }
      dismissButtonView.setOnClickListener { hideInternal() }

      topOffsetPx = if (topInset > 0) topInset + dpToPx(pill, 12f) else dpToPx(pill, 16f)
      val paused = resumeAction != null
      val content: View =
          if (paused) {
            // Dims the app and swallows touches while it is paused, since it cannot respond to
            // them. The capsule sits inside, so it stays interactive.
            FrameLayout(currentActivity).apply {
              setBackgroundColor(DIMMING_COLOR)
              isClickable = true
              addView(
                  pill,
                  FrameLayout.LayoutParams(
                          ViewGroup.LayoutParams.WRAP_CONTENT,
                          ViewGroup.LayoutParams.WRAP_CONTENT,
                          Gravity.TOP or Gravity.CENTER_HORIZONTAL,
                      )
                      .apply { topMargin = topOffsetPx },
              )
            }
          } else {
            pill
          }
      val size =
          if (paused) ViewGroup.LayoutParams.MATCH_PARENT else ViewGroup.LayoutParams.WRAP_CONTENT
      val popup = PopupWindow(content, size, size)
      if (paused) {
        // The dimming covers the whole screen, system bars included, which also keeps the
        // capsule's top offset in screen coordinates like the loading banners'.
        popup.isClippingEnabled = false
      } else {
        // Loading banners sit in a layer above the paused banner's dimming, so they stay readable
        // and tappable while the app is paused.
        popup.windowLayoutType = WindowManager.LayoutParams.TYPE_APPLICATION_SUB_PANEL
      }
      this.pill = pill
      popup.showAtLocation(
          decorView,
          Gravity.TOP or Gravity.CENTER_HORIZONTAL,
          0,
          if (paused) 0 else topOffsetPx + stackOffsetPx(),
      )
      // A new message resizes the window about its center. Without this, the system animates that
      // move, so the capsule grows from its old left edge and then slides back to center.
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        val popupRoot = content.rootView
        (popupRoot.layoutParams as? WindowManager.LayoutParams)?.let {
          it.setCanPlayMoveAnimation(false)
          currentActivity.windowManager.updateViewLayout(popupRoot, it)
        }
      }
      devLoadingView = textView
      devLoadingPopup = popup
      visibleBanners.add(this)
      // The capsule's height is known once it has been laid out.
      pill.post { updateOtherBanners() }
      animateIn(pill)
      if (paused) {
        content.alpha = 0f
        content.animate().alpha(1f).setDuration(ANIMATION_DURATION_MS).start()
      }

      // TODO T164786028: Find out the root cause of the BadTokenException exception here
    } catch (e: WindowManager.BadTokenException) {
      FLog.e(
          ReactConstants.TAG,
          "Unable to display loading message because react activity isn't active, message: $message",
      )
    }
  }

  private fun applyContent(
      pill: View,
      message: String,
      textColor: Int,
      bgColor: Int,
      dismissButton: Boolean,
  ) {
    val paused = resumeAction != null
    pill.background =
        GradientDrawable().apply {
          setColor(bgColor)
          // Larger than any banner height, so the corners always form a capsule.
          cornerRadius = dpToPx(pill, 1000f).toFloat()
        }
    pill.minimumHeight = dpToPx(pill, if (paused) PAUSED_MIN_HEIGHT_DP else MIN_HEIGHT_DP)
    val textView = pill.findViewById<TextView>(R.id.loading_text)
    textView.text = if (paused) pausedText(pill, message, textColor) else message
    textView.setTextColor(textColor)
    // The paused message aligns to its leading icon; loading messages center.
    textView.gravity = if (paused) Gravity.START else Gravity.CENTER
    val verticalPadding = dpToPx(pill, if (paused) 7f else 10f)
    textView.setPadding(0, verticalPadding, 0, verticalPadding)

    val pausedIconView = pill.findViewById<ImageView>(R.id.paused_icon)
    pausedIconView.visibility = if (paused) View.VISIBLE else View.GONE
    pill.contentDescription =
        if (paused) "$message. ${pill.resources.getString(R.string.catalyst_paused_tap_to_resume)}."
        else null

    val dismissButtonView = pill.findViewById<ImageView>(R.id.dismiss_button)
    dismissButtonView.visibility = if (dismissButton) View.VISIBLE else View.GONE
    // The round button sits closer to the capsule's end than the text would, and the paused icon
    // is inset from the leading end by the same amount as from the top and bottom.
    pill.setPaddingRelative(
        dpToPx(pill, if (paused) (PAUSED_MIN_HEIGHT_DP - PAUSED_ICON_SIZE_DP) / 2 else 14f),
        pill.paddingTop,
        dpToPx(pill, if (dismissButton) 9f else if (paused) 19f else 14f),
        pill.paddingBottom,
    )
    dismissButtonView.setColorFilter(textColor)
    dismissButtonView.background =
        GradientDrawable().apply {
          shape = GradientDrawable.OVAL
          setColor(
              Color.argb(51, Color.red(textColor), Color.green(textColor), Color.blue(textColor))
          )
        }
  }

  // The message, then a smaller, dimmer, centered "Tap to resume" line.
  private fun pausedText(pill: View, message: String, textColor: Int): CharSequence {
    val subtitle = pill.resources.getString(R.string.catalyst_paused_tap_to_resume)
    return SpannableStringBuilder(message).apply {
      val start = length + 1
      append("\n").append(subtitle)
      val flags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
      setSpan(AbsoluteSizeSpan(SUBTITLE_TEXT_SIZE_SP, true), start, length, flags)
      setSpan(StyleSpan(android.graphics.Typeface.NORMAL), start, length, flags)
      setSpan(ForegroundColorSpan(withAlpha(textColor, 0.6f)), start, length, flags)
      setSpan(AlignmentSpan.Standard(Layout.Alignment.ALIGN_CENTER), start, length, flags)
    }
  }

  // Hides the banner, or resumes the debugger in the paused state.
  private fun handleTap() {
    val resumeAction = resumeAction
    if (resumeAction != null) {
      resumeAction()
    } else {
      hideInternal()
    }
  }

  private fun animateIn(pill: View) {
    pill.alpha = 0f
    pill.scaleX = HIDDEN_SCALE
    pill.scaleY = HIDDEN_SCALE
    pill.post {
      setHiddenPivot(pill)
      pill
          .animate()
          .alpha(1f)
          .scaleX(1f)
          .scaleY(1f)
          .setDuration(ANIMATION_DURATION_MS)
          .setInterpolator(DecelerateInterpolator())
          .start()
    }
  }

  private fun hideInternal() {
    val popup = devLoadingPopup ?: return
    val pill = pill ?: return
    if (!popup.isShowing || hideAnimator != null) {
      return
    }
    setHiddenPivot(pill)
    val animator =
        AnimatorSet().apply {
          val animators =
              mutableListOf(
                  ObjectAnimator.ofFloat(pill, View.ALPHA, 0f),
                  ObjectAnimator.ofFloat(pill, View.SCALE_X, HIDDEN_SCALE),
                  ObjectAnimator.ofFloat(pill, View.SCALE_Y, HIDDEN_SCALE),
              )
          if (popup.contentView !== pill) {
            animators.add(ObjectAnimator.ofFloat(popup.contentView, View.ALPHA, 0f))
          }
          playTogether(animators as Collection<Animator>)
          // Keeps a message that is shown and hidden in quick succession, such as a fast refresh,
          // on screen long enough to read.
          startDelay = maxOf(0L, MIN_PRESENTED_TIME_MS - (SystemClock.uptimeMillis() - showTimeMs))
          duration = ANIMATION_DURATION_MS
          interpolator = AccelerateInterpolator()
          addListener(
              object : AnimatorListenerAdapter() {
                private var canceled = false

                override fun onAnimationCancel(animation: Animator) {
                  canceled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                  hideAnimator = null
                  // A new message canceled the hide, so the banner stays and returns to full size.
                  if (canceled) {
                    pill
                        .animate()
                        .alpha(1f)
                        .scaleX(1f)
                        .scaleY(1f)
                        .setDuration(ANIMATION_DURATION_MS)
                        .setInterpolator(DecelerateInterpolator())
                        .start()
                    popup.contentView.animate().alpha(1f).setDuration(ANIMATION_DURATION_MS).start()
                    return
                  }
                  if (popup.isShowing) {
                    popup.dismiss()
                  }
                  if (devLoadingPopup === popup) {
                    devLoadingPopup = null
                    devLoadingView = null
                    this@DefaultDevLoadingViewImplementation.pill = null
                  }
                  visibleBanners.remove(this@DefaultDevLoadingViewImplementation)
                  updateOtherBanners()
                }
              }
          )
        }
    hideAnimator = animator
    animator.start()
  }

  // Banners with a lower level stack above those with a higher one: the paused banner stays on
  // top, and a loading banner sits below it.
  private fun stackLevel(): Int = if (resumeAction != null) 0 else 1

  private fun stackOffsetPx(): Int {
    val pill = pill ?: return 0
    return visibleBanners.sumOf {
      val other = it.pill
      if (it !== this && other != null && it.stackLevel() < stackLevel()) {
        other.height + dpToPx(pill, STACK_SPACING_DP)
      } else {
        0
      }
    }
  }

  // Moves the capsule under the banners stacked above it. The paused banner is never pushed down.
  private fun updatePlacement() {
    val popup = devLoadingPopup ?: return
    if (!popup.isShowing || resumeAction != null) {
      return
    }
    popup.update(0, topOffsetPx + stackOffsetPx(), -1, -1)
  }

  private fun updateOtherBanners() {
    for (banner in visibleBanners.toList()) {
      if (banner !== this) {
        banner.updatePlacement()
      }
    }
  }

  public companion object {
    private const val ANIMATION_DURATION_MS = 200L
    private const val MIN_PRESENTED_TIME_MS = 600L
    private const val HIDDEN_SCALE = 0.85f
    // The hidden state scales about a point this fraction of the banner's height above its center.
    private const val HIDDEN_ANCHOR_OFFSET = 0.05f
    private const val MIN_HEIGHT_DP = 40f
    // The paused state's two-line capsule, with tighter vertical padding, and the pause icon at its
    // leading end.
    private const val PAUSED_MIN_HEIGHT_DP = 46f
    private const val PAUSED_ICON_SIZE_DP = 24f
    private const val SUBTITLE_TEXT_SIZE_SP = 10
    private val PAUSED_BACKGROUND_COLOR = Color.rgb(255, 236, 152)
    private val DIMMING_COLOR = Color.argb(51, 0, 0, 0)
    // The gap between banners stacked one below another.
    private const val STACK_SPACING_DP = 12f

    private var isEnabled = true

    // The banners currently shown, so one can stack below another. Touched on the UI thread only.
    private val visibleBanners = mutableListOf<DefaultDevLoadingViewImplementation>()

    public fun setDevLoadingEnabled(enabled: Boolean) {
      isEnabled = enabled
    }

    private fun setHiddenPivot(pill: View) {
      pill.pivotX = pill.width / 2f
      pill.pivotY = pill.height * (0.5f - HIDDEN_ANCHOR_OFFSET)
    }

    private fun withAlpha(color: Int, alpha: Float): Int =
        Color.argb((alpha * 255).toInt(), Color.red(color), Color.green(color), Color.blue(color))

    private fun dpToPx(view: View, dp: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, dp, view.resources.displayMetrics)
            .toInt()
  }
}
