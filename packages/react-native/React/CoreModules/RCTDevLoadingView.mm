/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <React/RCTDevLoadingView.h>
#include <UIKit/UIKit.h>

#import <QuartzCore/QuartzCore.h>

#import <FBReactNativeSpec/FBReactNativeSpec.h>
#import <React/RCTAppearance.h>
#import <React/RCTBridge.h>
#import <React/RCTConstants.h>
#import <React/RCTConvert.h>
#import <React/RCTDefines.h>
#import <React/RCTDevLoadingViewSetEnabled.h>
#import <React/RCTUtils.h>

#import "CoreModulesPlugins.h"

using namespace facebook::react;

@interface RCTDevLoadingView () <NativeDevLoadingViewSpec>
@end

#if RCT_DEV_MENU

static const CGFloat RCTDevLoadingViewTopMargin = 16;
static const CGFloat RCTDevLoadingViewHorizontalMargin = 16;
static const CGFloat RCTDevLoadingViewLabelHorizontalPadding = 14;
static const CGFloat RCTDevLoadingViewLabelVerticalPadding = 10;
static const CGFloat RCTDevLoadingViewMinHeight = 40;
static const CGFloat RCTDevLoadingViewDismissButtonSize = 22;
// The paused state's two-line capsule, with tighter vertical padding, and the pause icon at its leading end.
static const CGFloat RCTDevLoadingViewPausedMinHeight = 46;
static const CGFloat RCTDevLoadingViewPausedLabelVerticalPadding = 7;
static const CGFloat RCTDevLoadingViewPausedIconSize = 28;
static const CGFloat RCTDevLoadingViewPausedLabelTrailingPadding = 16;
static const CGFloat RCTDevLoadingViewDimmingAlpha = 0.2;
static const CGFloat RCTDevLoadingViewFontSize = 12.5;
static const CGFloat RCTDevLoadingViewSubtitleFontSize = 10.5;
static const CGFloat RCTDevLoadingViewLineSpacing = 2;
static const NSTimeInterval RCTDevLoadingViewAnimationDuration = 0.2;
static const CGFloat RCTDevLoadingViewHiddenScale = 0.85;
// The hidden state scales about a point this fraction of the capsule's height above its center.
static const CGFloat RCTDevLoadingViewHiddenAnchorOffset = 0.05;
// The gap between banners stacked one below another.
static const CGFloat RCTDevLoadingViewStackSpacing = 12;

#if defined(__IPHONE_27_1) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_27_1
#define RCT_DEV_LOADING_VIEW_HAS_HINGE 1
#else
#define RCT_DEV_LOADING_VIEW_HAS_HINGE 0
#endif

// The horizontal margin a system alert keeps from each side of its window, unless the safe area inset there is larger.
static const CGFloat RCTDevLoadingViewAlertMinimumMargin = 24;

// The horizontal offset from the window's center to the line the banner centers on, matching where a system alert
// sits: each side inset, capped at the alert's minimum margin, pushes the alert away from it by half its size. The
// iPhone Duo's 84pt rail thus shifts it 12pt; equal insets, as on every other iPhone, leave it centered. No public API
// exposes this; it mirrors UIKit's alert presentation on iOS 27.1.
static CGFloat RCTDevLoadingViewCenterLayoutAnchor(UIEdgeInsets safeAreaInsets)
{
  return (MIN(safeAreaInsets.left, RCTDevLoadingViewAlertMinimumMargin) -
          MIN(safeAreaInsets.right, RCTDevLoadingViewAlertMinimumMargin)) /
      2;
}

// The banners currently shown, held weakly, so one can stack below another.
static NSHashTable<RCTDevLoadingView *> *RCTDevLoadingViewVisibleBanners(void)
{
  static NSHashTable<RCTDevLoadingView *> *banners;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    banners = [NSHashTable weakObjectsHashTable];
  });
  return banners;
}

// Hosts the banner above the app's windows and passes touches outside it through to them.
@interface RCTDevLoadingWindow : UIWindow
// Called after each layout pass, since the banner's placement depends on the window's size and safe area in
// ways Auto Layout can't express.
@property (nonatomic, copy) void (^layoutHandler)(void);
@end

@implementation RCTDevLoadingWindow

- (void)layoutSubviews
{
  [super layoutSubviews];
  if (_layoutHandler != nil) {
    _layoutHandler();
  }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
  UIView *view = [super hitTest:point withEvent:event];
  return view == self.rootViewController.view ? nil : view;
}

@end

