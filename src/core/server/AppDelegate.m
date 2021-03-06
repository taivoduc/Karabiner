#import <Carbon/Carbon.h>
#import "AppDelegate.h"
#import "ClientForKernelspace.h"
#import "KarabinerKeys.h"
#import "KextLoader.h"
#import "MigrationUtilities.h"
#import "NotificationKeys.h"
#import "PreferencesController.h"
#import "PreferencesKeys.h"
#import "PreferencesManager.h"
#import "Relauncher.h"
#import "ServerForUserspace.h"
#import "StartAtLoginUtilities.h"
#import "StatusBar.h"
#import "StatusWindow.h"
#import "Updater.h"
#import "WorkSpaceData.h"
#include <stdlib.h>

@interface AppDelegate () {
  NSDictionary* focusedUIElementInformation_;
  NSMutableDictionary* inputSourceInformation_;

  // for IONotification
  IONotificationPortRef notifyport_;
  CFRunLoopSourceRef loopsource_;

  dispatch_queue_t axnotifierManagerQueue_;

  struct BridgeWorkSpaceData bridgeworkspacedata_;
}
@end

@implementation AppDelegate

@synthesize clientForKernelspace;

// ----------------------------------------
- (void)send_workspacedata_to_kext {
  [clientForKernelspace send_workspacedata_to_kext:&bridgeworkspacedata_];
}

// ------------------------------------------------------------
- (void)distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    [WorkSpaceData refreshEnabledInputSources];
  });
}

- (void)distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    InputSource* inputSource = [WorkSpaceData getCurrentInputSource];
    [workSpaceData_ getInputSourceID:inputSource
                  output_inputSource:(&(bridgeworkspacedata_.inputsource))
            output_inputSourceDetail:(&(bridgeworkspacedata_.inputsourcedetail))];
    [self send_workspacedata_to_kext];

    @synchronized(self) {
      inputSourceInformation_ = [NSMutableDictionary new];
      inputSourceInformation_[@"mtime"] = @((NSUInteger)([[NSDate date] timeIntervalSince1970] * 1000));

      if ([inputSource languagecode]) {
        inputSourceInformation_[@"languageCode"] = [inputSource languagecode];
      }
      if ([inputSource inputSourceID]) {
        inputSourceInformation_[@"inputSourceID"] = [inputSource inputSourceID];
      }
      if ([inputSource inputModeID]) {
        inputSourceInformation_[@"inputModeID"] = [inputSource inputModeID];
      }
    }
  });
}

- (void)observer_ConfigXMLReloaded:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    // If <appdef> or <inputsourcedef> is updated,
    // the following values might be changed.
    // Therefore, we need to resend values to kext.
    //
    // - bridgeworkspacedata_.applicationtype
    // - bridgeworkspacedata_.windowname
    // - bridgeworkspacedata_.uielementrole
    // - bridgeworkspacedata_.inputsource
    // - bridgeworkspacedata_.inputsourcedetail

    [self updateFocusedUIElementInformation:nil];
    [self distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:nil];
    [self distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:nil];
  });
}

// ------------------------------------------------------------
- (void)callClearNotSave {
  if (![preferencesManager_ value:@"general.keep_notsave_at_wake"]) {
    // disable notsave.* in order to disable "Browsing Mode" and
    // other modes which overwrite some keys
    // because these modes annoy password input.
    [preferencesManager_ clearNotSave];
  }
}

- (void)observer_NSWorkspaceDidWakeNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_NSWorkspaceDidWakeNotification");
    [self callClearNotSave];
  });
}

- (void)observer_NSWorkspaceScreensDidWakeNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_NSWorkspaceScreensDidWakeNotification");
    [self callClearNotSave];
  });
}

- (void)registerWakeNotification {
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceDidWakeNotification:)
                                                             name:NSWorkspaceDidWakeNotification
                                                           object:nil];
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceScreensDidWakeNotification:)
                                                             name:NSWorkspaceScreensDidWakeNotification
                                                           object:nil];
}

- (void)unregisterWakeNotification {
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                name:NSWorkspaceDidWakeNotification
                                                              object:nil];
  [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                name:NSWorkspaceScreensDidWakeNotification
                                                              object:nil];
}

