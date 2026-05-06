#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static NSString *BBSupportDir(void) {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BearBrowser"];
}

static NSString *BBLogDir(void) {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/BearBrowser"];
}

static NSString *BBProvenancePath(void) {
  return [[BBSupportDir() stringByAppendingPathComponent:@"provenance"] stringByAppendingPathComponent:@"events.jsonl"];
}

static NSString *BBPolicyPath(void) {
  return [[BBSupportDir() stringByAppendingPathComponent:@"policy"] stringByAppendingPathComponent:@"actions.jsonl"];
}

static NSString *BBMemoryPath(void) {
  return [[BBSupportDir() stringByAppendingPathComponent:@"memory"] stringByAppendingPathComponent:@"candidates.jsonl"];
}

static NSString *BBTimestamp(void) {
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
  fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
  return [fmt stringFromDate:[NSDate date]];
}

static NSString *BBRandomHex(NSUInteger bytes) {
  NSMutableString *out = [NSMutableString stringWithCapacity:bytes * 2];
  for (NSUInteger i = 0; i < bytes; i++) {
    uint8_t value = (uint8_t)arc4random_uniform(256);
    [out appendFormat:@"%02x", value];
  }
  return out;
}

static void BBAppendLine(NSString *path, NSString *line) {
  NSString *dir = [path stringByDeletingLastPathComponent];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *withNewline = [line stringByAppendingString:@"\n"];
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!handle) {
    [withNewline writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  [handle seekToEndOfFile];
  [handle writeData:[withNewline dataUsingEncoding:NSUTF8StringEncoding]];
  [handle closeFile];
}

static NSString *BBJSON(NSDictionary *dict) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
  if (!data) { return @"{}"; }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void BBLog(NSString *message) {
  [[NSFileManager defaultManager] createDirectoryAtPath:BBLogDir() withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [BBLogDir() stringByAppendingPathComponent:@"launcher.log"];
  NSString *line = [NSString stringWithFormat:@"%@ %@", [NSDate date], message];
  BBAppendLine(path, line);
}

static void BBEmitEvent(NSString *eventType, NSString *decision, NSString *reason, NSDictionary *payload) {
  NSDictionary *event = @{
    @"schemaVersion": @"bearbrowser.provenance.v1",
    @"eventId": [@"evt-" stringByAppendingString:BBRandomHex(16)],
    @"timestamp": BBTimestamp(),
    @"product": @"BearBrowser",
    @"surface": @"native-shell",
    @"profile": @"bootstrap",
    @"eventType": eventType,
    @"actor": @{ @"type": @"system", @"id": NSUserName() ?: @"local-user" },
    @"policy": @{
      @"decision": decision,
      @"decisionId": [@"local-" stringByAppendingString:BBRandomHex(8)],
      @"mode": @"local-default",
      @"reason": reason
    },
    @"redaction": @{
      @"secretValuesPresent": @NO,
      @"secretValuesLogged": @NO,
      @"payloadClass": @"metadata"
    },
    @"payload": payload ?: @{}
  };
  BBAppendLine(BBProvenancePath(), BBJSON(event));
}

static void BBProposeAction(NSString *actionType, NSString *targetKind, NSString *targetLabel, NSString *targetURL, NSString *risk, NSString *decision, BOOL requiresApproval, NSString *reason) {
  NSMutableDictionary *target = [@{ @"kind": targetKind ?: @"page" } mutableCopy];
  if (targetLabel.length > 0) { target[@"label"] = targetLabel; }
  if (targetURL.length > 0) { target[@"url"] = targetURL; }
  NSDictionary *action = @{
    @"schemaVersion": @"bearbrowser.policy_action.v1",
    @"actionId": [@"act-" stringByAppendingString:BBRandomHex(16)],
    @"timestamp": BBTimestamp(),
    @"actionType": actionType,
    @"requestedBy": @{ @"type": @"human", @"id": NSUserName() ?: @"local-user" },
    @"target": target,
    @"risk": @{ @"level": risk, @"requiresUserApproval": @(requiresApproval), @"reason": reason },
    @"decision": @{ @"state": decision, @"decisionId": [@"local-" stringByAppendingString:BBRandomHex(8)], @"mode": @"local-default", @"reason": reason }
  };
  BBAppendLine(BBPolicyPath(), BBJSON(action));
}

static BOOL BBMemoryLooksSensitive(NSString *text) {
  NSArray<NSString *> *markers = @[@"password", @"secret", @"token", @"cookie", @"credential", @"payment"];
  NSString *lower = [text lowercaseString];
  for (NSString *marker in markers) {
    if ([lower containsString:marker]) { return YES; }
  }
  return NO;
}

static void BBCreateMemoryCandidate(NSString *text, NSString *sourceURL, NSString *sourceLabel) {
  BOOL sensitive = BBMemoryLooksSensitive(text ?: @"");
  NSString *memoryId = [@"mem-" stringByAppendingString:BBRandomHex(16)];
  NSString *storedText = sensitive ? @"<REDACTED-SENSITIVE-MEMORY-CANDIDATE>" : (text ?: @"");
  NSString *payloadClass = sensitive ? @"secret-blocked" : @"metadata";
  NSMutableDictionary *source = [@{ @"kind": @"page" } mutableCopy];
  if (sourceURL.length > 0) { source[@"url"] = sourceURL; }
  if (sourceLabel.length > 0) { source[@"label"] = sourceLabel; }
  NSDictionary *memory = @{
    @"schemaVersion": @"bearbrowser.memory_candidate.v1",
    @"memoryId": memoryId,
    @"timestamp": BBTimestamp(),
    @"product": @"BearBrowser",
    @"state": @"candidate",
    @"actor": @{ @"type": @"human", @"id": NSUserName() ?: @"local-user" },
    @"source": source,
    @"classification": @{
      @"payloadClass": payloadClass,
      @"secretLikeDetected": @(sensitive),
      @"persistentWriteRequiresApproval": @YES
    },
    @"text": storedText,
    @"policy": @{
      @"decision": @"hold",
      @"decisionId": [@"local-" stringByAppendingString:BBRandomHex(8)],
      @"mode": @"local-default",
      @"reason": @"Memory candidates must be previewed and explicitly committed or rejected."
    }
  };
  BBAppendLine(BBMemoryPath(), BBJSON(memory));
  BBEmitEvent(@"memory.candidate_created", @"hold", @"Native shell created a held memory candidate.", @{ @"memoryId": memoryId, @"url": sourceURL ?: @"" });
}

@interface BBDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate, NSTextFieldDelegate>
@property(strong) NSWindow *window;
@property(strong) WKWebView *webView;
@property(strong) NSTextField *address;
@end

@implementation BBDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  BBLog(@"BearBrowser native WebKit shell start");
  BBEmitEvent(@"app.launch", @"allow", @"Native BearBrowser shell launched.", @{ @"bundleId": @"dev.sourceos.BearBrowser" });
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  NSRect frame = NSMakeRect(0, 0, 1320, 820);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  [self.window setTitle:@"BearBrowser"];
  [self.window center];

  NSView *root = [[NSView alloc] initWithFrame:frame];
  [root setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [self.window setContentView:root];

  CGFloat toolbarH = 48.0;
  NSView *toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0, frame.size.height - toolbarH, frame.size.width, toolbarH)];
  [toolbar setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
  [root addSubview:toolbar];

  NSButton *back = [NSButton buttonWithTitle:@"‹" target:self action:@selector(goBack:)];
  NSButton *fwd = [NSButton buttonWithTitle:@"›" target:self action:@selector(goForward:)];
  NSButton *reload = [NSButton buttonWithTitle:@"↻" target:self action:@selector(reload:)];
  NSButton *share = [NSButton buttonWithTitle:@"Propose Share" target:self action:@selector(proposePageShare:)];
  NSButton *memory = [NSButton buttonWithTitle:@"Memory Candidate" target:self action:@selector(createMemoryCandidate:)];
  NSButton *resolve = [NSButton buttonWithTitle:@"Resolve Held" target:self action:@selector(resolveHeld:)];
  NSButton *sidecar = [NSButton buttonWithTitle:@"Sidecar Status" target:self action:@selector(openSidecarStatus:)];

  CGFloat x = 12.0;
  for (NSButton *button in @[back, fwd, reload]) {
    [button setFrame:NSMakeRect(x, 9, 38, 30)];
    [button setBezelStyle:NSBezelStyleRounded];
    [toolbar addSubview:button];
    x += 44.0;
  }

  CGFloat right = frame.size.width - 660;
  [share setFrame:NSMakeRect(right, 9, 124, 30)];
  [memory setFrame:NSMakeRect(right + 132, 9, 150, 30)];
  [resolve setFrame:NSMakeRect(right + 290, 9, 118, 30)];
  [sidecar setFrame:NSMakeRect(right + 416, 9, 132, 30)];
  for (NSButton *button in @[share, memory, resolve, sidecar]) {
    [button setAutoresizingMask:NSViewMinXMargin];
    [button setBezelStyle:NSBezelStyleRounded];
    [toolbar addSubview:button];
  }

  self.address = [[NSTextField alloc] initWithFrame:NSMakeRect(x + 6, 9, frame.size.width - x - 676, 30)];
  [self.address setAutoresizingMask:NSViewWidthSizable];
  [self.address setDelegate:self];
  [self.address setStringValue:@"bearbrowser://start"];
  [toolbar addSubview:self.address];

  WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
  self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height - toolbarH) configuration:config];
  [self.webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
  [self.webView setNavigationDelegate:self];
  [root addSubview:self.webView];

  NSURL *landing = [[NSBundle mainBundle] URLForResource:@"BearBrowser-start" withExtension:@"html"];
  if (landing) {
    [self.webView loadFileURL:landing allowingReadAccessToURL:[landing URLByDeletingLastPathComponent]];
    BBLog([NSString stringWithFormat:@"loaded %@", landing.path]);
  } else {
    [self.webView loadHTMLString:@"<h1>BearBrowser</h1><p>Landing page missing.</p>" baseURL:nil];
    BBLog(@"landing page missing");
  }

  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)goBack:(id)sender { if (self.webView.canGoBack) [self.webView goBack]; }