@implementation RCTDevLoadingView {
  RCTDevLoadingWindow *_window;
  UILabel *_label;
  UIView *_container;
  UIView *_contentView;
  UIButton *_dismissButton;
  UIImageView *_pausedIcon;
  UIView *_dimmingView;
  NSLayoutConstraint *_labelLeadingConstraint;
  NSLayoutConstraint *_labelToIconConstraint;
  NSLayoutConstraint *_minHeightConstraint;
  NSLayoutConstraint *_labelTopConstraint;
  NSLayoutConstraint *_labelBottomConstraint;
  NSLayoutConstraint *_labelTrailingConstraint;
  NSLayoutConstraint *_labelToButtonConstraint;
  NSLayoutConstraint *_centerConstraint;
  NSLayoutConstraint *_trailingLimitConstraint;
  NSLayoutConstraint *_topSafeAreaConstraint;
  NSLayoutConstraint *_topMarginConstraint;
  NSLayoutConstraint *_topPullConstraint;
  // Set in the paused-in-debugger state, where a tap on the banner resumes instead of hiding it.
  dispatch_block_t _resumeAction;
  NSDate *_showDate;
  BOOL _hiding;
  // Incremented by each show so a hide animation that it interrupts does not tear down the new banner.
  NSUInteger _generation;
  dispatch_block_t _initialMessageBlock;
#if RCT_DEV_LOADING_VIEW_HAS_HINGE
  NSTimer *_divisionPollTimer;
  NSDate *_divisionPollDeadline;
  BOOL _hingeOpen;
#endif
}

RCT_EXPORT_MODULE()

- (instancetype)init
{
  if (self = [super init]) {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hide)
                                                 name:RCTJavaScriptDidLoadNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hide)
                                                 name:RCTJavaScriptDidFailToLoadNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hide)
                                                 name:@"RCTInstanceDidLoadBundle"
                                               object:nil];
  }
  return self;
}

- (void)dealloc
{
  [self clearInitialMessageDelay];
#if RCT_DEV_LOADING_VIEW_HAS_HINGE
  [_divisionPollTimer invalidate];
#endif
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  UIWindow *window = _window;
  _window = nil;
  if (window) {
    RCTExecuteOnMainQueue(^{
      window.hidden = YES;
    });
  }
}

+ (void)setEnabled:(BOOL)enabled
{
  RCTDevLoadingViewSetEnabled(enabled);
}

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (void)clearInitialMessageDelay
{
  if (_initialMessageBlock != nil) {
    dispatch_block_cancel(_initialMessageBlock);
    _initialMessageBlock = nil;
  }
}

- (void)showInitialMessageDelayed:(void (^)())initialMessage
{
  _initialMessageBlock = dispatch_block_create(static_cast<dispatch_block_flags_t>(0), initialMessage);

  // We delay the initial loading message to prevent flashing it
  // when loading progress starts quickly. To do that, we
  // schedule the message to be shown in a block, and cancel
  // the block later when the progress starts coming in.
  // If the progress beats this timer, this message is not shown.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 0.2 * NSEC_PER_SEC), dispatch_get_main_queue(), self->_initialMessageBlock);
}

- (void)showMessage:(NSString *)message
              color:(UIColor *)color
    backgroundColor:(UIColor *)backgroundColor
      dismissButton:(BOOL)dismissButton
{
  if (!RCTDevLoadingViewGetEnabled()) {
    return;
  }
  [self _showMessage:message color:color backgroundColor:backgroundColor dismissButton:dismissButton resumeAction:nil];
}

- (void)showPausedInDebuggerMessage:(NSString *)message onResume:(dispatch_block_t)onResume
{
  [self _showMessage:message
                color:UIColor.blackColor
      backgroundColor:[UIColor colorWithRed:1 green:0.926 blue:0.595 alpha:1]
        dismissButton:NO
         resumeAction:onResume];
}

- (void)hidePausedInDebuggerMessage
{
  [self _hide];
}

