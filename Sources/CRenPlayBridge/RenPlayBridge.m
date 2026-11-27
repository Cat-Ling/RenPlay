// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include "RenPlayBridge.h"

#ifdef __APPLE__

#define GLES_SILENCE_DEPRECATION 1

@import UIKit;
@import Foundation;
@import AVFoundation;
@import StoreKit;

#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern const unsigned char *glGetString(unsigned int name);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// Keep a file-scope reference into MetalANGLE so the linker cannot strip it as unused.
const void * volatile renplay_ma_symbol_anchor = (const void *)&glGetString;
#pragma clang diagnostic pop

static void *g_active_handle = NULL;
static int g_active_sdl_version = 2;
static char g_log_file_path[2048] = {0};
static char g_loaded_framework[2048] = {0};
static int g_text_input_active = 0;
static __weak UIWindowScene *g_target_window_scene = nil;
static atomic_int g_pending_command = 0;
static atomic_int g_quit_in_progress = 0;

static UIWindowScene *renplay_find_foreground_scene(void) {
    UISceneActivationState states[] = {
        UISceneActivationStateForegroundActive,
        UISceneActivationStateForegroundInactive,
    };
    for (NSUInteger i = 0; i < sizeof(states) / sizeof(states[0]); ++i) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == states[i]) {
                return (UIWindowScene *)scene;
            }
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static UIWindowScene *renplay_resolve_target_scene(void) {
    UIWindowScene *captured = g_target_window_scene;
    if (captured != nil) {
        return captured;
    }
    return renplay_find_foreground_scene();
}

void renplay_capture_window_scene(void) {
    g_target_window_scene = renplay_find_foreground_scene();
}

static UIWindow *renplay_find_game_window(void) {
    UIWindowScene *scene = renplay_resolve_target_scene();
    if (!scene) {
        return nil;
    }
    UIWindow *fallback = nil;
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha == 0 || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) {
            continue;
        }
        if (window.isKeyWindow) {
            return window;
        }
        if (!fallback) {
            fallback = window;
        }
    }
    return fallback;
}

static UIViewController *renplay_find_presenter(UIWindow *window) {
    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class] &&
                   ((UINavigationController *)controller).visibleViewController) {
            controller = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class] &&
                   ((UITabBarController *)controller).selectedViewController) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            return controller;
        }
    }
    return nil;
}

@implementation UIWindow (RenPlaySDLScene)

- (void)renplay_makeKeyAndVisible {
    Class sdlWinCls = NSClassFromString(@"SDL_uikitwindow");
    if (sdlWinCls != Nil && [self isKindOfClass:sdlWinCls] && self.windowScene == nil) {
        UIWindowScene *scene = renplay_resolve_target_scene();
        if (scene != nil) {
            self.windowScene = scene;
        }
    }
    [self renplay_makeKeyAndVisible];
}

- (void)renplay_setHidden:(BOOL)hidden {
    Class sdlWinCls = NSClassFromString(@"SDL_uikitwindow");
    if (!hidden && sdlWinCls != Nil && [self isKindOfClass:sdlWinCls] && self.windowScene == nil) {
        UIWindowScene *scene = renplay_resolve_target_scene();
        if (scene != nil) {
            self.windowScene = scene;
        }
    }
    [self renplay_setHidden:hidden];
}

@end

// Objective-C classes expected by Ren'Py's iossupport / pyobjus bridge.
@interface Log : NSObject
+ (void)log:(char *)s;
@end

@implementation Log
+ (void)log:(char *)s {
    if (s != NULL) {
        NSLog(@"[RenPy] %s", s);
        if (g_log_file_path[0] != '\0') {
            FILE *fp = fopen(g_log_file_path, "a");
            if (fp != NULL) {
                fprintf(fp, "[RenPy] %s\n", s);
                fclose(fp);
            }
        }
    }
}
@end

@interface RenPlayVideoView : UIView
@property (nonatomic) AVPlayer *player;
@end