- (void)goForward:(id)sender { if (self.webView.canGoForward) [self.webView goForward]; }
- (void)reload:(id)sender { [self.webView reload]; }

- (NSString *)currentURLString {
  return self.webView.URL.absoluteString ?: @"bearbrowser://start";
}

- (void)runCommand:(NSString *)command successMessage:(NSString *)successMessage {
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/bin/bash";
  task.arguments = @[@"-lc", [NSString stringWithFormat:@"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; %@", command]];
  [task launch];
  [task waitUntilExit];
  BBLog([NSString stringWithFormat:@"command exit=%d command=%@", task.terminationStatus, command]);
  [self openSidecarStatus:nil];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = task.terminationStatus == 0 ? successMessage : @"BearBrowser command failed";
  alert.informativeText = task.terminationStatus == 0 ? @"Sidecar Status has been refreshed." : @"Check ~/Library/Logs/BearBrowser/launcher.log and the local governance logs.";
  [alert addButtonWithTitle:@"OK"];
  [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)proposePageShare:(id)sender {
  NSString *url = [self currentURLString];
  BBProposeAction(@"share_page_with_agent", @"page", @"native-propose-share", url, @"medium", @"hold", YES, @"User requested a held page-share proposal from the native shell.");
  BBEmitEvent(@"page.shared_with_agent", @"hold", @"Native page-share proposal created; no agent authority granted.", @{ @"url": url, @"surface": @"native-propose-share" });
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Page share proposal held";
  alert.informativeText = @"BearBrowser recorded a held share_page_with_agent action. Use Resolve Held or Sidecar Status to inspect and resolve it.";
  [alert addButtonWithTitle:@"OK"];
  [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)createMemoryCandidate:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Create memory candidate";
  alert.informativeText = @"Memory candidates are held by default and must be explicitly committed or rejected.";
  NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 460, 28)];
  input.placeholderString = @"What should BearBrowser remember as a candidate?";
  alert.accessoryView = input;
  [alert addButtonWithTitle:@"Create Candidate"];
  [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
    if (returnCode != NSAlertFirstButtonReturn) { return; }
    NSString *text = input.stringValue ?: @"";
    if (text.length == 0) { return; }
    NSString *url = [self currentURLString];
    BBProposeAction(@"write_memory_candidate", @"memory", @"native-memory-candidate", url, @"medium", @"hold", YES, @"User requested a held memory candidate from the native shell.");
    BBCreateMemoryCandidate(text, url, @"native-memory-candidate");
  }];
}