// The paused state has its own entry points above, which skip the enabled switch: a paused app must always show
// why it is not responding.
- (void)_showMessage:(NSString *)message
               color:(UIColor *)color
     backgroundColor:(UIColor *)backgroundColor
       dismissButton:(BOOL)dismissButton
        resumeAction:(dispatch_block_t)resumeAction
{
  // Input validation
  if (message == nil || [message isEqualToString:@""]) {
    NSLog(@"Error: message cannot be nil or empty");
    return;
  }
  if (color == nil) {
    NSLog(@"Error: color cannot be nil");
    return;
  }
  if (backgroundColor == nil) {
    NSLog(@"Error: backgroundColor cannot be nil");
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (RCTRunningInTestEnvironment()) {
      return;
    }

    self->_showDate = [NSDate date];
    self->_generation++;
    self->_resumeAction = resumeAction;
    if (self->_hiding) {
      [self _removeBanner];
    }

    if (self->_window == nullptr) {
      UIWindowScene *windowScene = RCTKeyWindow().windowScene;
      self->_window = windowScene != nil ? [[RCTDevLoadingWindow alloc] initWithWindowScene:windowScene]
                                         : [[RCTDevLoadingWindow alloc] init];
      self->_window.frame = self->_window.windowScene.coordinateSpace.bounds;
#if !TARGET_OS_TV
      // The paused window dims and blocks the app beneath it; loading banners sit one level above, so they stay
      // readable and tappable while the app is paused.
      self->_window.windowLevel = UIWindowLevelStatusBar + (resumeAction != nil ? 1 : 2);
#endif
      self->_window.rootViewController = [UIViewController new];
      __weak __typeof(self) weakSelf = self;
      self->_window.layoutHandler = ^{
        [weakSelf _updatePlacementAnimated:NO];
      };
      self->_window.rootViewController.view.backgroundColor = UIColor.clearColor;
#if RCT_DEV_LOADING_VIEW_HAS_HINGE
      [self _observeHinge];
#endif
    }

    BOOL isNewBanner = self->_container == nullptr;
    if (isNewBanner) {
      [self _createBannerWithBackgroundColor:backgroundColor];
    } else {
      [self _applyBackgroundColor:backgroundColor];
    }

    self->_label.textColor = color;
    [self _setLabelText:message];

    if (dismissButton && self->_dismissButton == nullptr) {
      [self _createDismissButton];
    } else if (!dismissButton && self->_dismissButton != nullptr) {
      [self->_dismissButton removeFromSuperview];
      self->_dismissButton = nullptr;
      self->_labelToButtonConstraint = nil;
    }
    if (self->_dismissButton != nullptr) {
      UIButtonConfiguration *buttonConfig = self->_dismissButton.configuration;
      buttonConfig.baseForegroundColor = color;
      buttonConfig.background.backgroundColor = [color colorWithAlphaComponent:0.2];
      self->_dismissButton.configuration = buttonConfig;
    }
    self->_labelTrailingConstraint.active = self->_dismissButton == nullptr;
    self->_labelToButtonConstraint.active = self->_dismissButton != nullptr;

    BOOL paused = resumeAction != nil;
    if (paused && self->_pausedIcon == nullptr) {
      [self _createPausedIcon];
    } else if (!paused && self->_pausedIcon != nullptr) {
      [self->_pausedIcon removeFromSuperview];
      self->_pausedIcon = nullptr;
      self->_labelToIconConstraint = nil;
    }
    self->_labelLeadingConstraint.active = self->_pausedIcon == nullptr;
    self->_labelToIconConstraint.active = self->_pausedIcon != nullptr;
    if (paused && self->_dimmingView == nullptr) {
      [self _createDimmingView];
    } else if (!paused && self->_dimmingView != nullptr) {
      [self->_dimmingView removeFromSuperview];
      self->_dimmingView = nullptr;
    }
    CGFloat verticalPadding =
        paused ? RCTDevLoadingViewPausedLabelVerticalPadding : RCTDevLoadingViewLabelVerticalPadding;
    self->_labelTopConstraint.constant = verticalPadding;
    self->_labelBottomConstraint.constant = -verticalPadding;
    self->_labelTrailingConstraint.constant =
        -(paused ? RCTDevLoadingViewPausedLabelTrailingPadding : RCTDevLoadingViewLabelHorizontalPadding);
    self->_container.isAccessibilityElement = paused;
    self->_container.accessibilityLabel = paused ? [message stringByAppendingString:@". Tap to resume."] : nil;
    CGFloat minHeight = paused ? RCTDevLoadingViewPausedMinHeight : RCTDevLoadingViewMinHeight;
    self->_minHeightConstraint.constant = minHeight;
    if (![self->_container isKindOfClass:UIVisualEffectView.class]) {
      self->_container.layer.cornerRadius = minHeight / 2;
    }

    [RCTDevLoadingViewVisibleBanners() addObject:self];
    self->_window.hidden = NO;
    [self _updatePlacementAnimated:NO];
    [self->_window layoutIfNeeded];
    [self _updateOtherBannersAnimated:YES];
    if (isNewBanner) {
      [self _animateBannerIn];
    }
  });
}