@implementation RenPlayVideoView
+ (Class)layerClass {
    return [AVPlayerLayer class];
}
- (AVPlayer *)player {
    return [(AVPlayerLayer *)self.layer player];
}
- (void)setPlayer:(AVPlayer *)player {
    [(AVPlayerLayer *)self.layer setPlayer:player];
}
@end

@interface VideoPlayer : NSObject {
    UIView *_hostView;
    AVPlayer *_player;
    RenPlayVideoView *_vpv;
    BOOL _playing;
    BOOL _paused;
}
- (id)initWithFile:(char *)fn;
- (int)isPlaying;
- (void)stop;
- (void)pause;
- (void)unpause;
- (void)periodic;
@end

@implementation VideoPlayer

- (id)initWithFile:(char *)fn {
    self = [super init];
    if (!self || fn == NULL) {
        return nil;
    }

    UIWindow *window = renplay_find_game_window();
    _hostView = window.rootViewController.view;
    if (!_hostView) {
        return self;
    }

    NSString *path = [NSString stringWithUTF8String:fn];
    NSURL *url = [NSURL fileURLWithPath:path];
    _player = [AVPlayer playerWithURL:url];

    _vpv = [[RenPlayVideoView alloc] initWithFrame:_hostView.bounds];
    _vpv.player = _player;
    _vpv.opaque = YES;
    _vpv.backgroundColor = [UIColor blackColor];
    _vpv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_hostView addSubview:_vpv];

    [_player play];
    _playing = YES;
    _paused = NO;
    return self;
}

- (int)isPlaying {
    return _playing ? 1 : 0;
}

- (void)periodic {
    if (!_playing || _paused) {
        return;
    }
    if (_player.rate == 0.0f || _player.error != nil) {
        [self stop];
    }
}

- (void)stop {
    [_player pause];
    [_vpv removeFromSuperview];
    _playing = NO;
    _paused = NO;
}

- (void)pause {
    [_player pause];
    _paused = YES;
}

- (void)unpause {
    if (!_playing) {
        return;
    }
    [_player play];
    _paused = NO;
}

@end

@interface IAPHelper : NSObject <SKProductsRequestDelegate, SKPaymentTransactionObserver>
@property NSArray *productIdentifiers;
@property NSMutableDictionary *products;
@property int initialized_queue;
@property int validated;
@property int finished;
@property NSMutableSet *purchased;
@property NSMutableSet *deferred;
@property NSString *dialogTitle;
- (id)init;
- (void)initQueue;
- (BOOL)canMakePayments;
- (void)validateProductIdentifiersInBackground;
- (void)validateProductIdentifiers;
- (void)beginPurchase:(NSString *)identifier;
- (void)restorePurchases;
- (BOOL)hasPurchased:(NSString *)identifier;
- (BOOL)hasPurchasedConsumable:(NSString *)identifier;
- (BOOL)isDeferred:(NSString *)identifier;
- (NSString *)formatPrice:(NSString *)identifier;
- (void)requestReview;
- (BOOL)showDialog;
@end

@implementation IAPHelper {
    UIAlertController *_alert;
}

- (id)init {
    self = [super init];
    if (!self) return nil;
    _products = [[NSMutableDictionary alloc] init];
    _purchased = [[NSMutableSet alloc] init];
    _deferred = [[NSMutableSet alloc] init];
    _validated = 0;
    _finished = 1;
    _initialized_queue = 0;
    _dialogTitle = @"Contacting App Store\nPlease Wait...";
    return self;
}