- (void)resolveHeld:(id)sender {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Resolve held BearBrowser state";
  alert.informativeText = @"Resolve the latest held policy action or latest pending memory candidate. Decisions are appended to local governance logs.";
  [alert addButtonWithTitle:@"Allow Held Action"];
  [alert addButtonWithTitle:@"Deny Held Action"];
  [alert addButtonWithTitle:@"Commit Memory"];
  [alert addButtonWithTitle:@"Reject Memory"];
  [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
    if (returnCode == NSAlertFirstButtonReturn) {
      [self runCommand:@"bearbrowser-resolve-action --latest-held --decision allow --actor-type human --actor-id native-shell --reason 'Allowed from BearBrowser native shell.'" successMessage:@"Held action allowed"];
    } else if (returnCode == NSAlertSecondButtonReturn) {
      [self runCommand:@"bearbrowser-resolve-action --latest-held --decision deny --actor-type human --actor-id native-shell --reason 'Denied from BearBrowser native shell.'" successMessage:@"Held action denied"];
    } else if (returnCode == NSAlertThirdButtonReturn) {
      [self runCommand:@"bearbrowser-memory-candidate resolve --latest-candidate --decision commit --actor-type human --actor-id native-shell --reason 'Committed from BearBrowser native shell.'" successMessage:@"Memory candidate committed"];
    } else if (returnCode == NSAlertThirdButtonReturn + 1) {
      [self runCommand:@"bearbrowser-memory-candidate resolve --latest-candidate --decision reject --actor-type human --actor-id native-shell --reason 'Rejected from BearBrowser native shell.'" successMessage:@"Memory candidate rejected"];
    }
  }];
}