// ------------------------------------------------------------
static void observer_IONotification(void* refcon, io_iterator_t iterator) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_IONotification");

    AppDelegate* self = (__bridge AppDelegate*)(refcon);
    if (! self) {
      NSLog(@"[ERROR] observer_IONotification refcon == nil\n");
      return;
    }

    for (;;) {
      io_object_t obj = IOIteratorNext(iterator);
      if (! obj) break;

      IOObjectRelease(obj);
    }
    // Do not release iterator.

    // = Documentation of IOKit =
    // - Introduction to Accessing Hardware From Applications
    //   - Finding and Accessing Devices
    //
    // In the case of IOServiceAddMatchingNotification, make sure you release the iterator only if you’re also ready to stop receiving notifications:
    // When you release the iterator you receive from IOServiceAddMatchingNotification, you also disable the notification.

    // ------------------------------------------------------------
    [[self clientForKernelspace] refresh_connection_with_retry];
    [self send_workspacedata_to_kext];
  });
}

- (void)unregisterIONotification {
  if (notifyport_) {
    if (loopsource_) {
      CFRunLoopSourceInvalidate(loopsource_);
      loopsource_ = nil;
    }
    IONotificationPortDestroy(notifyport_);
    notifyport_ = nil;
  }
}

- (void)registerIONotification {
  [self unregisterIONotification];

  notifyport_ = IONotificationPortCreate(kIOMasterPortDefault);
  if (!notifyport_) {
    NSLog(@"[ERROR] IONotificationPortCreate failed\n");
    return;
  }

  // ----------------------------------------------------------------------
  io_iterator_t it;
  kern_return_t kernResult;

  [KextLoader load]; // Load kext before use org_pqrs_driver_Karabiner

  kernResult = IOServiceAddMatchingNotification(notifyport_,
                                                kIOMatchedNotification,
                                                IOServiceNameMatching("org_pqrs_driver_Karabiner"),
                                                &observer_IONotification,
                                                (__bridge void*)(self),
                                                &it);
  if (kernResult != kIOReturnSuccess) {
    NSLog(@"[ERROR] IOServiceAddMatchingNotification failed");
    return;
  }
  observer_IONotification((__bridge void*)(self), it);

  // ----------------------------------------------------------------------
  loopsource_ = IONotificationPortGetRunLoopSource(notifyport_);
  if (!loopsource_) {
    NSLog(@"[ERROR] IONotificationPortGetRunLoopSource failed");
    return;
  }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), loopsource_, kCFRunLoopDefaultMode);
}

// ------------------------------------------------------------
- (void)observer_NSWorkspaceSessionDidBecomeActiveNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_NSWorkspaceSessionDidBecomeActiveNotification");

    [statusWindow_ resetStatusMessage];

    [self registerIONotification];
    [self registerWakeNotification];
  });
}

- (void)observer_NSWorkspaceSessionDidResignActiveNotification:(NSNotification*)notification {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"observer_NSWorkspaceSessionDidResignActiveNotification");

    [statusWindow_ resetStatusMessage];

    [self unregisterIONotification];
    [self unregisterWakeNotification];
    [clientForKernelspace disconnect_from_kext];
  });
}

// ------------------------------------------------------------
#define kDescendantProcess @"org_pqrs_Karabiner_DescendantProcess"

