//
//  OTRMessagesViewController.m
//  Off the Record
//
//  Created by David Chiles on 5/12/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

#import "OTRMessagesViewController.h"

#import "OTRDatabaseView.h"
#import "OTRDatabaseManager.h"
#import "OTRLog.h"

#import "OTRBuddy.h"
#import "OTRAccount.h"
#import "OTRMessage+JSQMessageData.h"
#import "JSQMessages.h"
#import "OTRProtocolManager.h"
#import "OTRXMPPTorAccount.h"
#import "OTRXMPPManager.h"
#import "OTRLockButton.h"
#import "OTRButtonView.h"
#import "Strings.h"
#import "UIAlertView+Blocks.h"
#import "OTRTitleSubtitleView.h"
#import "OTRKit.h"
#import "OTRImages.h"
#import "UIActivityViewController+ChatSecure.h"
#import "OTRUtilities.h"
#import "OTRProtocolManager.h"
#import "OTRLoginViewController.h"
#import "OTRColors.h"
#import "JSQMessagesCollectionViewCell+ChatSecure.h"
#import "NSString+FontAwesome.h"
#import "OTRAttachmentPicker.h"

static NSTimeInterval const kOTRMessageSentDateShowTimeInterval = 1 * 60;

typedef NS_ENUM(int, OTRDropDownType) {
    OTRDropDownTypeNone          = 0,
    OTRDropDownTypeEncryption    = 1,
    OTRDropDownTypePush          = 2
};

@interface OTRMessagesViewController () <UITextViewDelegate, OTRAttachmentPickerDelegate>

@property (nonatomic, strong) OTRAccount *account;

@property (nonatomic, strong) YapDatabaseConnection *uiDatabaseConnection;
@property (nonatomic, strong) YapDatabaseViewMappings *messageMappings;
@property (nonatomic, strong) YapDatabaseViewMappings *buddyMappings;

@property (nonatomic, strong) JSQMessagesBubbleImage *outgoingBubbleImage;
@property (nonatomic, strong) JSQMessagesBubbleImage *incomingBubbleImage;

@property (nonatomic, weak) id textViewNotificationObject;
@property (nonatomic, weak) id databaseConnectionDidUpdateNotificationObject;
@property (nonatomic, weak) id didFinishGeneratingPrivateKeyNotificationObject;
@property (nonatomic, weak) id messageStateDidChangeNotificationObject;

@property (nonatomic, weak) OTRXMPPManager *xmppManager;

@property (nonatomic ,strong) UIBarButtonItem *lockBarButtonItem;
@property (nonatomic, strong) OTRLockButton *lockButton;
@property (nonatomic, strong) OTRButtonView *buttonDropdownView;
@property (nonatomic, strong) OTRTitleSubtitleView *titleView;

@property (nonatomic, strong) OTRAttachmentPicker *attachmentPicker;

@end

@implementation OTRMessagesViewController

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.automaticallyScrollsToMostRecentMessage = YES;
    
    ////// bubbles //////
    JSQMessagesBubbleImageFactory *bubbleImageFactory = [[JSQMessagesBubbleImageFactory alloc] init];
    
    self.outgoingBubbleImage = [bubbleImageFactory outgoingMessagesBubbleImageWithColor:[UIColor jsq_messageBubbleBlueColor]];
    
    self.incomingBubbleImage = [bubbleImageFactory incomingMessagesBubbleImageWithColor:[UIColor jsq_messageBubbleLightGrayColor]];
    
    ////// Lock Button //////
    
    ////// TitleView //////
    self.titleView = [[OTRTitleSubtitleView alloc] initWithFrame:CGRectMake(0, 0, 200, 44)];
    self.titleView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    self.navigationItem.titleView = self.titleView;
    
    UITapGestureRecognizer *tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTapTitleView:)];
    [self.titleView addGestureRecognizer:tapGestureRecognizer];
    
    [self refreshTitleView];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self refreshLockButton];
    
    __weak OTRMessagesViewController *welf = self;
    
    self.textViewNotificationObject = [[NSNotificationCenter defaultCenter] addObserverForName:UITextViewTextDidChangeNotification object:self.inputToolbar.contentView.textView queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [welf textViewDidChangeNotifcation:note];
    }];
    
    [self.uiDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        [welf.messageMappings updateWithTransaction:transaction];
        [welf.buddyMappings updateWithTransaction:transaction];
    }];
    
    void (^refreshGeneratingLock)(OTRAccount *) = ^void(OTRAccount * account) {
        if ([account.uniqueId isEqualToString:welf.account.uniqueId]) {
            [welf refreshLockButton];
        }
    };
    
    self.didFinishGeneratingPrivateKeyNotificationObject = [[NSNotificationCenter defaultCenter] addObserverForName:OTRDidFinishGeneratingPrivateKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[OTRAccount class]]) {
            refreshGeneratingLock(note.object);
        }
    }];
    
    self.messageStateDidChangeNotificationObject = [[NSNotificationCenter defaultCenter] addObserverForName:OTRMessageStateDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[OTRBuddy class]]) {
            OTRBuddy *notificationBuddy = note.object;
            if ([notificationBuddy.uniqueId isEqualToString:welf.buddy.uniqueId]) {
                [welf refreshLockButton];
            }
        }
    }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [self saveCurrentMessageText];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self.textViewNotificationObject];
    [[NSNotificationCenter defaultCenter] removeObserver:self.databaseConnectionDidUpdateNotificationObject];
    [[NSNotificationCenter defaultCenter] removeObserver:self.messageStateDidChangeNotificationObject];
    [[NSNotificationCenter defaultCenter] removeObserver:self.didFinishGeneratingPrivateKeyNotificationObject];
}