- (void)openSidecarStatus:(id)sender {
  NSString *support = BBSupportDir();
  NSString *sidecarDir = [support stringByAppendingPathComponent:@"sidecar"];
  [[NSFileManager defaultManager] createDirectoryAtPath:sidecarDir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *htmlPath = [sidecarDir stringByAppendingPathComponent:@"status.html"];

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = @"/bin/bash";
  task.arguments = @[@"-lc", [NSString stringWithFormat:@"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; if command -v bearbrowser-sidecar-status >/dev/null 2>&1; then bearbrowser-sidecar-status --format html --out '%@'; fi", htmlPath]];
  [task launch];
  [task waitUntilExit];

  BBProposeAction(@"share_page_with_agent", @"page", @"sidecar-status-open", [self currentURLString], @"medium", @"hold", YES, @"Opening sidecar status records page context sharing as a held local-default action.");
  BBEmitEvent(@"page.shared_with_agent", @"hold", @"Sidecar status requested; page sharing remains held by local default policy.", @{ @"url": [self currentURLString], @"surface": @"sidecar-status" });

  NSURL *url = [NSURL fileURLWithPath:htmlPath];
  if ([[NSFileManager defaultManager] fileExistsAtPath:htmlPath]) {
    [self.webView loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]];
  } else {
    [self.webView loadHTMLString:@"<h1>BearBrowser Sidecar Status</h1><p>Status renderer command is not installed yet. Reinstall the Homebrew formula.</p>" baseURL:nil];
  }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)sel {
  if (sel == @selector(insertNewline:)) {
    NSString *raw = self.address.stringValue;
    NSURL *url = [NSURL URLWithString:raw];
    if (!url.scheme) { url = [NSURL URLWithString:[@"https://" stringByAppendingString:raw]]; }
    if (url) {
      BBLog([NSString stringWithFormat:@"navigate %@", url.absoluteString]);
      BBEmitEvent(@"navigation.requested", @"allow", @"User requested navigation from native address bar.", @{ @"url": url.absoluteString ?: @"" });
      [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
    return YES;
  }
  return NO;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  NSString *url = webView.URL.absoluteString ?: @"bearbrowser://start";
  self.address.stringValue = url;
  BBEmitEvent(@"navigation.committed", @"allow", @"Navigation committed in native shell.", @{ @"url": url });
}

@end

int main(int argc, const char * argv[]) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    BBDelegate *delegate = [[BBDelegate alloc] init];
    [app setDelegate:delegate];
    [app run];
  }
  return 0;
}