- (void)applicationDidFinishLaunching:(NSNotification*)aNotification {
  NSInteger isDescendantProcess = [[[NSProcessInfo processInfo] environment][kDescendantProcess] integerValue];
  setenv([kDescendantProcess UTF8String], "1", 1);

  // ------------------------------------------------------------
  if ([MigrationUtilities migrate:@[ @"org.pqrs.KeyRemap4MacBook" ]
           oldApplicationSupports:@[ @"KeyRemap4MacBook" ]
                         oldPaths:@[ @"/Applications/KeyRemap4MacBook.app" ]]) {
    [Relauncher relaunch];
  }

  // ------------------------------------------------------------
  BOOL openPreferences = NO;
  {
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    if (![bundlePath isEqualToString:@"/Applications/Karabiner.app"]) {
      NSLog(@"Skip setStartAtLogin for %@", bundlePath);
    } else {
      if (![StartAtLoginUtilities isStartAtLogin]) {
        [StartAtLoginUtilities setStartAtLogin:YES];
        openPreferences = YES;
      }
    }
  }

  // ------------------------------------------------------------
  {
    // Remove old pkg files and finish_installation.app in
    // "~/Library/Application Support/Karabiner/.Sparkle".
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* sparkle = paths[0];
    if (sparkle) {
      sparkle = [sparkle stringByAppendingPathComponent:[MigrationUtilities applicationSupportName]];
      sparkle = [sparkle stringByAppendingPathComponent:@".Sparkle"];

      NSFileManager* fm = [NSFileManager defaultManager];
      if ([fm fileExistsAtPath:sparkle]) {
        [fm removeItemAtPath:sparkle error:nil];
      }
    }
  }

  // ------------------------------------------------------------
  if (![serverForUserspace_ register]) {
    // Relaunch when register is failed.
    NSLog(@"[ServerForUserspace register] is failed. Restarting process.");
    [NSThread sleepForTimeInterval:2];
    [Relauncher relaunch];
  }
  [Relauncher resetRelaunchedCount];

  // Wait until other apps connect to me.
  [NSThread sleepForTimeInterval:1];

  axnotifierManagerQueue_ = dispatch_queue_create("org.pqrs.Karabiner.axnotifierManagerQueue_", NULL);

  [preferencesManager_ load];

  [self registerIONotification];
  [self registerWakeNotification];

  [statusWindow_ setupStatusWindow];
  [statusbar_ refresh];
  [xmlCompiler_ reload];

  // ------------------------------------------------------------
  // We need to speficy NSNotificationSuspensionBehaviorDeliverImmediately for NSDistributedNotificationCenter
  // because kTISNotify* will be dropped sometimes without this.
  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:)
                                                          name:(NSString*)(kTISNotifyEnabledKeyboardInputSourcesChanged)
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:)
                                                          name:(NSString*)(kTISNotifySelectedKeyboardInputSourceChanged)
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(observer_ConfigXMLReloaded:)
                                               name:kConfigXMLReloadedNotification
                                             object:nil];

  // ------------------------------
  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceSessionDidBecomeActiveNotification:)
                                                             name:NSWorkspaceSessionDidBecomeActiveNotification
                                                           object:nil];

  [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                         selector:@selector(observer_NSWorkspaceSessionDidResignActiveNotification:)
                                                             name:NSWorkspaceSessionDidResignActiveNotification
                                                           object:nil];

  // ------------------------------------------------------------
  [self distributedObserver_kTISNotifyEnabledKeyboardInputSourcesChanged:nil];
  [self distributedObserver_kTISNotifySelectedKeyboardInputSourceChanged:nil];

  [updater_ checkForUpdatesInBackground:nil];

  // ------------------------------------------------------------
  [self manageAXNotifier:self];

  // ------------------------------------------------------------
  // Send kKarabinerServerDidLaunchNotification after launching AXNotifier.
  //
  // AXNotifier will be relaunched by kKarabinerServerDidLaunchNotification.
  // If we send the notification before launching AXNotifier,
  // two AXNotifier processes will be launched when AXNotifier is already running.
  //
  // * relaunched AXNotifier.
  // * AXNotifier launched by manageAXNotifier.

  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kKarabinerServerDidLaunchNotification
                                                                 object:nil];

  // ------------------------------------------------------------
  // Open Preferences if Karabiner was launched by hand.
  if (openPreferences &&
      !isDescendantProcess) {
    [preferencesController_ show];
  }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication*)theApplication hasVisibleWindows:(BOOL)flag {
  [preferencesController_ show];
  return YES;
}