#if RCT_DEV_LOADING_VIEW_HAS_HINGE
- (void)_observeHinge
{
  if (@available(iOS 27.1, *)) {
    __weak __typeof(self) weakSelf = self;
    UIHingeInteraction *interaction = [[UIHingeInteraction alloc]
        initWithUpdateHandler:^(__unused UIHingeInteraction *hingeInteraction, UIHingeInteractionUpdate *update) {
          [weakSelf _hingeDidUpdate:update.hinge];
        }];
    [_window.rootViewController.view addInteraction:interaction];
  }
}

// The division region becomes active once the hinge settles, matching when the system's own UI moves aside,
// but that change has no notification of its own, so each hinge update starts a short poll for it.
- (void)_hingeDidUpdate:(UIHinge *)hinge API_AVAILABLE(ios(27.1))
{
  _hingeOpen = hinge.status == UIHingeStatusPartiallyOpen || hinge.status == UIHingeStatusFullyOpen;
  _divisionPollDeadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
  if (_divisionPollTimer != nil) {
    return;
  }
  __weak __typeof(self) weakSelf = self;
  _divisionPollTimer =
      [NSTimer scheduledTimerWithTimeInterval:0.05
                                      repeats:YES
                                        block:^(NSTimer *timer) {
                                          __typeof(self) strongSelf = weakSelf;
                                          if (strongSelf == nil) {
                                            [timer invalidate];
                                            return;
                                          }
                                          [strongSelf _updatePlacementAnimated:YES];
                                          if (strongSelf->_divisionPollDeadline.timeIntervalSinceNow < 0) {
                                            [timer invalidate];
                                            strongSelf->_divisionPollTimer = nil;
                                          }
                                        }];
}
#endif

// Places the banner where a system alert would center itself, or while a fold divides the screen, centered within
// the leading segment and clear of the fold. On a foldable held open in portrait, the status bar sits in a corner
// while its inset spans the whole top edge, so the banner ignores that inset and sits 16pt from the top. A banner
// that stacks below others sits under them instead of at the top.
- (void)_updatePlacementAnimated:(BOOL)animated
{
  if (_container == nil) {
    return;
  }
  UIView *rootView = _window.rootViewController.view;
  UIEdgeInsets safeAreaInsets = rootView.safeAreaInsets;
  CGFloat centerOffset = RCTDevLoadingViewCenterLayoutAnchor(safeAreaInsets);
  CGFloat trailingMargin = RCTDevLoadingViewHorizontalMargin;
  BOOL respectsTopSafeArea = YES;
  CGFloat stackOffset = 0;
  for (RCTDevLoadingView *banner in RCTDevLoadingViewVisibleBanners()) {
    if (banner != self && banner->_container != nil && [banner _stackLevel] < [self _stackLevel]) {
      stackOffset += CGRectGetHeight(banner->_container.frame) + RCTDevLoadingViewStackSpacing;
    }
  }
#if RCT_DEV_LOADING_VIEW_HAS_HINGE
  if (@available(iOS 27.1, *)) {
    respectsTopSafeArea = !(_hingeOpen && CGRectGetHeight(rootView.bounds) > CGRectGetWidth(rootView.bounds));
    CGFloat minX = safeAreaInsets.left;
    CGFloat maxX = CGRectGetWidth(rootView.bounds) - safeAreaInsets.right;
    for (UIViewReservedRegion *region in
         [rootView reservedRegionsOfKind:[UIViewReservedRegionKind divisionRegionKind]]) {
      CGFloat dividerX = CGRectGetMinX(region.frame);
      if (region.active && CGRectGetHeight(region.frame) >= CGRectGetWidth(region.frame) && dividerX > minX &&
          dividerX < maxX) {
        centerOffset = (minX + dividerX) / 2 - CGRectGetMidX(rootView.bounds);
        trailingMargin += maxX - dividerX;
      }
    }
  }
#endif
  if (centerOffset == _centerConstraint.constant && -trailingMargin == _trailingLimitConstraint.constant &&
      respectsTopSafeArea == _topSafeAreaConstraint.active && stackOffset == _topPullConstraint.constant) {
    return;
  }
  _centerConstraint.constant = centerOffset;
  _trailingLimitConstraint.constant = -trailingMargin;
  _topSafeAreaConstraint.active = respectsTopSafeArea;
  _topSafeAreaConstraint.constant = stackOffset;
  _topMarginConstraint.constant = RCTDevLoadingViewTopMargin + stackOffset;
  _topPullConstraint.constant = stackOffset;
  if (animated) {
    [UIView animateWithDuration:RCTDevLoadingViewAnimationDuration
                     animations:^{
                       [rootView layoutIfNeeded];
                     }];
  }
}

