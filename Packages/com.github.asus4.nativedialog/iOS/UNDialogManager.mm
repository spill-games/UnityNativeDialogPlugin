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

// Returns YES if the message string contains HTML anchor tags.
static BOOL MessageContainsLinks(NSString *msg)
{
    return [msg rangeOfString:@"<a " options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Converts an HTML string to an NSAttributedString with appropriate font and adaptive colors.
// Falls back to plain text on parse error.
static NSAttributedString* AttributedStringFromHTML(NSString *html)
{
    NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil)
    {
        return [[NSAttributedString alloc] initWithString:html];
    }

    NSDictionary *parseOptions = @{
        NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
        NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding)
    };
    NSError *error = nil;
    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc]
        initWithData:data
            options:parseOptions
 documentAttributes:nil
               error:&error];

    if (error != nil || attrStr == nil)
    {
        return [[NSAttributedString alloc] initWithString:html];
    }

    NSRange fullRange = NSMakeRange(0, attrStr.length);

    // Apply system font and adaptive text color to the entire string
    [attrStr addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:13.0] range:fullRange];
    [attrStr addAttribute:NSForegroundColorAttributeName value:[UIColor labelColor] range:fullRange];

    // Restore link color and underline for anchor tag ranges
    [attrStr enumerateAttribute:NSLinkAttributeName
                        inRange:fullRange
                        options:0
                     usingBlock:^(id value, NSRange range, BOOL *stop)
    {
        if (value != nil)
        {
            [attrStr addAttribute:NSForegroundColorAttributeName value:[UIColor systemBlueColor] range:range];
            [attrStr addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
        }
    }];

    return attrStr;
}

extern "C" {
    int _showSelectDialog(const char *msg) {
        return [[UNDialogManager sharedManager]
                showSelectDialog:[NSString stringWithUTF8String:msg]];
    }

    int _showSelectTitleDialog(const char *title, const char *msg) {
        return [[UNDialogManager sharedManager]
                showSelectDialog:[NSString stringWithUTF8String:title]
                         message:[NSString stringWithUTF8String:msg]];
    }

    int _showSubmitDialog(const char *msg) {
        return [[UNDialogManager sharedManager]
                showSubmitDialog:[NSString stringWithUTF8String:msg]];
    }

    int _showSubmitTitleDialog(const char *title, const char *msg) {
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
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:decideLabelCopy
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnSubmit", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        [UnityGetGLViewController() presentViewController:alert animated:YES completion:nil];
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
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:decideLabelCopy
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            NSString *idStr = [NSString stringWithFormat:@"%d", dialogId];
            UnitySendMessage("DialogManager", "OnSubmit", idStr.UTF8String);
            [alertsRef removeObjectForKey:@(dialogId)];
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        [UnityGetGLViewController() presentViewController:alert animated:YES completion:nil];
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
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        [UnityGetGLViewController() presentViewController:alert animated:YES completion:nil];
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
        }]];

        [alertsRef setObject:alert forKey:@(dialogId)];
        [UnityGetGLViewController() presentViewController:alert animated:YES completion:nil];
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