- (YapDatabaseConnection *)uiDatabaseConnection
{
    NSAssert([NSThread isMainThread], @"Must access uiDatabaseConnection on main thread!");
    if (!_uiDatabaseConnection) {
        YapDatabase *database = [OTRDatabaseManager sharedInstance].database;
        _uiDatabaseConnection = [database newConnection];
        [_uiDatabaseConnection beginLongLivedReadTransaction];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(yapDatabaseModified:)
                                                     name:YapDatabaseModifiedNotification
                                                   object:database];
    }
    return _uiDatabaseConnection;
}

- (OTRAttachmentPicker *)attachmentPicker
{
    if (!_attachmentPicker) {
        _attachmentPicker = [[OTRAttachmentPicker alloc] initWithRootViewController:self delegate:self];
    }
    return _attachmentPicker;
}

- (NSArray*) indexPathsToCount:(NSUInteger)count {
    NSMutableArray *indexPaths = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:i inSection:0];
        [indexPaths addObject:indexPath];
    }
    return indexPaths;
}

- (void)setBuddy:(OTRBuddy *)buddy
{
    OTRBuddy *originalBuddy = self.buddy;
    
    
    if ([originalBuddy.uniqueId isEqualToString:buddy.uniqueId]) {
        _buddy = buddy;
        
        //Update chatstate if it changed
        if (originalBuddy.chatState != self.buddy.chatState) {
            if (buddy.chatState == kOTRChatStateComposing || buddy.chatState == kOTRChatStatePaused) {
                self.showTypingIndicator = YES;
            }
            else {
                self.showTypingIndicator = NO;
            }
        }
        
        //Update title view if the status or username or display name have changed
        if (originalBuddy.status != self.buddy.status || ![originalBuddy.username isEqualToString:self.buddy.username] || ![originalBuddy.displayName isEqualToString:self.buddy.displayName]) {
            [self refreshTitleView];
        }
        
        
    } else {
        //different buddy
        [self saveCurrentMessageText];
        
        _buddy = buddy;
        if (self.buddy) {
            NSParameterAssert(self.buddy.uniqueId != nil);
            self.messageMappings = [[YapDatabaseViewMappings alloc] initWithGroups:@[self.buddy.uniqueId] view:OTRChatDatabaseViewExtensionName];
            self.buddyMappings = [[YapDatabaseViewMappings alloc] initWithGroups:@[self.buddy.uniqueId] view:OTRBuddyDatabaseViewExtensionName];
            self.inputToolbar.contentView.textView.text = self.buddy.composingMessageString;
            
            [self.uiDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
                self.account = [self.buddy accountWithTransaction:transaction];
                [self.messageMappings updateWithTransaction:transaction];
                [self.buddyMappings updateWithTransaction:transaction];
            }];
            
            if ([self.account isKindOfClass:[OTRXMPPAccount class]]) {
                self.xmppManager = (OTRXMPPManager *)[[OTRProtocolManager sharedInstance] protocolForAccount:self.account];
            }
        } else {
            self.messageMappings = nil;
            self.buddyMappings = nil;
            self.account = nil;
            self.xmppManager = nil;
        }
        [self refreshTitleView];
        [self.collectionView reloadData];
    }
}