// Banners with a lower level stack above those with a higher one: the paused banner stays on top, and a loading
// banner sits below it.
- (NSUInteger)_stackLevel
{
  return _resumeAction != nil ? 0 : 1;
}

- (void)_updateOtherBannersAnimated:(BOOL)animated
{
  for (RCTDevLoadingView *banner in [RCTDevLoadingViewVisibleBanners() copy]) {
    if (banner != self) {
      [banner _updatePlacementAnimated:animated];
    }
  }
}

- (CGAffineTransform)_hiddenTransform
{
  CGFloat anchorY = -RCTDevLoadingViewHiddenAnchorOffset * _container.bounds.size.height;
  CGAffineTransform transform = CGAffineTransformMakeTranslation(0, anchorY);
  transform = CGAffineTransformScale(transform, RCTDevLoadingViewHiddenScale, RCTDevLoadingViewHiddenScale);
  return CGAffineTransformTranslate(transform, 0, -anchorY);
}

- (void)_animateBannerIn
{
  // A visual effect view renders incorrectly below full alpha, so its effect and content fade instead.
  UIVisualEffectView *effectView =
      [_container isKindOfClass:UIVisualEffectView.class] ? (UIVisualEffectView *)_container : nil;
  UIVisualEffect *effect = effectView.effect;
  effectView.effect = nil;
  if (effectView != nil) {
    _contentView.alpha = 0;
  } else {
    _container.alpha = 0;
  }
  _container.transform = [self _hiddenTransform];
  _dimmingView.alpha = 0;

  [UIView animateWithDuration:RCTDevLoadingViewAnimationDuration
                        delay:0
                      options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     effectView.effect = effect;
                     self->_contentView.alpha = 1;
                     self->_container.alpha = 1;
                     self->_container.transform = CGAffineTransformIdentity;
                     self->_dimmingView.alpha = 1;
                   }
                   completion:nil];
}

- (void)_createBannerWithBackgroundColor:(UIColor *)backgroundColor
{
  UIView *container;
  UIView *contentView;
#if defined(__IPHONE_26_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_26_0
  if (@available(iOS 26.0, *)) {
    UIVisualEffectView *effectView =
        [[UIVisualEffectView alloc] initWithEffect:[self _glassEffectWithTintColor:backgroundColor]];
    effectView.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    container = effectView;
    contentView = effectView.contentView;
  }
#endif
  if (container == nil) {
    container = [UIView new];
    container.backgroundColor = backgroundColor;
    container.layer.cornerRadius = RCTDevLoadingViewMinHeight / 2;
    container.layer.cornerCurve = kCACornerCurveContinuous;
    container.clipsToBounds = YES;
    contentView = container;
  }
  container.translatesAutoresizingMaskIntoConstraints = NO;
  [container addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleTap)]];

  UILabel *label = [UILabel new];
  label.translatesAutoresizingMaskIntoConstraints = NO;
  label.font = [UIFont monospacedDigitSystemFontOfSize:RCTDevLoadingViewFontSize weight:UIFontWeightMedium];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  [contentView addSubview:label];

  UIView *rootView = _window.rootViewController.view;
  [rootView addSubview:container];

  // Centered on the window like a system alert, with required safe area limits that only push the banner
  // inward where the two would overlap, such as beside the camera cutout.
  UILayoutGuide *safeArea = rootView.safeAreaLayoutGuide;
  _centerConstraint = [container.centerXAnchor constraintEqualToAnchor:rootView.centerXAnchor];
  _centerConstraint.priority = UILayoutPriorityDefaultHigh;
  _trailingLimitConstraint =
      [container.trailingAnchor constraintLessThanOrEqualToAnchor:safeArea.trailingAnchor
                                                         constant:-RCTDevLoadingViewHorizontalMargin];
  _labelLeadingConstraint = [label.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor
                                                                constant:RCTDevLoadingViewLabelHorizontalPadding];
  _labelTrailingConstraint = [label.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor
                                                                  constant:-RCTDevLoadingViewLabelHorizontalPadding];
  // Sits flush under a top safe area inset such as the status bar, or 16pt from the top edge without one, each
  // pushed down by the banners stacked above it.
  _topSafeAreaConstraint = [container.topAnchor constraintGreaterThanOrEqualToAnchor:safeArea.topAnchor];
  _topMarginConstraint = [container.topAnchor constraintGreaterThanOrEqualToAnchor:rootView.topAnchor
                                                                          constant:RCTDevLoadingViewTopMargin];
  _topPullConstraint = [container.topAnchor constraintEqualToAnchor:rootView.topAnchor];
  _topPullConstraint.priority = UILayoutPriorityDefaultLow;
  _labelTopConstraint = [label.topAnchor constraintEqualToAnchor:contentView.topAnchor
                                                        constant:RCTDevLoadingViewLabelVerticalPadding];
  _labelBottomConstraint = [label.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor
                                                              constant:-RCTDevLoadingViewLabelVerticalPadding];
  _minHeightConstraint = [container.heightAnchor constraintGreaterThanOrEqualToConstant:RCTDevLoadingViewMinHeight];
  [NSLayoutConstraint activateConstraints:@[
    _centerConstraint,
    _trailingLimitConstraint,
    [container.leadingAnchor constraintGreaterThanOrEqualToAnchor:safeArea.leadingAnchor
                                                         constant:RCTDevLoadingViewHorizontalMargin],
    _topSafeAreaConstraint,
    _topMarginConstraint,
    _topPullConstraint,
    _minHeightConstraint,
    _labelTopConstraint,
    _labelBottomConstraint,
    _labelLeadingConstraint,
  ]];

  _container = container;
  _contentView = contentView;
  _label = label;
}