- (void)initQueue {
    if (self.initialized_queue) return;
    [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
    self.initialized_queue = 1;
}

- (BOOL)canMakePayments {
    [self initQueue];
    return [SKPaymentQueue canMakePayments];
}

- (void)validateProductIdentifiers {
    if (self.validated || ![self showDialog]) {
        self.finished = 1;
        return;
    }
    SKProductsRequest *req = [[SKProductsRequest alloc]
        initWithProductIdentifiers:[NSSet setWithArray:self.productIdentifiers ?: @[]]];
    self.finished = 0;
    req.delegate = self;
    [req start];
}

- (void)validateProductIdentifiersInBackground {
    SKProductsRequest *req = [[SKProductsRequest alloc]
        initWithProductIdentifiers:[NSSet setWithArray:self.productIdentifiers ?: @[]]];
    self.validated = 0;
    req.delegate = self;
    [req start];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    for (SKProduct *prod in response.products) {
        [self.products setObject:prod forKey:prod.productIdentifier];
    }
    [self hideDialog];
    self.validated = 1;
    self.finished = 1;
}

- (BOOL)showDialog {
    if (_alert != nil) return YES;
    UIViewController *presenter = renplay_find_presenter(renplay_find_game_window());
    if (!presenter || !presenter.view.window || presenter.isBeingDismissed) {
        return NO;
    }
    _alert = [UIAlertController alertControllerWithTitle:self.dialogTitle
                                                 message:nil
                                          preferredStyle:UIAlertControllerStyleAlert];
    [presenter presentViewController:_alert animated:YES completion:nil];
    return YES;
}

- (void)hideDialog {
    if (_alert != nil) {
        [_alert dismissViewControllerAnimated:YES completion:nil];
        _alert = nil;
    }
}

- (void)beginPurchase:(NSString *)identifier {
    [self initQueue];
    SKProduct *product = [self.products objectForKey:identifier];
    if (!product || ![self showDialog]) {
        self.finished = 1;
        return;
    }
    self.finished = 0;
    SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
    payment.quantity = 1;
    [[SKPaymentQueue defaultQueue] addPayment:payment];
}

- (void)restorePurchases {
    if (![self showDialog]) {
        self.finished = 1;
        return;
    }
    [self initQueue];
    self.finished = 0;
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {
    for (SKPaymentTransaction *t in transactions) {
        NSString *identifier = t.payment.productIdentifier;
        switch (t.transactionState) {
            case SKPaymentTransactionStatePurchased:
                [self.deferred removeObject:identifier];
                [self.purchased addObject:identifier];
                [[SKPaymentQueue defaultQueue] finishTransaction:t];
                [self hideDialog];
                self.finished = 1;
                break;
            case SKPaymentTransactionStateFailed:
                [[SKPaymentQueue defaultQueue] finishTransaction:t];
                [self hideDialog];
                self.finished = 1;
                break;
            case SKPaymentTransactionStateRestored:
                [self.deferred removeObject:identifier];
                [self.purchased addObject:identifier];
                [[SKPaymentQueue defaultQueue] finishTransaction:t];
                break;
            case SKPaymentTransactionStatePurchasing:
                break;
            case SKPaymentTransactionStateDeferred:
                [self.deferred addObject:identifier];
                [self hideDialog];
                self.finished = 1;
                break;
        }
    }
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    [self hideDialog];
    self.finished = 1;
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    [self hideDialog];
    self.finished = 1;
}

- (BOOL)hasPurchased:(NSString *)identifier {
    return [self.purchased member:identifier] != nil;
}

- (BOOL)hasPurchasedConsumable:(NSString *)identifier {
    BOOL res = [self.purchased member:identifier] != nil;
    [self.purchased removeObject:identifier];
    return res;
}

- (BOOL)isDeferred:(NSString *)identifier {
    return [self.deferred member:identifier] != nil;
}

- (NSString *)formatPrice:(NSString *)identifier {
    SKProduct *product = [self.products objectForKey:identifier];
    if (!product) return nil;
    NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
    [fmt setFormatterBehavior:NSNumberFormatterBehavior10_4];
    [fmt setNumberStyle:NSNumberFormatterCurrencyStyle];
    [fmt setLocale:product.priceLocale];
    return [fmt stringFromNumber:product.price];
}

- (void)requestReview {
    UIWindow *window = renplay_find_game_window();
    if (window.windowScene) {
        [SKStoreReviewController requestReviewInScene:window.windowScene];
    }
}

@end

@interface Age : NSObject
+ (BOOL)requested;
+ (BOOL)inProgress;
+ (BOOL)valid;
+ (NSInteger)ageLower;
+ (NSInteger)ageUpper;
+ (void)requestAgeRange;
@end

@implementation Age
+ (BOOL)requested { return NO; }
+ (BOOL)inProgress { return NO; }
+ (BOOL)valid { return NO; }
+ (NSInteger)ageLower { return -1; }
+ (NSInteger)ageUpper { return 150; }
+ (void)requestAgeRange {}
@end

@interface RenPlayRuntimeBridge : NSObject
+ (int)consumeCommand;
@end

@implementation RenPlayRuntimeBridge
+ (int)consumeCommand {
    return atomic_exchange(&g_pending_command, 0);
}
@end

static void renplay_uncaught_exception_handler(NSException *exception) {
    NSLog(@"[RenPlay-CRASH] Uncaught ObjC exception: %@: %@\n%@",
          exception.name, exception.reason, exception.callStackSymbols);
    if (g_log_file_path[0] != '\0') {
        FILE *fp = fopen(g_log_file_path, "a");
        if (fp != NULL) {
            fprintf(fp, "[RenPlay-CRASH] Uncaught ObjC exception: %s: %s\n%s\n",
                    exception.name.UTF8String ?: "",
                    exception.reason.UTF8String ?: "",
                    exception.callStackSymbols.description.UTF8String ?: "");
            fclose(fp);
        }
    }
}

static void renplay_signal_handler(int sig, siginfo_t *info, void *uap) {
    (void)uap;
    char msg[160];
    int len = snprintf(msg, sizeof(msg),
                       "\n[RenPlay-CRASH] Signal %d (%s) at addr=%p\n",
                       sig, strsignal(sig) ?: "unknown",
                       info ? info->si_addr : NULL);
    if (len > 0) {
        (void)write(STDERR_FILENO, msg, (size_t)len);
    }
    void *frames[64];
    int n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, STDERR_FILENO);
    raise(sig);
}

static void renplay_install_crash_handlers(void) {
    NSSetUncaughtExceptionHandler(&renplay_uncaught_exception_handler);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = &renplay_signal_handler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    int signals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        sigaction(signals[i], &sa, NULL);
    }
}