- (void)refreshTitleView
{
    if ([self.buddy.displayName length]) {
        self.titleView.titleLabel.text = self.buddy.displayName;
    }
    else {
        self.titleView.titleLabel.text = self.buddy.username;
    }
    
    if([self.account.displayName length]) {
        self.titleView.subtitleLabel.text = self.account.displayName;
    }
    else {
        self.titleView.subtitleLabel.text = self.account.username;
    }
    
    //Create big circle and the imageview will resize it down
    if (!self.buddy) {
        self.titleView.titleImageView.image = nil;
    } else {
        self.titleView.titleImageView.image = [OTRImages circleWithRadius:50 lineWidth:0 lineColor:nil fillColor:[OTRColors colorWithStatus:self.buddy.status]];
    }
    
}

- (void)showMessageError:(NSError *)error
{
    if (error) {
        RIButtonItem *okButton = [RIButtonItem itemWithLabel:OK_STRING];
        
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:ERROR_STRING message:error.localizedDescription cancelButtonItem:okButton otherButtonItems:nil];
        
        [alertView show];
    }
}

#pragma - mark titleView Methods

- (void)didTapTitleView:(id)sender
{
#ifndef CHATSECURE_PUSH
    return;
#endif
    /*
     void (^showPushDropDown)(void) = ^void(void) {
     UIButton *requestPushTokenButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
     [requestPushTokenButton setTitle:@"Request" forState:UIControlStateNormal];
     [requestPushTokenButton addTarget:self action:@selector(requestPushToken:) forControlEvents:UIControlEventTouchUpInside];
     
     UIButton *revokePushTokenButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
     [revokePushTokenButton setTitle:@"Revoke" forState:UIControlStateNormal];
     [revokePushTokenButton addTarget:self action:@selector(revokePushToken:) forControlEvents:UIControlEventTouchUpInside];
     
     UIButton *sendPushTokenButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
     [sendPushTokenButton setTitle:@"Send" forState:UIControlStateNormal];
     [sendPushTokenButton addTarget:self action:@selector(sendPushToken:) forControlEvents:UIControlEventTouchUpInside];
     
     
     [self showDropdownWithTitle:@"Push Token Actions" buttons:@[requestPushTokenButton,revokePushTokenButton,sendPushTokenButton] animated:YES tag:OTRDropDownTypePush];
     };
     
     if (!self.buttonDropdownView) {
     showPushDropDown();
     }
     else {
     if (self.buttonDropdownView.tag == OTRDropDownTypePush) {
     [self hideDropdownAnimated:YES completion:nil];
     }
     else {
     [self hideDropdownAnimated:YES completion:showPushDropDown];
     }
     }
     */
}
#pragma - mark Push Methods

- (void)revokePushToken:(id)sender
{
    
}

- (void)requestPushToken:(id)sender
{
    
}

- (void)sendPushToken:(id)sender
{
    
}

#pragma - mark lockButton Methods

