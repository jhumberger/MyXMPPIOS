#import "OTRAppDelegate.h"


#import "OTRConversationViewController.h"

#import "OTRMessagesViewController.h"
#import "Strings.h"
#import "OTRSettingsViewController.h"
#import "OTRSettingsManager.h"
#import "ZeroPush.h"

#import "Appirater.h"
#import "OTRConstants.h"
#import "OTRLanguageManager.h"
#import "OTRUtilities.h"
#import "OTRAccountsManager.h"
#import "FacebookSDK.h"
//#import "OTRAppVersionManager.h"
#import "OTRSettingsManager.h"
#import "OTRSecrets.h"
#import "OTRDatabaseManager.h"
#import "SSKeychain.h"

#import "OTRLog.h"
#import "DDTTYLogger.h"
#import "OTRAccount.h"
#import "OTRBuddy.h"
#import "YAPDatabaseTransaction.h"
#import "YapDatabaseConnection.h"
#import "OTRCertificatePinning.h"
#import "NSData+XMPP.h"
#import "NSURL+ChatSecure.h"
#import "OTRDatabaseUnlockViewController.h"
#import "OTRMessage.h"
#import "OTRPasswordGenerator.h"
#import "UIViewController+ChatSecure.h"
#import "OTRNotificationController.h"
static NSString *const ZeroPushAPIURLHost = @"https://api.zeropush.com";
static NSString *const ZeroPushClientVersion = @"ZeroPush-iOS/2.0.4";
#if CHATSECURE_DEMO
#import "OTRChatDemo.h"

#endif

@implementation OTRAppDelegate

@synthesize window = _window;
@synthesize backgroundTask, backgroundTimer, didShowDisconnectionWarning;
@synthesize settingsViewController;




- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    
#ifdef __IPHONE_8_0
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(registerUserNotificationSettings:)]) {
        UIUserNotificationSettings* notificationSettings = [UIUserNotificationSettings settingsForTypes:(UIUserNotificationTypeAlert | UIUserNotificationTypeBadge | UIUserNotificationTypeSound) categories:nil];
        [[UIApplication sharedApplication] registerUserNotificationSettings:notificationSettings];
        [[UIApplication sharedApplication] registerForRemoteNotifications];
    } else {
        [[UIApplication sharedApplication] registerForRemoteNotificationTypes: (UIRemoteNotificationTypeBadge | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeAlert)];
    }
#else
    [[UIApplication sharedApplication] registerForRemoteNotificationTypes: (UIRemoteNotificationTypeBadge | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeAlert)];
#endif
    [ZeroPush engageWithAPIKey:@"iosprod_XXY5dqqZsLjdxPspZ3vp" delegate:self];
    
    //now ask the user if they want to recieve push notifications. You can place this in another part of your app.
    [[ZeroPush shared] registerForRemoteNotifications];
    /*
     Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
     */
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
    
    [[BITHockeyManager sharedHockeyManager] configureWithBetaIdentifier:kOTRHockeyBetaIdentifier
                                                         liveIdentifier:kOTRHockeyLiveIdentifier
                                                               delegate:self];
    [[BITHockeyManager sharedHockeyManager].authenticator setIdentificationType:BITAuthenticatorIdentificationTypeDevice];
    [[BITHockeyManager sharedHockeyManager] startManager];
#ifndef DEBUG
    [[BITHockeyManager sharedHockeyManager].authenticator authenticateInstallation];