void renplay_install_sdl_scene_bridge(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        (void)renplay_ma_symbol_anchor;
        renplay_install_crash_handlers();
        Class cls = [UIWindow class];
        Method m1 = class_getInstanceMethod(cls, @selector(makeKeyAndVisible));
        Method m2 = class_getInstanceMethod(cls, @selector(renplay_makeKeyAndVisible));
        if (m1 && m2) {
            method_exchangeImplementations(m1, m2);
        }
        Method h1 = class_getInstanceMethod(cls, @selector(setHidden:));
        Method h2 = class_getInstanceMethod(cls, @selector(renplay_setHidden:));
        if (h1 && h2) {
            method_exchangeImplementations(h1, h2);
        }
    });
}

int renplay_has_sdl_window(void) {
    Class sdlWinCls = NSClassFromString(@"SDL_uikitwindow");
    if (sdlWinCls == Nil) {
        return 0;
    }
    UIWindowScene *scene = renplay_resolve_target_scene();
    if (!scene) {
        return 0;
    }
    for (UIWindow *win in scene.windows) {
        if ([win isKindOfClass:sdlWinCls] && !win.hidden) {
            return 1;
        }
    }
    return 0;
}

static void renplay_redirect_stdio(const char *logDir) {
    if (!logDir || logDir[0] == '\0') {
        return;
    }
    snprintf(g_log_file_path, sizeof(g_log_file_path), "%s/renplay_session.log", logDir);
    int fd = open(g_log_file_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        close(fd);
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
    }
}