// In the paused-in-debugger state, the message aligns to the leading icon, and a smaller, dimmer, centered
// "Tap to resume" line follows it.
- (void)_setLabelText:(NSString *)message
{
  NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
  paragraphStyle.alignment = _resumeAction != nil ? NSTextAlignmentNatural : NSTextAlignmentCenter;
  paragraphStyle.lineSpacing = RCTDevLoadingViewLineSpacing;
  NSMutableAttributedString *text =
      [[NSMutableAttributedString alloc] initWithString:message
                                             attributes:@{NSParagraphStyleAttributeName : paragraphStyle}];
  if (_resumeAction != nil) {
    NSMutableParagraphStyle *subtitleStyle = [paragraphStyle mutableCopy];
    subtitleStyle.alignment = NSTextAlignmentCenter;
    [text appendAttributedString:[[NSAttributedString alloc]
                                     initWithString:@"\nTap to resume"
                                         attributes:@{
                                           NSParagraphStyleAttributeName : subtitleStyle,
                                           NSFontAttributeName :
                                               [UIFont systemFontOfSize:RCTDevLoadingViewSubtitleFontSize
                                                                 weight:UIFontWeightRegular],
                                           NSForegroundColorAttributeName :
                                               [_label.textColor colorWithAlphaComponent:0.6],
                                         }]];
  }
  _label.attributedText = text;
}

// Hides the banner, or resumes the debugger in the paused state.
- (void)_handleTap
{
  if (_resumeAction != nil) {
    _resumeAction();
  } else {
    [self hide];
  }
}

- (void)_createDismissButton
{
  UIButtonConfiguration *buttonConfig = [UIButtonConfiguration plainButtonConfiguration];
  buttonConfig.image = [UIImage
       systemImageNamed:@"xmark"
      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightBold]];
  buttonConfig.contentInsets = NSDirectionalEdgeInsetsZero;
  buttonConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;

  __weak __typeof(self) weakSelf = self;
  UIButton *button = [UIButton buttonWithConfiguration:buttonConfig
                                         primaryAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
                                           [weakSelf hide];
                                         }]];
  button.accessibilityLabel = @"Dismiss";
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [_contentView addSubview:button];

  _labelToButtonConstraint = [_label.trailingAnchor constraintEqualToAnchor:button.leadingAnchor constant:-8];
  [NSLayoutConstraint activateConstraints:@[
    [button.trailingAnchor constraintEqualToAnchor:_contentView.trailingAnchor constant:-9],
    [button.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor],
    [button.widthAnchor constraintEqualToConstant:RCTDevLoadingViewDismissButtonSize],
    [button.heightAnchor constraintEqualToConstant:RCTDevLoadingViewDismissButtonSize],
  ]];

  _dismissButton = button;
}

