#!/usr/bin/env bash
set -euo pipefail

target="/Applications/BearBrowser.app"

usage() {
  cat <<'USAGE'
Usage: repair-macos-app-launcher [--target /Applications/BearBrowser.app]

Repairs BearBrowser.app so the running Dock process is BearBrowser, not Firefox.
Installs a native macOS WebKit bootstrap shell inside the app bundle.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      target="${2:?missing target app path}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this command is only supported on macOS" >&2
  exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang is required to build the BearBrowser native launcher" >&2
  exit 2
fi

if [ ! -d "$target/Contents/MacOS" ]; then
  echo "ERROR: BearBrowser.app is missing Contents/MacOS: $target" >&2
  echo "Run: bearbrowser-install-app-launcher" >&2
  exit 1
fi

contents="$target/Contents"
resources="$contents/Resources"
macos="$contents/MacOS"
mkdir -p "$resources" "$macos"

plist="$contents/Info.plist"
landing="$resources/BearBrowser-start.html"
source="$resources/BearBrowserWebKitLauncher.m"
exe="$macos/BearBrowser"

cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BearBrowser</string>
  <key>CFBundleDisplayName</key><string>BearBrowser</string>
  <key>CFBundleIdentifier</key><string>dev.sourceos.BearBrowser</string>
  <key>CFBundleExecutable</key><string>BearBrowser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>BearBrowser</string>
  <key>CFBundleShortVersionString</key><string>0.1.0-overlay</string>
  <key>CFBundleVersion</key><string>0.1.0-overlay</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$landing" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BearBrowser</title>
<style>
:root{color-scheme:dark;--bg:#1f1b16;--panel:#2a241d;--line:#6d4b31;--text:#f4efe7;--muted:#d8cabc;--gold:#f6d28b}
*{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:radial-gradient(circle at 30% 15%,#3a2a1d 0,#1f1b16 45%,#15120f 100%);color:var(--text);display:grid;place-items:center;min-height:100vh}.shell{max-width:860px;margin:48px;padding:48px;border:1px solid var(--line);border-radius:30px;background:rgba(42,36,29,.94);box-shadow:0 30px 90px rgba(0,0,0,.35)}.bear{font-size:64px}h1{font-size:52px;line-height:1.05;margin:12px 0 14px}p{font-size:18px;line-height:1.55;color:var(--muted)}.status{margin-top:28px;padding:16px 18px;border-radius:18px;background:#3a3027;color:var(--gold);font-weight:700}code{color:var(--gold)}
</style>
</head>
<body>
<main class="shell">
<div class="bear">🐻</div>
<h1>BearBrowser</h1>
<p>Native BearBrowser bootstrap shell is running. The Dock process and app identity should now be BearBrowser, not Firefox.</p>
<p>The final Gecko-derived runtime remains tracked by Lane 13. This interim native shell exists so the product opens from Applications with correct identity while the full runtime continues.</p>
<div class="status">BearBrowser native bootstrap active</div>
</main>
</body>
</html>
HTML

cat > "$source" <<'OBJC'
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

static void BBLog(NSString *message) {
  NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/BearBrowser"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [dir stringByAppendingPathComponent:@"launcher.log"];
  NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!handle) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
  [handle seekToEndOfFile]; [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [handle closeFile];
}

@interface BBDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate, NSTextFieldDelegate>
@property(strong) NSWindow *window;
@property(strong) WKWebView *webView;
@property(strong) NSTextField *address;
@end

@implementation BBDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  BBLog(@"BearBrowser native WebKit shell start");
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  NSRect frame = NSMakeRect(0, 0, 1180, 820);
  self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable) backing:NSBackingStoreBuffered defer:NO];
  [self.window setTitle:@"BearBrowser"];
  [self.window center];

  NSView *root = [[NSView alloc] initWithFrame:frame];
  [root setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
  [self.window setContentView:root];

  CGFloat toolbarH = 46.0;
  NSView *toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0, frame.size.height-toolbarH, frame.size.width, toolbarH)];
  [toolbar setAutoresizingMask:NSViewWidthSizable|NSViewMinYMargin];
  [root addSubview:toolbar];

  NSButton *back = [NSButton buttonWithTitle:@"‹" target:self action:@selector(goBack:)];
  NSButton *fwd = [NSButton buttonWithTitle:@"›" target:self action:@selector(goForward:)];
  NSButton *reload = [NSButton buttonWithTitle:@"↻" target:self action:@selector(reload:)];
  NSArray *buttons = @[back, fwd, reload];
  CGFloat x = 12.0;
  for (NSButton *b in buttons) { [b setFrame:NSMakeRect(x, 8, 38, 30)]; [b setBezelStyle:NSBezelStyleRounded]; [toolbar addSubview:b]; x += 44.0; }

  self.address = [[NSTextField alloc] initWithFrame:NSMakeRect(x+6, 8, frame.size.width-x-24, 30)];
  [self.address setAutoresizingMask:NSViewWidthSizable];
  [self.address setDelegate:self];
  [self.address setStringValue:@"bearbrowser://start"];
  [toolbar addSubview:self.address];

  WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
  self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height-toolbarH) configuration:config];
  [self.webView setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
  [self.webView setNavigationDelegate:self];
  [root addSubview:self.webView];

  NSURL *landing = [[NSBundle mainBundle] URLForResource:@"BearBrowser-start" withExtension:@"html"];
  if (landing) { [self.webView loadFileURL:landing allowingReadAccessToURL:[landing URLByDeletingLastPathComponent]]; BBLog([NSString stringWithFormat:@"loaded %@", landing.path]); }
  else { [self.webView loadHTMLString:@"<h1>BearBrowser</h1><p>Landing page missing.</p>" baseURL:nil]; BBLog(@"landing page missing"); }

  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)goBack:(id)sender { if (self.webView.canGoBack) [self.webView goBack]; }
- (void)goForward:(id)sender { if (self.webView.canGoForward) [self.webView goForward]; }
- (void)reload:(id)sender { [self.webView reload]; }
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)sel {
  if (sel == @selector(insertNewline:)) {
    NSString *raw = self.address.stringValue;
    NSURL *url = [NSURL URLWithString:raw];
    if (!url.scheme) url = [NSURL URLWithString:[@"https://" stringByAppendingString:raw]];
    if (url) { BBLog([NSString stringWithFormat:@"navigate %@", url.absoluteString]); [self.webView loadRequest:[NSURLRequest requestWithURL:url]]; }
    return YES;
  }
  return NO;
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)nav { self.address.stringValue = webView.URL.absoluteString ?: @"bearbrowser://start"; }
@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    BBDelegate *delegate = [[BBDelegate alloc] init];
    [app setDelegate:delegate];
    [app run];
  }
  return 0;
}
OBJC

clang -fobjc-arc -framework Cocoa -framework WebKit "$source" -o "$exe"
chmod +x "$exe"
: > "$HOME/Library/Logs/BearBrowser/launcher.log" 2>/dev/null || true
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$lsregister" ]; then
  "$lsregister" -f "$target" || true
fi

/usr/bin/touch "$target"
echo "Repaired BearBrowser app launcher with native WebKit executable: $target"
echo "Open: open '$target'"
echo "Log: ~/Library/Logs/BearBrowser/launcher.log"
