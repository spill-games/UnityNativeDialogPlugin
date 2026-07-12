//
//  UNDialogManager.mm
//  UnityDialogPlugin
//
//  Created by ibu on 12/10/09.
//  Copyright (c) 2012年 kayac. All rights reserved.
//

#import "UNDialogManager.h"
#import <UIKit/UIKit.h>

#define MakeStringCopy( _x_ ) ( _x_ != NULL && [_x_ isKindOfClass:[NSString class]] ) ? strdup( [_x_ UTF8String] ) : NULL

extern void UnitySendMessage(const char *, const char *, const char *);
extern UIViewController* UnityGetGLViewController();

// Dedicated top-level windows that host presented alerts, keyed by dialog id.
// Presenting on Unity's own view controller (or the app key window's root) is
// unreliable here: on Unity 6 the alert lands on a window that sits *behind*
// Unity's Metal render window, so it presents with no error but is never
// visible. Hosting the alert in our own UIWindow at UIWindowLevelAlert
// guarantees it renders above everything, regardless of Unity's window setup.
static NSMutableDictionary<NSNumber *, UIWindow *> *AlertWindows()
{
    static NSMutableDictionary *dict;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dict = [NSMutableDictionary dictionary]; });
    return dict;
}

// Returns a foreground-active UIWindowScene (required to make a window visible
// on iOS 13+), falling back to any window scene.
static UIWindowScene* ActiveWindowScene()
{
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes)
    {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive)
        {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in app.connectedScenes)
    {
        if ([scene isKindOfClass:[UIWindowScene class]])
        {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

// Hides and releases the dedicated window for a dialog id so touch events pass
// back to Unity once the alert is gone.
static void TeardownAlertWindow(int dialogId)
{
    UIWindow *window = AlertWindows()[@(dialogId)];
    if (window != nil)
    {
        window.hidden = YES;
        [AlertWindows() removeObjectForKey:@(dialogId)];
        NSLog(@"[UNDialog] tore down window id=%d", dialogId);
    }
}

// Presents the alert in its own top-level window. Retries on the main queue if
// no foreground window scene exists yet (dialog can fire during app init).
static void PresentAlertInOwnWindow(UIAlertController *alert, int dialogId, int attemptsLeft)
{
    UIWindowScene *scene = ActiveWindowScene();
    if (scene == nil && attemptsLeft > 0)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PresentAlertInOwnWindow(alert, dialogId, attemptsLeft - 1);
        });
        return;
    }

    UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                             : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = [UIColor clearColor];

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = root;
    [window makeKeyAndVisible];

    AlertWindows()[@(dialogId)] = window;

    NSLog(@"[UNDialog] presenting id=%d scene=%@ window=%@ level=%f",
          dialogId, scene, window, window.windowLevel);
    [root presentViewController:alert animated:YES completion:^{
        NSLog(@"[UNDialog] present completion fired id=%d", dialogId);
    }];
}

// Returns YES if the message string contains HTML anchor tags.
static BOOL MessageContainsLinks(NSString *msg)
{
    return [msg rangeOfString:@"<a " options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Converts the link-annotated string built by DialogManager.BuildHtmlFromLinks
// (plain text with <a href="url">text</a> anchors) into an NSAttributedString.
//
// This intentionally does NOT use NSAttributedString's NSHTMLTextDocumentType
// importer: that importer spins up WebKit's WebContent process, which the app
// sandbox denies ("deny process-info-codesignature ... com.apple.WebKit.WebContent").
// The denied/blocked import returns nothing on the main thread, so the alert
// never presents. Parsing the simple anchor markup ourselves keeps everything
// on-thread with no WebKit dependency.
static NSAttributedString* AttributedStringFromHTML(NSString *html)
{
    UIFont *font = [UIFont systemFontOfSize:13.0];
    NSDictionary *plainAttrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor labelColor]
    };

    NSError *error = nil;
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>"
                             options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                               error:&error];

    if (re == nil)
    {
        return [[NSAttributedString alloc] initWithString:html attributes:plainAttrs];
    }

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSUInteger cursor = 0;
    NSArray<NSTextCheckingResult *> *matches =
        [re matchesInString:html options:0 range:NSMakeRange(0, html.length)];

    for (NSTextCheckingResult *match in matches)
    {
        // Plain text preceding this anchor.
        if (match.range.location > cursor)
        {
            NSString *plain = [html substringWithRange:NSMakeRange(cursor, match.range.location - cursor)];
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:plain attributes:plainAttrs]];
        }

        NSString *url = [html substringWithRange:[match rangeAtIndex:1]];
        NSString *text = [html substringWithRange:[match rangeAtIndex:2]];
        NSDictionary *linkAttrs = @{
            NSFontAttributeName: font,
            NSLinkAttributeName: url,
            NSForegroundColorAttributeName: [UIColor systemBlueColor],
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
        };
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:linkAttrs]];
        cursor = match.range.location + match.range.length;
    }

    // Trailing plain text after the last anchor.
    if (cursor < html.length)
    {
        NSString *plain = [html substringFromIndex:cursor];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:plain attributes:plainAttrs]];
    }

    return result;
}