const char *renplay_get_log_file_path(void) {
    return g_log_file_path[0] != '\0' ? g_log_file_path : NULL;
}

int renplay_launch_engine(
    const char *frameworkPath,
    const char *engineBaseDir,
    const char *gameDir,
    const char *saveDir,
    const char *logDir,
    const char *variant,
    int sdlVersionHint,
    int allowNetwork,
    int devMode,
    int forceRollback,
    int forceSkip,
    int lessMemory,
    char *errorBuf,
    size_t errorBufSize
) {
    renplay_install_sdl_scene_bridge();
    renplay_redirect_stdio(logDir);

    if (frameworkPath == NULL || engineBaseDir == NULL || gameDir == NULL) {
        if (errorBuf && errorBufSize > 0) {
            snprintf(errorBuf, errorBufSize, "Missing required launch path.");
        }
        return -1;
    }

    setenv("RENPY_GAME_DIRECTORY", gameDir, 1);
    if (saveDir) setenv("RENPY_SAVE_DIRECTORY", saveDir, 1);
    if (logDir) setenv("RENPY_LOG_DIRECTORY", logDir, 1);
    if (variant && variant[0] != '\0') setenv("RENPY_VARIANT", variant, 1);
    setenv("RENPY_PLATFORM", "ios-arm64", 1);
    setenv("RENPY_ALLOW_NETWORK", allowNetwork ? "1" : "0", 1);
    setenv("RENPY_DEV_MODE", devMode ? "1" : "0", 1);
    setenv("RENPY_FORCE_ROLLBACK", forceRollback ? "1" : "0", 1);
    setenv("RENPY_FORCE_SKIP", forceSkip ? "1" : "0", 1);
    setenv("RENPY_LESS_MEMORY", lessMemory ? "1" : "0", 1);
    setenv("RENPY_LESS_UPDATES", "1", 1);

    if (g_loaded_framework[0] != '\0') {
        if (errorBuf && errorBufSize > 0) {
            snprintf(
                errorBuf,
                errorBufSize,
                "An engine runtime was already loaded in this session. Close and reopen RenPlay to launch another game or engine version."
            );
        }
        return -4;
    }

    // Preload MetalANGLE with RTLD_GLOBAL so SDL_GL_GetProcAddress (dlsym(RTLD_DEFAULT, ...)) resolves GLES symbols.
    const char *fwDirMarker = strstr(frameworkPath, "/Frameworks/");
    if (fwDirMarker != NULL) {
        size_t prefixLen = (size_t)(fwDirMarker - frameworkPath) + strlen("/Frameworks/");
        char metalAnglePath[2048];
        if (prefixLen + strlen("MetalANGLE.framework/MetalANGLE") < sizeof(metalAnglePath)) {
            memcpy(metalAnglePath, frameworkPath, prefixLen);
            strcpy(metalAnglePath + prefixLen, "MetalANGLE.framework/MetalANGLE");
            void *maHandle = dlopen(metalAnglePath, RTLD_NOW | RTLD_GLOBAL);
            if (maHandle == NULL) {
                const char *err = dlerror();
                if (errorBuf && errorBufSize > 0) {
                    snprintf(errorBuf, errorBufSize, "MetalANGLE dlopen failed: %s", err ? err : "unknown error");
                }
                return -2;
            }
        }
    }

    void *handle = dlopen(frameworkPath, RTLD_NOW | RTLD_GLOBAL);
    if (handle == NULL) {
        const char *err = dlerror();
        if (errorBuf && errorBufSize > 0) {
            snprintf(errorBuf, errorBufSize, "dlopen failed: %s", err ? err : "unknown error");
        }
        return -2;
    }
    snprintf(g_loaded_framework, sizeof(g_loaded_framework), "%s", frameworkPath);

    typedef int (*SDLSetHintFn)(const char *name, const char *value);
    SDLSetHintFn setHint = (SDLSetHintFn)dlsym(handle, "SDL_SetHint");
    if (setHint != NULL) {
        setHint("SDL_IOS_HIDE_HOME_INDICATOR", "1");
        setHint("SDL_IOS_IDLE_TIMER_DISABLED", "1");
    }

    typedef int (*EntryFn)(int, char **);
    EntryFn entry = (EntryFn)dlsym(handle, "renplay_launch");
    if (entry == NULL) {
        entry = (EntryFn)dlsym(handle, "launcher_main");
    }
    if (entry == NULL) {
        const char *err = dlerror();
        if (errorBuf && errorBufSize > 0) {
            snprintf(errorBuf, errorBufSize, "Entry symbol not found: %s", err ? err : "renplay_launch");
        }
        dlclose(handle);
        return -3;
    }

    g_active_handle = handle;
    g_active_sdl_version = sdlVersionHint;
    atomic_store(&g_pending_command, 0);
    atomic_store(&g_quit_in_progress, 0);

    // librenpython resolves <dirname(argv[0])>/base/main.py and /base/lib/pythonX.Y.
    char argv0[2048];
    snprintf(argv0, sizeof(argv0), "%s/RenPlay", engineBaseDir);
    char *argv[] = { argv0, (char *)gameDir, NULL };

    void *glSym = dlsym(RTLD_DEFAULT, "glGetString");
    Dl_info glInfo;
    if (glSym != NULL && dladdr(glSym, &glInfo) != 0 && glInfo.dli_fname != NULL) {
        NSLog(@"[RenPlay] glGetString image: %s", glInfo.dli_fname);
        if (g_log_file_path[0] != '\0') {
            FILE *fp = fopen(g_log_file_path, "a");
            if (fp != NULL) {
                fprintf(fp, "[RenPlay] glGetString image: %s\n", glInfo.dli_fname);
                fclose(fp);
            }
        }
    }

    int rc = entry(2, argv);
    g_active_handle = NULL;
    return rc;
}