- (void)setupLockButton
{
    __weak OTRMessagesViewController *welf = self;
    self.lockButton = [OTRLockButton lockButtonWithInitailLockStatus:OTRLockStatusUnlocked withBlock:^(OTRLockStatus currentStatus) {
        
        void (^showEncryptionDropDown)(void) = ^void(void) {
            
            [[OTRKit sharedInstance] messageStateForUsername:welf.buddy.username accountName:welf.account.username protocol:welf.account.protocolTypeString completion:^(OTRKitMessageState messageState) {
                NSString *encryptionString = INITIATE_ENCRYPTED_CHAT_STRING;
                NSString *fingerprintString = VERIFY_STRING;
                NSArray * buttons = nil;
                
                if (messageState == OTRKitMessageStateEncrypted) {
                    encryptionString = CANCEL_ENCRYPTED_CHAT_STRING;
                }
                
                NSString * title = nil;
                if (currentStatus == OTRLockStatusLockedAndError) {
                    title = LOCKED_ERROR_STRING;
                }
                else if (currentStatus == OTRLockStatusLockedAndWarn) {
                    title = LOCKED_WARN_STRING;
                }
                else if (currentStatus == OTRLockStatusLockedAndVerified){
                    title = LOCKED_SECURE_STRING;
                }
                else if (currentStatus == OTRLockStatusUnlocked){
                    title = UNLOCKED_ALERT_STRING;
                }
                
                UIButton *encryptionButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
                [encryptionButton setTitle:encryptionString forState:UIControlStateNormal];
                [encryptionButton addTarget:self action:@selector(encryptionButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
                
                if (currentStatus == OTRLockStatusUnlocked || currentStatus == OTRLockStatusUnlocked) {
                    buttons = @[encryptionButton];
                }
                else {
                    UIButton *fingerprintButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
                    [fingerprintButton setTitle:fingerprintString forState:UIControlStateNormal];
                    [fingerprintButton addTarget:self action:@selector(verifyButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
                    buttons = @[encryptionButton,fingerprintButton];
                }
                
                [self showDropdownWithTitle:title buttons:buttons animated:YES tag:OTRDropDownTypeEncryption];
            }];
            
            
            
        };
        if (!self.buttonDropdownView) {
            showEncryptionDropDown();
        }
        else{
            if (self.buttonDropdownView.tag == OTRDropDownTypeEncryption) {
                [self hideDropdownAnimated:YES completion:nil];
            }
            else {
                [self hideDropdownAnimated:YES completion:showEncryptionDropDown];
            }
        }
        
        
    }];
    
    
    self.lockBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.lockButton];
    [self.navigationItem setRightBarButtonItem:self.lockBarButtonItem];
}

-(void)refreshLockButton
{
    [[OTRKit sharedInstance] checkIfGeneratingKeyForAccountName:self.account.username protocol:self.account.protocolTypeString completion:^(BOOL isGeneratingKey) {
        if( isGeneratingKey) {
            [self addLockSpinner];
        }
        else {
            UIBarButtonItem * rightBarItem = self.navigationItem.rightBarButtonItem;
            if ([rightBarItem isEqual:self.lockBarButtonItem]) {
                
                
                [[OTRKit sharedInstance] activeFingerprintIsVerifiedForUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString completion:^(BOOL isTrusted) {
                    
                    [[OTRKit sharedInstance] hasVerifiedFingerprintsForUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString completion:^(BOOL hasVerifiedFingerprints) {
                        
                        [[OTRKit sharedInstance] messageStateForUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString completion:^(OTRKitMessageState messageState) {
                            
                            
                            if (messageState == OTRKitMessageStateEncrypted && isTrusted) {
                                self.lockButton.lockStatus = OTRLockStatusLockedAndVerified;
                            }
                            else if (messageState == OTRKitMessageStateEncrypted && hasVerifiedFingerprints)
                            {
                                self.lockButton.lockStatus = OTRLockStatusLockedAndError;
                            }
                            else if (messageState == OTRKitMessageStateEncrypted) {
                                self.lockButton.lockStatus = OTRLockStatusLockedAndWarn;
                            }
                            else {
                                self.lockButton.lockStatus = OTRLockStatusUnlocked;
                            }
                            
                        }];
                        
                    }];
                    
                }];
            }
            
        }
        
    }];
}

-(void)addLockSpinner {
    UIActivityIndicatorView * activityIndicatorView = [[UIActivityIndicatorView alloc] initWithFrame:CGRectMake(0, 0, 25, 25)];
    activityIndicatorView.activityIndicatorViewStyle = UIActivityIndicatorViewStyleGray;
    [activityIndicatorView sizeToFit];
    [activityIndicatorView setAutoresizingMask:(UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin)];
    UIBarButtonItem * activityBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:activityIndicatorView];
    [activityIndicatorView startAnimating];
    self.navigationItem.rightBarButtonItem = activityBarButtonItem;
}
-(void)removeLockSpinner {
    self.navigationItem.rightBarButtonItem = self.lockBarButtonItem;
    [self refreshLockButton];
}

- (void)encryptionButtonPressed:(id)sender
{
    [self hideDropdownAnimated:YES completion:nil];
    
    
    [[OTRKit sharedInstance] messageStateForUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString completion:^(OTRKitMessageState messageState) {
        
        if (messageState == OTRKitMessageStateEncrypted) {
            [[OTRKit sharedInstance] disableEncryptionWithUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString];
        }
        else {
            [[OTRKit sharedInstance] initiateEncryptionWithUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString];
        }
        
        
    }];
}

- (void)verifyButtonPressed:(id)sender
{
    [self hideDropdownAnimated:YES completion:nil];
    
    [[OTRKit sharedInstance] fingerprintForAccountName:self.account.username protocol:self.account.protocolTypeString completion:^(NSString *ourFingerprintString) {
        
        [[OTRKit sharedInstance] activeFingerprintForUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString completion:^(NSString *theirFingerprintString) {
            
            [[OTRKit sharedInstance] activeFingerprintIsVerifiedForUsername:self.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString completion:^(BOOL verified) {
                
                
                UIAlertView * alert;
                __weak OTRMessagesViewController * welf = self;
                
                RIButtonItem * verifiedButtonItem = [RIButtonItem itemWithLabel:VERIFIED_STRING action:^{
                    [[OTRKit sharedInstance] setActiveFingerprintVerificationForUsername:welf.buddy.username accountName:welf.account.username protocol:self.account.protocolTypeString verified:YES completion:^{
                        [welf refreshLockButton];
                    }];
                }];
                
                RIButtonItem * notVerifiedButtonItem = [RIButtonItem itemWithLabel:NOT_VERIFIED_STRING action:^{
                    
                    [[OTRKit sharedInstance] setActiveFingerprintVerificationForUsername:welf.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString verified:NO completion:^{
                        [welf refreshLockButton];
                    }];
                }];
                
                RIButtonItem * verifyLaterButtonItem = [RIButtonItem itemWithLabel:VERIFY_LATER_STRING action:^{
                    [[OTRKit sharedInstance] setActiveFingerprintVerificationForUsername:welf.buddy.username accountName:self.account.username protocol:self.account.protocolTypeString verified:NO completion:^{
                        [welf refreshLockButton];
                    }];
                }];
                
                if(ourFingerprintString && theirFingerprintString) {
                    NSString *msg = [NSString stringWithFormat:@"%@, %@:\n%@\n\n%@ %@:\n%@\n", YOUR_FINGERPRINT_STRING, self.account.username, ourFingerprintString, THEIR_FINGERPRINT_STRING, self.buddy.username, theirFingerprintString];
                    if(verified)
                    {
                        alert = [[UIAlertView alloc] initWithTitle:VERIFY_FINGERPRINT_STRING message:msg cancelButtonItem:verifiedButtonItem otherButtonItems:notVerifiedButtonItem, nil];
                    }
                    else
                    {
                        alert = [[UIAlertView alloc] initWithTitle:VERIFY_FINGERPRINT_STRING message:msg cancelButtonItem:verifyLaterButtonItem otherButtonItems:verifiedButtonItem, nil];
                    }
                } else {
                    NSString *msg = SECURE_CONVERSATION_STRING;
                    alert = [[UIAlertView alloc] initWithTitle:nil message:msg delegate:nil cancelButtonTitle:nil otherButtonTitles:OK_STRING, nil];
                }
                
                [alert show];
            }];
        }];
    }];
}

- (void)connectButtonPressed:(id)sender
{
    [self hideDropdownAnimated:YES completion:nil];
    
    //If we have the password then we can login with that password otherwise show login UI to enter password
    if ([self.account.password length]) {
        [[OTRProtocolManager sharedInstance] loginAccount:self.account userInitiated:YES];
        
    } else {
        [OTRLoginViewController showLoginViewControllerWithAccount:self.account fromViewController:self completion:nil];
    }
    
    
}

#pragma - mark  dropDown Methods

- (void)showDropdownWithTitle:(NSString *)title buttons:(NSArray *)buttons animated:(BOOL)animated tag:(NSInteger)tag
{
    NSTimeInterval duration = 0.3;
    if (!animated) {
        duration = 0.0;
    }
    
    self.buttonDropdownView = [[OTRButtonView alloc] initWithTitle:title buttons:buttons];
    self.buttonDropdownView.tag = tag;
    
    CGFloat height = [OTRButtonView heightForTitle:title width:self.view.bounds.size.width buttons:buttons];
    
    self.buttonDropdownView.frame = CGRectMake(0, self.navigationController.navigationBar.frame.size.height+self.navigationController.navigationBar.frame.origin.y-height, self.view.bounds.size.width, height);
    
    [self.view addSubview:self.buttonDropdownView];
    
    [UIView animateWithDuration:duration animations:^{
        CGRect frame = self.buttonDropdownView.frame;
        frame.origin.y = self.navigationController.navigationBar.frame.size.height+self.navigationController.navigationBar.frame.origin.y;
        self.buttonDropdownView.frame = frame;
    } completion:nil];
    
}

- (void)hideDropdownAnimated:(BOOL)animated completion:(void (^)(void))completion
{
    if (!self.buttonDropdownView) {
        if (completion) {
            completion();
        }
    }
    else {
        NSTimeInterval duration = 0.3;
        if (!animated) {
            duration = 0.0;
        }
        
        [UIView animateWithDuration:duration animations:^{
            CGRect frame = self.buttonDropdownView.frame;
            CGFloat navBarBottom = self.navigationController.navigationBar.frame.size.height+self.navigationController.navigationBar.frame.origin.y;
            frame.origin.y = navBarBottom - frame.size.height;
            self.buttonDropdownView.frame = frame;
            
        } completion:^(BOOL finished) {
            if (finished) {
                [self.buttonDropdownView removeFromSuperview];
                self.buttonDropdownView = nil;
            }
            
            if (completion) {
                completion();
            }
        }];
    }
}

- (void)saveCurrentMessageText
{
    if (!self.buddy) {
        return;
    }
    self.buddy.composingMessageString = self.inputToolbar.contentView.textView.text;
    __block OTRBuddy *buddy = [self.buddy copy];
    [[OTRDatabaseManager sharedInstance].readWriteDatabaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [buddy saveWithTransaction:transaction];
    }];
    
    if (![self.buddy.composingMessageString length]) {
        [self.xmppManager sendChatState:kOTRChatStateInactive withBuddyID:self.buddy.uniqueId];
    }
    
}

- (OTRMessage *)messageAtIndexPath:(NSIndexPath *)indexPath
{
    __block OTRMessage *message = nil;
    [self.uiDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        YapDatabaseViewTransaction *viewTransaction = [transaction ext:OTRChatDatabaseViewExtensionName];
        NSParameterAssert(viewTransaction != nil);
        NSParameterAssert(self.messageMappings != nil);
        NSParameterAssert(indexPath != nil);
        NSUInteger row = indexPath.row;
        NSUInteger section = indexPath.section;
        
        NSAssert(row < [self.messageMappings numberOfItemsInSection:section], @"Cannot fetch message because row %d is >= numberOfItemsInSection %d", (int)row, (int)[self.messageMappings numberOfItemsInSection:section]);
        
        message = [viewTransaction objectAtRow:row inSection:section withMappings:self.messageMappings];
        NSParameterAssert(message != nil);
    }];
    return message;
}