extern "C" {
    int _showSelectDialog(const char *msg) {
        return [[UNDialogManager sharedManager]
                showSelectDialog:[NSString stringWithUTF8String:msg]];
    }

    int _showSelectTitleDialog(const char *title, const char *msg) {
        NSLog(@"[UNDialog] _showSelectTitleDialog entered");
        return [[UNDialogManager sharedManager]
                showSelectDialog:[NSString stringWithUTF8String:title]
                         message:[NSString stringWithUTF8String:msg]];
    }

    int _showSubmitDialog(const char *msg) {
        return [[UNDialogManager sharedManager]
                showSubmitDialog:[NSString stringWithUTF8String:msg]];
    }

    int _showSubmitTitleDialog(const char *title, const char *msg) {
        NSLog(@"[UNDialog] _showSubmitTitleDialog entered");
        return [[UNDialogManager sharedManager]
                showSubmitDialog:[NSString stringWithUTF8String:title]
                         message:[NSString stringWithUTF8String:msg]];
    }

    void _dismissDialog(const int theID) {
        [[UNDialogManager sharedManager] dismissDialog:theID];
    }

    void _setLabel(const char *decide, const char *cancel, const char *close) {
        [[UNDialogManager sharedManager]
            setLabelTitleWithDecide:[NSString stringWithUTF8String:decide]
                             cancel:[NSString stringWithUTF8String:cancel]
                              close:[NSString stringWithUTF8String:close]];
    }
}


@implementation UNDialogManager

static UNDialogManager *sharedDialogManager;

+ (UNDialogManager*) sharedManager {
    @synchronized(self) {
        if (sharedDialogManager == nil) {
            sharedDialogManager = [[self alloc] init];
        }
    }
    return sharedDialogManager;
}

- (id) init {
    self = [super init];
    if (self) {
        alerts = [NSMutableDictionary dictionary];
        decideLabel = @"YES";
        cancelLabel = @"NO";
        closeLabel = @"CLOSE";
    }
    return self;
}

// Builds a UIAlertController for the given title and message.
// When the message contains HTML anchor tags, embeds a UITextView with link
// support via the contentViewController KVC property. Plain-text messages
// use the standard UIAlertController message label.
- (UIAlertController*) buildAlertWithTitle:(NSString*)title message:(NSString*)msg
{
    if (MessageContainsLinks(msg))
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];

        UITextView *textView = [[UITextView alloc] init];
        textView.editable = NO;
        textView.dataDetectorTypes = UIDataDetectorTypeLink;
        textView.backgroundColor = [UIColor clearColor];
        textView.textAlignment = NSTextAlignmentCenter;
        textView.translatesAutoresizingMaskIntoConstraints = NO;
        textView.attributedText = AttributedStringFromHTML(msg);

        UIViewController *contentVC = [[UIViewController alloc] init];
        contentVC.view.backgroundColor = [UIColor clearColor];
        [contentVC.view addSubview:textView];

        [NSLayoutConstraint activateConstraints:@[
            [textView.topAnchor constraintEqualToAnchor:contentVC.view.topAnchor constant:8.0],
            [textView.bottomAnchor constraintEqualToAnchor:contentVC.view.bottomAnchor constant:-8.0],
            [textView.leadingAnchor constraintEqualToAnchor:contentVC.view.leadingAnchor constant:4.0],
            [textView.trailingAnchor constraintEqualToAnchor:contentVC.view.trailingAnchor constant:-4.0],
        ]];

        // Size the content area to fit the text, capped to avoid excessively tall alerts
        CGFloat contentWidth = 236.0;
        CGFloat maxHeight = 180.0;
        CGSize textSize = [textView sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
        CGFloat height = MIN(textSize.height + 16.0, maxHeight);
        textView.scrollEnabled = (textSize.height + 16.0 > maxHeight);
        contentVC.preferredContentSize = CGSizeMake(contentWidth, MAX(height, 44.0));

        [alert setValue:contentVC forKey:@"contentViewController"];
        return alert;
    }

    return [UIAlertController alertControllerWithTitle:title
                                               message:msg
                                        preferredStyle:UIAlertControllerStyleAlert];
}