- (void)dealloc {
  [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ------------------------------------------------------------
- (void)updateFocusedUIElementInformation:(NSDictionary*)information;
{
  @synchronized(self) {
    if (information) {
      // We ignore our investigation application.
      if ([information[@"BundleIdentifier"] isEqualToString:@"org.pqrs.Karabiner.EventViewer"]) return;

      focusedUIElementInformation_ = information;
    }

    bridgeworkspacedata_.applicationtype = [workSpaceData_ getApplicationType:focusedUIElementInformation_[@"BundleIdentifier"]];
    bridgeworkspacedata_.windowname = [workSpaceData_ getWindowName:focusedUIElementInformation_[@"WindowName"]];
    bridgeworkspacedata_.uielementrole = [workSpaceData_ getUIElementRole:focusedUIElementInformation_[@"UIElementRole"]];
    [self send_workspacedata_to_kext];
  }
}

- (NSDictionary*)getFocusedUIElementInformation {
  @synchronized(self) {
    return focusedUIElementInformation_;
  }
}

- (NSDictionary*)getInputSourceInformation {
  @synchronized(self) {
    return inputSourceInformation_;
  }
}

// ------------------------------------------------------------
- (NSString*)AXNotifierPath {
  return @"/Applications/Karabiner.app/Contents/Applications/Karabiner_AXNotifier.app";
}

- (void)launchNewAXNotifier {
  dispatch_sync(axnotifierManagerQueue_, ^{
    NSString* path = [self AXNotifierPath];
    NSURL* url = [NSURL fileURLWithPath:path];
    // Set NSWorkspaceLaunchNewInstance because
    // AXNotifier might be running (terminating) immediately after terminateAXNotifier.
    NSWorkspaceLaunchOptions options = NSWorkspaceLaunchDefault | NSWorkspaceLaunchNewInstance;
    [[NSWorkspace sharedWorkspace] launchApplicationAtURL:url
                                                  options:options
                                            configuration:nil
                                                    error:nil];
  });
}

- (void)terminateAXNotifiers {
  dispatch_sync(axnotifierManagerQueue_, ^{
    NSString* path = [self AXNotifierPath];
    NSString* bundleIdentifier = [[NSBundle bundleWithPath:path] bundleIdentifier];

    // If Karabiner has been moved into /Applications/Utilities, bundleIdentifier will be nil.

    if (bundleIdentifier) {
      NSArray* applications = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
      for (NSRunningApplication* runningApplication in applications) {
        [runningApplication terminate];
      }
    }
  });
}

- (IBAction)restartAXNotifier:(id)sender {
  if (![[NSUserDefaults standardUserDefaults] boolForKey:kIsAXNotifierEnabled]) {
    NSAlert* alert = [NSAlert new];
    [alert setMessageText:@"Karabiner Alert"];
    [alert addButtonWithTitle:@"Close"];
    [alert setInformativeText:@"AXNotifier is disabled.\nPlease enable AXNotifier if you want to start."];
    [alert runModal];
    return;
  }

  [self terminateAXNotifiers];
  [self launchNewAXNotifier];
}

- (IBAction)manageAXNotifier:(id)sender {
  [self terminateAXNotifiers];

  if ([[NSUserDefaults standardUserDefaults] boolForKey:kIsAXNotifierEnabled]) {
    [self launchNewAXNotifier];
  }
}

- (IBAction)launchEventViewer:(id)sender {
  NSString* path = @"/Applications/Karabiner.app/Contents/Applications/EventViewer.app";
  [[NSWorkspace sharedWorkspace] launchApplication:path];
}

- (IBAction)launchMultiTouchExtension:(id)sender {
  [[NSWorkspace sharedWorkspace] launchApplication:@"/Applications/Karabiner.app/Contents/Applications/Karabiner_multitouchextension.app"];
}

- (IBAction)launchUninstaller:(id)sender {
  system("/Applications/Karabiner.app/Contents/Library/extra/launchUninstaller.sh");
}

- (IBAction)openPreferences:(id)sender {
  [preferencesController_ show];
}

- (IBAction)openPrivateXML:(id)sender {
  // Open a directory which contains private.xml.
  NSString* path = [XMLCompiler get_private_xml_path];
  if ([path length] > 0) {
    [[NSWorkspace sharedWorkspace] openFile:[path stringByDeletingLastPathComponent]];
  }
}

- (IBAction)quit:(id)sender {
  NSAlert* alert = [NSAlert alertWithMessageText:@"Quit Karabiner?"
                                   defaultButton:@"Quit"
                                 alternateButton:@"Cancel"
                                     otherButton:nil
                       informativeTextWithFormat:@"Are you sure you want to quit Karabiner?"];
  if ([alert runModal] != NSAlertDefaultReturn) return;

  [StartAtLoginUtilities setStartAtLogin:NO];
  [NSApp terminate:nil];
}

@end