- (void)_createPausedIcon
{
  // Cream pause bars in a deep amber circle.
  UIImageSymbolConfiguration *configuration =
      [[UIImageSymbolConfiguration configurationWithPointSize:RCTDevLoadingViewPausedIconSize]
          configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithPaletteColors:@[
            [UIColor colorWithRed:0.996 green:0.972 blue:0.869 alpha:1],
            [UIColor colorWithRed:0.343 green:0.269 blue:0.105 alpha:1],
          ]]];
  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pause.circle.fill"
                                                                 withConfiguration:configuration]];
  icon.contentMode = UIViewContentModeScaleAspectFit;
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  [_contentView addSubview:icon];

  // Inset from the capsule's leading end by the same amount as from its top and bottom.
  CGFloat inset = (RCTDevLoadingViewPausedMinHeight - RCTDevLoadingViewPausedIconSize) / 2;
  _labelToIconConstraint = [_label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6];
  [NSLayoutConstraint activateConstraints:@[
    [icon.leadingAnchor constraintEqualToAnchor:_contentView.leadingAnchor constant:inset],
    [icon.centerYAnchor constraintEqualToAnchor:_contentView.centerYAnchor],
    [icon.widthAnchor constraintEqualToConstant:RCTDevLoadingViewPausedIconSize],
    [icon.heightAnchor constraintEqualToConstant:RCTDevLoadingViewPausedIconSize],
  ]];

  _pausedIcon = icon;
}