- (int) showSelectDialog:(NSString*)msg {
    int dialogId = ++_id;
    NSMutableDictionary *alertsRef = alerts;
    NSString *cancelLabelCopy = [cancelLabel copy];
    NSString *decideLabelCopy = [decideLabel copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [self buildAlertWithTitle:nil message:msg];

        [alert addAction:[UIAlertAction actionWithTitle:cancelLabelCopy
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnCancel", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
            TeardownAlertWindow(dialogId);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:decideLabelCopy
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnSubmit", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
            TeardownAlertWindow(dialogId);
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        PresentAlertInOwnWindow(alert, dialogId, 20);
    });

    return dialogId;
}

- (int) showSelectDialog:(NSString*)title message:(NSString*)msg {
    int dialogId = ++_id;
    NSMutableDictionary *alertsRef = alerts;
    NSString *cancelLabelCopy = [cancelLabel copy];
    NSString *decideLabelCopy = [decideLabel copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [self buildAlertWithTitle:title message:msg];

        [alert addAction:[UIAlertAction actionWithTitle:cancelLabelCopy
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnCancel", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
            TeardownAlertWindow(dialogId);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:decideLabelCopy
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnSubmit", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
            TeardownAlertWindow(dialogId);
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        PresentAlertInOwnWindow(alert, dialogId, 20);
    });

    return dialogId;
}

- (int) showSubmitDialog:(NSString*)msg {
    int dialogId = ++_id;
    NSMutableDictionary *alertsRef = alerts;
    NSString *closeLabelCopy = [closeLabel copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [self buildAlertWithTitle:nil message:msg];

        [alert addAction:[UIAlertAction actionWithTitle:closeLabelCopy
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnSubmit", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
            TeardownAlertWindow(dialogId);
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        PresentAlertInOwnWindow(alert, dialogId, 20);
    });

    return dialogId;
}

- (int) showSubmitDialog:(NSString*)title message:(NSString*)msg {
    int dialogId = ++_id;
    NSMutableDictionary *alertsRef = alerts;
    NSString *closeLabelCopy = [closeLabel copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [self buildAlertWithTitle:title message:msg];

        [alert addAction:[UIAlertAction actionWithTitle:closeLabelCopy
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnSubmit", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
            TeardownAlertWindow(dialogId);
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        PresentAlertInOwnWindow(alert, dialogId, 20);
    });

    return dialogId;
}

- (void) dismissDialog:(int)theID {
    // Dictionary reads/writes must happen on the same queue as inserts (the
    // present blocks insert on the main queue). Doing the lookup on the caller
    // thread races: a dismiss issued right after a show finds nothing (the
    // insert block has not run yet), then the alert is presented and orphaned.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = alerts[@(theID)];
        if (alert != nil)
        {
            [alert dismissViewControllerAnimated:YES completion:nil];
            [alerts removeObjectForKey:@(theID)];
        }
        TeardownAlertWindow(theID);
    });
}

- (void) setLabelTitleWithDecide:(NSString*)decide cancel:(NSString*)cancel close:(NSString*)close {
    // Guard against nil (a NULL C-string from Unity yields a nil NSString);
    // -stringWithString: throws NSInvalidArgumentException on nil.
    if (decide != nil) { decideLabel = [decide copy]; }
    if (cancel != nil) { cancelLabel = [cancel copy]; }
    if (close  != nil) { closeLabel  = [close copy]; }
}

@end