- (BOOL)showDateAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL showDate = NO;
    if (indexPath.row == 0) {
        showDate = YES;
    }
    else {
        OTRMessage *currentMessage = [self messageAtIndexPath:indexPath];
        OTRMessage *previousMessage = [self messageAtIndexPath:[NSIndexPath indexPathForItem:indexPath.row-1 inSection:indexPath.section]];
        
        NSTimeInterval timeDifference = [currentMessage.date timeIntervalSinceDate:previousMessage.date];
        if (timeDifference > kOTRMessageSentDateShowTimeInterval) {
            showDate = YES;
        }
    }
    return showDate;
}

- (void)textViewDidChangeNotifcation:(NSNotification *)notification
{
    JSQMessagesComposerTextView *textView = notification.object;
    if ([textView.text length]) {
        //typing
        [self.xmppManager sendChatState:kOTRChatStateComposing withBuddyID:self.buddy.uniqueId];
    }
    else {
        [self.xmppManager sendChatState:kOTRChatStateActive withBuddyID:self.buddy.uniqueId];
        //done typing
    }
}

#pragma mark - JSQMessagesViewController method overrides

- (UICollectionViewCell *)collectionView:(JSQMessagesCollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    JSQMessagesCollectionViewCell *cell = (JSQMessagesCollectionViewCell *)[super collectionView:collectionView cellForItemAtIndexPath:indexPath];
    
    OTRMessage *message = [self messageAtIndexPath:indexPath];
    
    if (message.isIncoming) {
        cell.textView.textColor = [UIColor blackColor];
    }
    else {
        cell.textView.textColor = [UIColor whiteColor];
    }
    
    return cell;
}