static void renplay_focus_sdl_textfield_on_main(int show) {
    Class sdlWinCls = NSClassFromString(@"SDL_uikitwindow");
    if (sdlWinCls == Nil) {
        return;
    }
    UIWindowScene *scene = renplay_resolve_target_scene();
    if (!scene) {
        return;
    }
    for (UIWindow *win in scene.windows) {
        if (![win isKindOfClass:sdlWinCls] || win.hidden) {
            continue;
        }
        UIView *rootView = win.rootViewController.view;
        for (UIView *subview in rootView.subviews) {
            if ([subview isKindOfClass:UITextField.class]) {
                if (show) {
                    [subview becomeFirstResponder];
                } else {
                    [subview resignFirstResponder];
                }
                return;
            }
            for (UIView *child in subview.subviews) {
                if ([child isKindOfClass:UITextField.class]) {
                    if (show) {
                        [child becomeFirstResponder];
                    } else {
                        [child resignFirstResponder];
                    }
                    return;
                }
            }
        }
    }
}

static void renplay_focus_sdl_textfield(int show) {
    if ([NSThread isMainThread]) {
        renplay_focus_sdl_textfield_on_main(show);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            renplay_focus_sdl_textfield_on_main(show);
        });
    }
}

static void *renplay_quit_watchdog(void *arg) {
    (void)arg;
    usleep(300000);
    fflush(NULL);
    _exit(0);
    return NULL;
}

void renplay_request_command(int command) {
    if (command == RENPLAY_CMD_TOGGLE_KEYBOARD) {
        g_text_input_active = !g_text_input_active;
        atomic_store(&g_pending_command, RENPLAY_CMD_TOGGLE_KEYBOARD);
        renplay_focus_sdl_textfield(g_text_input_active);
        return;
    }
    if (command == RENPLAY_CMD_QUIT) {
        atomic_store(&g_pending_command, RENPLAY_CMD_QUIT);
        if (atomic_exchange(&g_quit_in_progress, 1) == 0) {
            pthread_t thread;
            pthread_attr_t attr;
            if (pthread_attr_init(&attr) == 0) {
                pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
                if (pthread_create(&thread, &attr, renplay_quit_watchdog, NULL) != 0) {
                    fflush(NULL);
                    _exit(0);
                }
                pthread_attr_destroy(&attr);
            } else {
                fflush(NULL);
                _exit(0);
            }
        }
        return;
    }
    atomic_store(&g_pending_command, command);
}