// Dims the app and swallows touches while it is paused, since it cannot respond to them. The dimming view sits
// below the banner, which this window's hit testing leaves interactive.
- (void)_createDimmingView
{
  UIView *dimmingView = [UIView new];
  dimmingView.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:RCTDevLoadingViewDimmingAlpha];
  dimmingView.translatesAutoresizingMaskIntoConstraints = NO;
  UIView *rootView = _window.rootViewController.view;
  [rootView insertSubview:dimmingView belowSubview:_container];
  [NSLayoutConstraint activateConstraints:@[
    [dimmingView.topAnchor constraintEqualToAnchor:rootView.topAnchor],
    [dimmingView.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
    [dimmingView.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
    [dimmingView.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
  ]];
  _dimmingView = dimmingView;
}

- (void)_removeBanner
{
  [_container removeFromSuperview];
  _container = nil;
  _contentView = nil;
  _label = nil;
  _dismissButton = nil;
  _pausedIcon = nil;
  [_dimmingView removeFromSuperview];
  _dimmingView = nil;
  _labelLeadingConstraint = nil;
  _labelToIconConstraint = nil;
  _minHeightConstraint = nil;
  _labelTopConstraint = nil;
  _labelBottomConstraint = nil;
  _labelTrailingConstraint = nil;
  _labelToButtonConstraint = nil;
  _centerConstraint = nil;
  _trailingLimitConstraint = nil;
  _topSafeAreaConstraint = nil;
  _topMarginConstraint = nil;
  _topPullConstraint = nil;
  _hiding = NO;
}

- (void)_applyBackgroundColor:(UIColor *)backgroundColor
{
#if defined(__IPHONE_26_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_26_0
  if (@available(iOS 26.0, *)) {
    if ([_container isKindOfClass:UIVisualEffectView.class]) {
      ((UIVisualEffectView *)_container).effect = [self _glassEffectWithTintColor:backgroundColor];
      return;
    }
  }
#endif
  _container.backgroundColor = backgroundColor;
}

#if defined(__IPHONE_26_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_26_0
- (UIGlassEffect *)_glassEffectWithTintColor:(UIColor *)tintColor API_AVAILABLE(ios(26.0))
{
  UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
  effect.tintColor = tintColor;
  return effect;
}
#endif

- (void)showMessage:(NSString *)message
              withColor:(NSNumber *__nonnull)color
    withBackgroundColor:(NSNumber *__nonnull)backgroundColor
      withDismissButton:(NSNumber *)dismissButton
{
  [self showMessage:message
                color:[RCTConvert UIColor:color]
      backgroundColor:[RCTConvert UIColor:backgroundColor]
        dismissButton:[dismissButton boolValue]];
}
- (void)hide
{
  if (!RCTDevLoadingViewGetEnabled()) {
    return;
  }
  [self _hide];
}

- (void)_hide
{
  // Cancel the initial message block so it doesn't display later and get stuck.
  [self clearInitialMessageDelay];

  dispatch_async(dispatch_get_main_queue(), ^{
    self->_hiding = YES;
    NSUInteger generation = self->_generation;
    const NSTimeInterval MIN_PRESENTED_TIME = 0.6;
    NSTimeInterval presentedTime = [[NSDate date] timeIntervalSinceDate:self->_showDate];
    NSTimeInterval delay = MAX(0, MIN_PRESENTED_TIME - presentedTime);
    [UIView animateWithDuration:RCTDevLoadingViewAnimationDuration
        delay:delay
        options:UIViewAnimationOptionCurveEaseIn
        animations:^{
          if ([self->_container isKindOfClass:UIVisualEffectView.class]) {
            ((UIVisualEffectView *)self->_container).effect = nil;
            self->_contentView.alpha = 0;
          } else {
            self->_container.alpha = 0;
          }
          self->_container.transform = [self _hiddenTransform];
          self->_dimmingView.alpha = 0;
        }
        completion:^(__unused BOOL finished) {
          if (self->_generation != generation) {
            return;
          }
          [self _removeBanner];
          [RCTDevLoadingViewVisibleBanners() removeObject:self];
          [self _updateOtherBannersAnimated:YES];
          self->_window.hidden = YES;
          self->_window = nil;
        }];
  });
}

- (void)showProgressMessage:(NSString *)message
{
  if (_window != nil) {
    // This is an optimization. Since the progress can come in quickly,
    // we want to do the minimum amount of work to update the UI,
    // which is to only update the label text.
    [self _setLabelText:message];
    return;
  }

  UIColor *color = [UIColor whiteColor];
  UIColor *backgroundColor = [UIColor colorWithHue:105 saturation:0 brightness:.25 alpha:1];

  if ([self isDarkModeEnabled]) {
    color = [UIColor colorWithHue:208 saturation:0.03 brightness:.14 alpha:1];
    backgroundColor = [UIColor colorWithHue:0 saturation:0 brightness:0.98 alpha:1];
  }

  [self showMessage:message color:color backgroundColor:backgroundColor dismissButton:false];
}

- (void)showOfflineMessage
{
  UIColor *color = [UIColor whiteColor];
  UIColor *backgroundColor = [UIColor blackColor];

  if ([self isDarkModeEnabled]) {
    color = [UIColor blackColor];
    backgroundColor = [UIColor whiteColor];
  }

  NSString *message = [NSString stringWithFormat:@"Connect to %@ to develop JavaScript.", RCT_PACKAGER_NAME];
  [self showMessage:message color:color backgroundColor:backgroundColor dismissButton:false];
}

- (BOOL)isDarkModeEnabled
{
  // We pass nil here to match the behavior of the native module.
  // If we were to pass a view, then it's possible that this native
  // banner would have a different color than the JavaScript banner
  // (which always passes nil). This would result in an inconsistent UI.
  return [RCTColorSchemePreference(nil) isEqualToString:@"dark"];
}
- (void)showWithURL:(NSURL *)URL
{
  if (URL.fileURL) {
    // If dev mode is not enabled, we don't want to show this kind of notification.
#if !RCT_DEV
    return;
#endif
    [self showOfflineMessage];
  } else {
    [self showInitialMessageDelayed:^{
      NSString *message = [NSString stringWithFormat:@"Loading from %@\u2026", RCT_PACKAGER_NAME];
      [self showProgressMessage:message];
    }];
  }
}

- (void)updateProgress:(RCTLoadingProgress *)progress
{
  if (!progress) {
    return;
  }

  // Cancel the initial message block so it's not flashed before progress.
  [self clearInitialMessageDelay];

  dispatch_async(dispatch_get_main_queue(), ^{
    [self showProgressMessage:[progress description]];
  });
}

- (std::shared_ptr<TurboModule>)getTurboModule:(const ObjCTurboModule::InitParams &)params
{
  return std::make_shared<NativeDevLoadingViewSpecJSI>(params);
}

@end

#else

@implementation RCTDevLoadingView

+ (NSString *)moduleName
{
  return nil;
}
+ (void)setEnabled:(BOOL)enabled
{
}
- (void)showMessage:(NSString *)message
              color:(UIColor *)color
    backgroundColor:(UIColor *)backgroundColor
      dismissButton:(BOOL)dismissButton
{
}
- (void)showMessage:(NSString *)message
              withColor:(NSNumber *)color
    withBackgroundColor:(NSNumber *)backgroundColor
      withDismissButton:(NSNumber *)dismissButton
{
}
- (void)showPausedInDebuggerMessage:(NSString *)message onResume:(dispatch_block_t)onResume
{
}
- (void)hidePausedInDebuggerMessage
{
}
- (void)showWithURL:(NSURL *)URL
{
}
- (void)updateProgress:(RCTLoadingProgress *)progress
{
}
- (void)hide
{
}
- (std::shared_ptr<TurboModule>)getTurboModule:(const ObjCTurboModule::InitParams &)params
{
  return std::make_shared<NativeDevLoadingViewSpecJSI>(params);
}

@end

#endif

Class RCTDevLoadingViewCls(void)
{
  return RCTDevLoadingView.class;
}