- (BOOL)collectionView:(UICollectionView *)collectionView canPerformAction:(SEL)action forItemAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender
{
    if (action == @selector(delete:)) {
        return YES;
    }
    
    return [super collectionView:collectionView canPerformAction:action forItemAtIndexPath:indexPath withSender:sender];
}

- (void)didPressSendButton:(UIButton *)button withMessageText:(NSString *)text senderId:(NSString *)senderId senderDisplayName:(NSString *)senderDisplayName date:(NSDate *)date
{
    
    OTRMessage *message = [[OTRMessage alloc] init];
    message.buddyUniqueId = self.buddy.uniqueId;
    message.text = text;
    message.read = YES;
    message.transportedSecurely = NO;
    
    [[OTRDatabaseManager sharedInstance].readWriteDatabaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [message saveWithTransaction:transaction];
        self.buddy.lastMessageDate = message.date;
        [self.buddy saveWithTransaction:transaction];
    } completionBlock:^{
        
        [[OTRProtocolManager sharedInstance] sendMessage:message];
        
    }];
    //Reset text because of added whitespace
    NSString *currentText = self.inputToolbar.contentView.textView.text;
    self.inputToolbar.contentView.textView.text = [currentText substringToIndex:[currentText length]-1];
    
}

- (void)didPressAccessoryButton:(UIButton *)sender
{
    [self.attachmentPicker showAlertControllerWithCompletion:nil];
}