typedef int (*SDL2PushEventFn)(void *event);
typedef int (*SDL3PushEventFn)(void *event);

void renplay_send_sdl_quit(void) {
    renplay_request_command(RENPLAY_CMD_QUIT);
}

void renplay_send_key_press(int sdlKeycode, int sdlScancode) {
    if (!g_active_handle) return;
    SDL2PushEventFn pushFn = (SDL2PushEventFn)dlsym(g_active_handle, "SDL_PushEvent");
    if (!pushFn) return;

    uint8_t ev[128];
    if (g_active_sdl_version >= 3) {
        uint32_t downType = 0x300;
        uint32_t upType = 0x301;
        uint32_t sc = (uint32_t)sdlScancode;
        uint32_t kc = (uint32_t)sdlKeycode;

        memset(ev, 0, sizeof(ev));
        memcpy(ev + 0, &downType, 4);
        memcpy(ev + 24, &sc, 4);
        memcpy(ev + 28, &kc, 4);
        ev[36] = 1;
        pushFn(ev);

        memset(ev, 0, sizeof(ev));
        memcpy(ev + 0, &upType, 4);
        memcpy(ev + 24, &sc, 4);
        memcpy(ev + 28, &kc, 4);
        ev[36] = 0;
        pushFn(ev);
    } else {
        uint32_t downType = 0x300;
        uint32_t upType = 0x301;
        uint32_t sc = (uint32_t)sdlScancode;
        int32_t sym = (int32_t)sdlKeycode;

        memset(ev, 0, sizeof(ev));
        memcpy(ev + 0, &downType, 4);
        ev[12] = 1;
        memcpy(ev + 16, &sc, 4);
        memcpy(ev + 20, &sym, 4);
        pushFn(ev);

        memset(ev, 0, sizeof(ev));
        memcpy(ev + 0, &upType, 4);
        ev[12] = 0;
        memcpy(ev + 16, &sc, 4);
        memcpy(ev + 20, &sym, 4);
        pushFn(ev);
    }
}

void renplay_toggle_text_input(void) {
    renplay_request_command(RENPLAY_CMD_TOGGLE_KEYBOARD);
}

#else

void renplay_install_sdl_scene_bridge(void) {}
void renplay_capture_window_scene(void) {}
void renplay_request_command(int command) { (void)command; }

int renplay_launch_engine(
    const char *frameworkPath,
    const char *engineBaseDir,
    const char *gameDir,
    const char *saveDir,
    const char *logDir,
    const char *variant,
    int sdlVersionHint,
    int allowNetwork,
    int devMode,
    int forceRollback,
    int forceSkip,
    int lessMemory,
    char *errorBuf,
    size_t errorBufSize
) {
    (void)frameworkPath;
    (void)engineBaseDir;
    (void)gameDir;
    (void)saveDir;
    (void)logDir;
    (void)variant;
    (void)sdlVersionHint;
    (void)allowNetwork;
    (void)devMode;
    (void)forceRollback;
    (void)forceSkip;
    (void)lessMemory;
    (void)errorBuf;
    (void)errorBufSize;
    return -1;
}

void renplay_send_sdl_quit(void) {}
void renplay_send_key_press(int sdlKeycode, int sdlScancode) {
    (void)sdlKeycode;
    (void)sdlScancode;
}
void renplay_toggle_text_input(void) {}
const char *renplay_get_log_file_path(void) { return NULL; }
int renplay_has_sdl_window(void) { return 0; }

#endif