#endif
    
    [OTRCertificatePinning loadBundledCertificatesToKeychain];
    
    [SSKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly];
    
    UIViewController *rootViewController = nil;
    
    self.settingsViewController = [[OTRSettingsViewController alloc] init];
    self.conversationViewController = [[OTRConversationViewController alloc] init];
    self.messagesViewController = [OTRMessagesViewController messagesViewController];
    
    if ([OTRDatabaseManager existsYapDatabase] && ![[OTRDatabaseManager sharedInstance] hasPassphrase]) {
        // user needs to enter password for current database
        rootViewController = [[OTRDatabaseUnlockViewController alloc] init];
    } else {
        ////// Normal launch to conversationViewController //////
        if (![OTRDatabaseManager existsYapDatabase]) {
            /**
             First Launch
             Create password and save to keychain
             **/
            NSString *newPassword = [OTRPasswordGenerator passwordWithLength:OTRDefaultPasswordLength];
            NSError *error = nil;
            [[OTRDatabaseManager sharedInstance] setDatabasePassphrase:newPassword remember:YES error:&error];
            if (error) {
                DDLogError(@"Password Error: %@",error);
            }
        }
        
        [[OTRDatabaseManager sharedInstance] setupDatabaseWithName:OTRYapDatabaseName];
        rootViewController = [self defaultConversationNavigationController];
        
        
#if CHATSECURE_DEMO
        [self performSelector:@selector(loadDemoData) withObject:nil afterDelay:0.0];
#endif
    }
    
    
    
    
    //rootViewController = [[OTRDatabaseUnlockViewController alloc] init];
    //    NSString *outputStoreName = @"ChatSecure.sqlite";
    //    [[OTRDatabaseManager sharedInstance] setupDatabaseWithName:outputStoreName];
    //
    //    [[OTRDatabaseManager sharedInstance].readWriteDatabaseConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
    //        NSArray *allAccounts = [OTRAccount allAccountsWithTransaction:transaction];
    //        NSArray *allAccountsToDelete = [allAccounts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
    //            if ([evaluatedObject isKindOfClass:[OTRAccount class]]) {
    //                OTRAccount *account = (OTRAccount *)evaluatedObject;
    //                if (![account.username length]) {
    //                    return YES;
    //                }
    //            }
    //            return NO;
    //        }]];
    //
    //        [transaction removeObjectsForKeys:[allAccountsToDelete valueForKey:OTRYapDatabaseObjectAttributes.uniqueId] inCollection:[OTRAccount collection]];
    //        //FIXME? [OTRManagedAccount resetAccountsConnectionStatus];
    //    }];
    
    
    
    
    //[OTRAppVersionManager applyAppUpdatesForCurrentAppVersion];
    
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    
    
    self.window.rootViewController = rootViewController;
    [self.window makeKeyAndVisible];
    
    application.applicationIconBadgeNumber = 0;
    
    OTRNotificationController *notificationController = [OTRNotificationController sharedInstance];
    [notificationController start];
    
    [Appirater setAppId:@"464200063"];
    [Appirater setOpenInAppStore:NO];
    [Appirater appLaunched:YES];
    
    [self autoLogin];
    
    return YES;
}

- (void) loadDemoData {
#if CHATSECURE_DEMO
    [OTRChatDemo loadDemoChatInDatabase];
#endif
}

- (UIViewController*)defaultConversationNavigationController
{
    UIViewController *viewController = nil;
    
    //ConversationViewController Nav
    UINavigationController *conversationListNavController = [[UINavigationController alloc] initWithRootViewController:self.conversationViewController];
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        viewController = conversationListNavController;
    } else {
        //MessagesViewController Nav
        UINavigationController *messagesNavController = [[UINavigationController alloc ]initWithRootViewController:self.messagesViewController];
        
        //SplitViewController
        UISplitViewController *splitViewController = [[UISplitViewController alloc] init];
        splitViewController.viewControllers = [NSArray arrayWithObjects:conversationListNavController, messagesNavController, nil];
        splitViewController.delegate = self.messagesViewController;
        splitViewController.title = CHAT_STRING;
        
        viewController = splitViewController;
        
    }
    
    return viewController;
}

- (void)showConversationViewController
{
    self.window.rootViewController = [self defaultConversationNavigationController];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    /*
     Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
     Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
     */
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    DDLogInfo(@"Application entered background state.");
    NSAssert(self.backgroundTask == UIBackgroundTaskInvalid, nil);
    
    [[OTRDatabaseManager sharedInstance].readOnlyDatabaseConnection asyncReadWithBlock:^(YapDatabaseReadTransaction *transaction) {
        application.applicationIconBadgeNumber = [OTRMessage numberOfUnreadMessagesWithTransaction:transaction];
    }];
    
    self.didShowDisconnectionWarning = NO;
    
    self.backgroundTask = [application beginBackgroundTaskWithExpirationHandler: ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            DDLogInfo(@"Background task expired");
            if (self.backgroundTimer)
            {
                [self.backgroundTimer invalidate];
                self.backgroundTimer = nil;
            }
            [application endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        });
    }];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.backgroundTimer = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(timerUpdate:) userInfo:nil repeats:YES];
    });
}