- (void)collectionView:(UICollectionView *)collectionView performAction:(SEL)action forItemAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender
{
    if (action == @selector(delete:)) {
        [self deleteMessageAtIndexPath:indexPath];
    }
    else {
        [super collectionView:collectionView performAction:action forItemAtIndexPath:indexPath withSender:sender];
    }
}

#pragma - mark OTRAttachmentPickerDelegate Methods

- (void)attachmentPicker:(OTRAttachmentPicker *)attachmentPicker gotPhoto:(UIImage *)photo withInfo:(NSDictionary *)info
{
    
}

#pragma - mark UIScrollViewDelegate Methods

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self hideDropdownAnimated:YES completion:nil];
}

#pragma mark - UICollectionView DataSource
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    NSInteger numberOfMessages = [self.messageMappings numberOfItemsInSection:section];
    return numberOfMessages;
}

#pragma - mark JSQMessagesCollectionViewDataSource Methods

- (NSString *)senderDisplayName
{
    if ([self.account.displayName length]) {
        return self.account.displayName;
    }
    return self.account.username;
}

- (NSString *)senderId
{
    return self.account.uniqueId;
}

- (id<JSQMessageData>)collectionView:(JSQMessagesCollectionView *)collectionView messageDataForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return [self messageAtIndexPath:indexPath];
}

- (id<JSQMessageBubbleImageDataSource>)collectionView:(JSQMessagesCollectionView *)collectionView messageBubbleImageDataForItemAtIndexPath:(NSIndexPath *)indexPath
{
    OTRMessage *message = [self messageAtIndexPath:indexPath];
    JSQMessagesBubbleImage *image = nil;
    if (message.isIncoming) {
        image = self.incomingBubbleImage;
    }
    else {
        image = self.outgoingBubbleImage;
    }
    return image;
}

- (id <JSQMessageAvatarImageDataSource>)collectionView:(JSQMessagesCollectionView *)collectionView avatarImageDataForItemAtIndexPath:(NSIndexPath *)indexPath
{
    OTRMessage *message = [self messageAtIndexPath:indexPath];
    UIImage *avatarImage = nil;
    if (message.error) {
        avatarImage = [OTRImages circleWarningWithColor:[OTRColors warnColor]];
    }
    else if (message.isIncoming) {
        avatarImage = [self.buddy avatarImage];
    }
    else {
        avatarImage = [self.account avatarImage];
    }
    
    if (avatarImage) {
        NSUInteger diameter = MIN(avatarImage.size.width, avatarImage.size.height);
        return [JSQMessagesAvatarImageFactory avatarImageWithImage:avatarImage diameter:diameter];
    }
    return nil;
}

////// Optional //////

- (NSAttributedString *)collectionView:(JSQMessagesCollectionView *)collectionView attributedTextForCellTopLabelAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self showDateAtIndexPath:indexPath]) {
        OTRMessage *message = [self messageAtIndexPath:indexPath];
        return [[JSQMessagesTimestampFormatter sharedFormatter] attributedTimestampForDate:message.date];
    }
    return nil;
}


- (NSAttributedString *)collectionView:(JSQMessagesCollectionView *)collectionView attributedTextForMessageBubbleTopLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}


- (NSAttributedString *)collectionView:(JSQMessagesCollectionView *)collectionView attributedTextForCellBottomLabelAtIndexPath:(NSIndexPath *)indexPath
{
    OTRMessage *message = [self messageAtIndexPath:indexPath];
    
    UIFont *font = [UIFont fontWithName:kFontAwesomeFont size:12];
    NSDictionary *iconAttributes = @{NSFontAttributeName: font};
    
    NSString *lockString = nil;
    if (message.transportedSecurely) {
        lockString = [NSString stringWithFormat:@"%@ ",[NSString fa_stringForFontAwesomeIcon:FALock]];
    }
    else {
        lockString = [NSString fa_stringForFontAwesomeIcon:FAUnlock];
    }
    
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:lockString attributes:iconAttributes];
    
    
    if (message.isDelivered) {
        NSString *iconString = [NSString stringWithFormat:@"%@ ",[NSString fa_stringForFontAwesomeIcon:FACheck]];
        
        [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:iconString attributes:iconAttributes]];
    }
    
    return attributedString;
}


#pragma - mark  JSQMessagesCollectionViewDelegateFlowLayout Methods

- (CGFloat)collectionView:(JSQMessagesCollectionView *)collectionView
                   layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout
heightForCellTopLabelAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self showDateAtIndexPath:indexPath]) {
        return kJSQMessagesCollectionViewCellLabelHeightDefault;
    }
    return 0.0f;
}

- (CGFloat)collectionView:(JSQMessagesCollectionView *)collectionView
                   layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout
heightForCellBottomLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return kJSQMessagesCollectionViewCellLabelHeightDefault;
}

- (void)deleteMessageAtIndexPath:(NSIndexPath *)indexPath
{
    __block OTRMessage *message = [self messageAtIndexPath:indexPath];
    [[OTRDatabaseManager sharedInstance].readWriteDatabaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [message removeWithTransaction:transaction];
        //Update Last message date for sorting and grouping
        [self.buddy updateLastMessageDateWithTransaction:transaction];
        [self.buddy saveWithTransaction:transaction];
    }];
}

- (void)collectionView:(JSQMessagesCollectionView *)collectionView didTapAvatarImageView:(UIImageView *)avatarImageView atIndexPath:(NSIndexPath *)indexPath
{
    OTRMessage *message = [self messageAtIndexPath:indexPath];
    if (message.error) {
        [self showMessageError:message.error];
    }
}

#pragma mark - YapDatabaseNotificatino Method

- (void)yapDatabaseModified:(NSNotification *)notification
{
    // Process the notification(s),
    // and get the change-set(s) as applies to my view and mappings configuration.
    NSArray *notifications = [self.uiDatabaseConnection beginLongLivedReadTransaction];
    
    NSArray *messageRowChanges = nil;
    
    [[self.uiDatabaseConnection ext:OTRChatDatabaseViewExtensionName] getSectionChanges:nil
                                                                             rowChanges:&messageRowChanges
                                                                       forNotifications:notifications
                                                                           withMappings:self.messageMappings];
    
    NSArray *buddyRowChanges = nil;
    [[self.uiDatabaseConnection ext:OTRBuddyDatabaseViewExtensionName] getSectionChanges:nil
                                                                              rowChanges:&buddyRowChanges
                                                                        forNotifications:notifications
                                                                            withMappings:self.buddyMappings];
    
    for (YapDatabaseViewRowChange *rowChange in buddyRowChanges)
    {
        if (rowChange.type == YapDatabaseViewChangeUpdate) {
            __block OTRBuddy *updatedBuddy = nil;
            [self.uiDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
                updatedBuddy = [[transaction ext:OTRBuddyDatabaseViewExtensionName] objectAtIndexPath:rowChange.indexPath withMappings:self.buddyMappings];
            }];
            
            self.buddy = updatedBuddy;
        }
    }
    
    
    [self.collectionView reloadData];
    
    if (messageRowChanges.count && [self.collectionView numberOfItemsInSection:0] != 0) {
        NSUInteger lastMessageIndex = [self.collectionView numberOfItemsInSection:0] - 1;
        NSIndexPath *lastMessageIndexPath = [NSIndexPath indexPathForRow:lastMessageIndex inSection:0];
        OTRMessage *mostRecentMessage = [self messageAtIndexPath:lastMessageIndexPath];
        if (mostRecentMessage.isIncoming) {
            [JSQSystemSoundPlayer jsq_playMessageReceivedSound];
            [self finishReceivingMessage];
        } else {
            [self finishSendingMessage];
        }
    }
}

#pragma mark UISplitViewControllerDelegate methods

- (void) splitViewController:(UISplitViewController *)svc willHideViewController:(UIViewController *)aViewController withBarButtonItem:(UIBarButtonItem *)barButtonItem forPopoverController:(UIPopoverController *)pc {
    barButtonItem.title = aViewController.title;
    self.navigationItem.leftBarButtonItem = barButtonItem;
}

- (void) splitViewController:(UISplitViewController *)svc willShowViewController:(UIViewController *)aViewController invalidatingBarButtonItem:(UIBarButtonItem *)barButtonItem {
    self.navigationItem.leftBarButtonItem = nil;
}

#pragma - mark UITextViewDelegateMethods

- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL inRange:(NSRange)characterRange
{
    UIActivityViewController *activityViewController = [UIActivityViewController otr_linkActivityViewControllerWithURLs:@[URL]];
    
    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"8.0")) {
        activityViewController.popoverPresentationController.sourceView = textView;
        activityViewController.popoverPresentationController.sourceRect = textView.bounds;
    }
    
    [self presentViewController:activityViewController animated:YES completion:nil];
    return NO;
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField{
    return NO;
}

@end