- (void) timerUpdate:(NSTimer*)timer {
    UIApplication *application = [UIApplication sharedApplication];
    
    DDLogInfo(@"Timer update, background time left: %f", application.backgroundTimeRemaining);
    
    if ([application backgroundTimeRemaining] < 60 && !self.didShowDisconnectionWarning && [OTRSettingsManager boolForOTRSettingKey:kOTRSettingKeyShowDisconnectionWarning])
    {
        UILocalNotification *localNotif = [[UILocalNotification alloc] init];
        if (localNotif) {
            localNotif.alertBody = EXPIRATION_STRING;
            localNotif.alertAction = OK_STRING;
            localNotif.soundName = UILocalNotificationDefaultSoundName;
            [application presentLocalNotificationNow:localNotif];
        }
        self.didShowDisconnectionWarning = YES;
    }
    if ([application backgroundTimeRemaining] < 10)
    {
        // Clean up here
        [self.backgroundTimer invalidate];
        self.backgroundTimer = nil;
        
        [[OTRProtocolManager sharedInstance] disconnectAllAccounts];
        //FIXME [OTRManagedAccount resetAccountsConnectionStatus];
        
        
        [application endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
}

- (void)autoLogin
{
    //Auto Login
    if (![BITHockeyManager sharedHockeyManager].crashManager.didCrashInLastSession) {
        [[OTRProtocolManager sharedInstance] loginAccounts:[OTRAccountsManager allAutoLoginAccounts]];
    }
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [Appirater appEnteredForeground:YES];
    [self autoLogin];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    [ZeroPush engageWithAPIKey:@"iosprod_XXY5dqqZsLjdxPspZ3vp" delegate:self];
    [[ZeroPush shared] registerForRemoteNotifications];
    
    /*
     Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
     */
    
    DDLogInfo(@"Application became active");
    
    if (self.backgroundTimer)
    {
        [self.backgroundTimer invalidate];
        self.backgroundTimer = nil;
    }
    if (self.backgroundTask != UIBackgroundTaskInvalid)
    {
        [application endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
    //FIXME? [OTRManagedAccount resetAccountsConnectionStatus];
    application.applicationIconBadgeNumber = 0;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    /*
     Called when the application is about to terminate.
     Save data if appropriate.
     See also applicationDidEnterBackground:.
     */
    
    
    [[OTRProtocolManager sharedInstance] disconnectAllAccounts];
    
    //FIXME? [OTRManagedAccount resetAccountsConnectionStatus];
    //[OTRUtilities deleteAllBuddiesAndMessages];
}
/*
 // Optional UITabBarControllerDelegate method.
 - (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController
 {
 }
 */

/*
 // Optional UITabBarControllerDelegate method.
 - (void)tabBarController:(UITabBarController *)tabBarController didEndCustomizingViewControllers:(NSArray *)viewControllers changed:(BOOL)changed
 {
 }
 */

- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification {
    
    NSDictionary *userInfo = notification.userInfo;
    NSString *buddyUniqueId = userInfo[kOTRNotificationBuddyUniqueIdKey];
    
    if([buddyUniqueId length]) {
        __block OTRBuddy *buddy = nil;
        [[OTRDatabaseManager sharedInstance].readWriteDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            buddy = [OTRBuddy fetchObjectWithUniqueID:buddyUniqueId transaction:transaction];
        }];
        
        if (!([self.messagesViewController otr_isVisible] || [self.conversationViewController otr_isVisible])) {
            self.window.rootViewController = [self defaultConversationNavigationController];
        }
        
        [self.conversationViewController enterConversationWithBuddy:buddy];
    }
    
    
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    if( [[BITHockeyManager sharedHockeyManager].authenticator handleOpenURL:url
                                                          sourceApplication:sourceApplication
                                                                 annotation:annotation]) {
        return YES;
    } else if ([url otr_isFacebookCallBackURL]) {
        return [[FBSession activeSession] handleOpenURL:url];
    }
    return NO;
}

// Delegation methods
- (void)application:(UIApplication *)app didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)devToken
{
    [[ZeroPush shared] registerDeviceToken:devToken];
     NSString *tokenString = [ZeroPush deviceTokenFromData:devToken];
     NSLog(@"%@", tokenString);
    [[ZeroPush shared] subscribeToChannel:@"joe"];
}


- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    NSLog(@"%@", [error description]);
    //Common reason for errors:
    //  1.) Simulator does not support receiving push notifications
    //  2.) User rejected push alert
    //  3.) "no valid 'aps-environment' entitlement string found for application"
    //      This means your provisioning profile does not have Push Notifications configured. https://zeropush.com/documentation/generating_certificates
}

#pragma - mark Class Methods
+ (OTRAppDelegate *)appDelegate
{
    return (OTRAppDelegate *)[[UIApplication sharedApplication] delegate];
}

@end