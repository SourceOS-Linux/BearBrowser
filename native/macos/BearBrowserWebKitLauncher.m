#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// Forward declarations needed by classes defined before the support helpers
static NSString *BBSupportDir(void);
static NSString *BBLogDir(void);

// ── BBFontSchemeHandler ───────────────────────────────────────────────────────
// Serves bundled woff2 fonts via bbfont:// scheme so pages never hit Google Fonts CDN.
@interface BBFontSchemeHandler : NSObject <WKURLSchemeHandler>
@property(strong) NSString *fontsDir;
@end
@implementation BBFontSchemeHandler
- (instancetype)init {
  self=[super init];
  NSString *bundle=[[NSBundle mainBundle] resourcePath];
  _fontsDir=[bundle stringByAppendingPathComponent:@"fonts/woff2"];
  return self;
}
- (void)webView:(WKWebView *)wv startURLSchemeTask:(id<WKURLSchemeTask>)task {
  NSURL *url=task.request.URL;
  // bbfont://fonts/<filename.woff2>
  NSString *filename=url.path.lastPathComponent;
  NSString *path=[self.fontsDir stringByAppendingPathComponent:filename];
  NSData *data=[NSData dataWithContentsOfFile:path];
  if (!data) {
    [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];
    return;
  }
  NSURLResponse *resp=[[NSURLResponse alloc]initWithURL:url MIMEType:@"font/woff2"
    expectedContentLength:data.length textEncodingName:nil];
  [task didReceiveResponse:resp];
  [task didReceiveData:data];
  [task didFinish];
}
- (void)webView:(WKWebView *)wv stopURLSchemeTask:(id<WKURLSchemeTask>)task {}
@end

// ── BBContentBlocker ──────────────────────────────────────────────────────────
// Compiles and caches WKContentRuleList for tracker/ad blocking.
@interface BBContentBlocker : NSObject
+ (void)loadRulesInto:(WKWebViewConfiguration *)config completion:(void(^)(void))done;
@end
@implementation BBContentBlocker

// Baseline tracker/ad rules — covers the highest-traffic domains.
// Full list updated via scripts/update-content-rules.sh → compiled JSON cached to disk.
+ (NSString *)baselineRulesJSON {
  // Format: WKContentRuleList declarative JSON.
  // Block trackers at the network layer before any request fires.
  static NSArray *trackerDomains = nil;
  if (!trackerDomains) trackerDomains = @[
    // Analytics & tracking
    @"google-analytics\\.com", @"googletagmanager\\.com", @"googletagservices\\.com",
    @"doubleclick\\.net", @"googlesyndication\\.com", @"adservice\\.google\\.com",
    @"facebook\\.com/tr", @"connect\\.facebook\\.net", @"analytics\\.twitter\\.com",
    @"t\\.co/[0-9]", @"static\\.ads-twitter\\.com",
    @"hotjar\\.com", @"fullstory\\.com", @"logrocket\\.com", @"smartlook\\.com",
    @"mixpanel\\.com", @"amplitude\\.com/api", @"segment\\.io", @"segment\\.com/analytics",
    @"heap\\.io", @"heapanalytics\\.com",
    @"newrelic\\.com/browser", @"nr-data\\.net",
    @"intercom\\.io/api", @"intercomcdn\\.com",
    @"crisp\\.chat/client", @"widget\\.intercom\\.io",
    // Ad networks
    @"ads\\.linkedin\\.com", @"platform\\.linkedin\\.com/in\\.js",
    @"snap\\.licdn\\.com", @"px\\.ads\\.linkedin\\.com",
    @"bing\\.com/bat", @"bat\\.bing\\.com",
    @"amazon-adsystem\\.com", @"aax-us-east\\.amazon-adsystem\\.com",
    @"rubiconproject\\.com", @"openx\\.net", @"pubmatic\\.com",
    @"casalemedia\\.com", @"criteo\\.com", @"criteo\\.net",
    @"outbrain\\.com", @"taboola\\.com", @"revcontent\\.com",
    @"moatads\\.com", @"adnxs\\.com", @"appnexus\\.com",
    @"bidswitch\\.net", @"ssp\\.yahoo\\.com", @"gemini\\.yahoo\\.com",
    // Font CDNs (served locally instead)
    @"fonts\\.googleapis\\.com", @"fonts\\.gstatic\\.com",
    @"use\\.typekit\\.net", @"p\\.typekit\\.net",
    // Fingerprinting & session replay
    @"fingerprintjs\\.com", @"fp\\.clarity\\.ms", @"clarity\\.ms/tag",
    @"mouseflow\\.com", @"inspectlet\\.com", @"sessioncam\\.com",
    // Social widgets (privacy leak even without interaction)
    @"platform\\.twitter\\.com/widgets", @"platform\\.instagram\\.com",
    @"staticxx\\.facebook\\.com", @"www\\.facebook\\.com/plugins",
    // Data brokers / identity resolution
    @"quantserve\\.com", @"scorecardresearch\\.com", @"comscore\\.com",
    @"bluekai\\.com", @"turn\\.com", @"mediamath\\.com",
    @"adsymptotic\\.com", @"adsafeprotected\\.com",
  ];

  NSMutableArray *rules=[NSMutableArray array];
  // Block all tracker domains
  for (NSString *pattern in trackerDomains) {
    [rules addObject:@{
      @"trigger": @{@"url-filter": pattern, @"load-type": @[@"third-party"]},
      @"action":  @{@"type": @"block"}
    }];
  }
  // Block font CDNs entirely (we serve locally)
  [rules addObject:@{
    @"trigger": @{@"url-filter": @"fonts\\.googleapis\\.com|fonts\\.gstatic\\.com|use\\.typekit\\.net"},
    @"action":  @{@"type": @"block"}
  }];
  // Block known tracking pixels (1x1 images)
  [rules addObject:@{
    @"trigger": @{@"url-filter": @".*", @"resource-type": @[@"image"],
                  @"url-filter-is-case-sensitive": @NO,
                  @"load-type": @[@"third-party"]},
    @"action":  @{@"type": @"css-display-none", @"selector": @"img[width='1'][height='1'],img[src*='pixel'],img[src*='beacon'],img[src*='tracking']"}
  }];
  NSData *json=[NSJSONSerialization dataWithJSONObject:rules options:0 error:nil];
  return [[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding];
}

+ (void)loadRulesInto:(WKWebViewConfiguration *)config completion:(void(^)(void))done {
  // Check for compiled rules on disk (put there by update-content-rules.sh)
  NSString *compiledPath=[[BBSupportDir() stringByAppendingPathComponent:@"content-rules"] stringByAppendingPathComponent:@"rules.json"];
  NSString *rulesJSON=([NSFileManager.defaultManager fileExistsAtPath:compiledPath])
    ? [NSString stringWithContentsOfFile:compiledPath encoding:NSUTF8StringEncoding error:nil]
    : nil;
  if (!rulesJSON.length) rulesJSON=[self baselineRulesJSON];

  WKContentRuleListStore *store=[WKContentRuleListStore defaultStore];
  [store compileContentRuleListForIdentifier:@"bb-baseline"
                      encodedContentRuleList:rulesJSON
                           completionHandler:^(WKContentRuleList *list, NSError *err) {
    if (list) [config.userContentController addContentRuleList:list];
    if (err)  NSLog(@"[BBContentBlocker] compile error: %@", err.localizedDescription);
    if (done) done();
  }];
}
@end

// ── BBVoice ───────────────────────────────────────────────────────────────────
// Read-aloud with voice tuned between Gemini Ursa / ChatGPT Sol (female)
// and Australian-inflected natural male. Falls back gracefully on older macOS.
@interface BBVoice : NSObject <AVSpeechSynthesizerDelegate>
@property(strong) AVSpeechSynthesizer *synth;
@property(assign) BOOL speaking;
+ (instancetype)shared;
- (void)readPage:(WKWebView *)wv;
- (void)stop;
@end
@implementation BBVoice
+ (instancetype)shared { static BBVoice *s; static dispatch_once_t t; dispatch_once(&t,^{s=[[self alloc]init];}); return s; }
- (instancetype)init { self=[super init]; _synth=[[AVSpeechSynthesizer alloc]init]; _synth.delegate=self; return self; }

// Preferred voice identifiers in priority order.
// Female: Karen Enhanced (AU) → Zoe Enhanced → Samantha Enhanced → Samantha
// Male:   Lee Enhanced (AU) → Daniel Enhanced (UK) → Alex
+ (AVSpeechSynthesisVoice *)preferredVoiceForGender:(AVSpeechSynthesisVoiceGender)gender {
  NSArray *femaleIds=@[
    @"com.apple.voice.enhanced.en-AU.Karen",
    @"com.apple.voice.premium.en-AU.Karen",
    @"com.apple.ttsbundle.Karen-premium",
    @"com.apple.voice.enhanced.en-US.Zoe",
    @"com.apple.voice.enhanced.en-US.Samantha",
    @"com.apple.ttsbundle.Samantha-premium",
  ];
  NSArray *maleIds=@[
    @"com.apple.voice.enhanced.en-AU.Lee",
    @"com.apple.voice.premium.en-AU.Lee",
    @"com.apple.ttsbundle.Lee-premium",
    @"com.apple.voice.enhanced.en-GB.Daniel",
    @"com.apple.ttsbundle.Alex-compact",
  ];
  NSArray *candidates=(gender==AVSpeechSynthesisVoiceGenderFemale)?femaleIds:maleIds;
  for (NSString *vid in candidates) {
    AVSpeechSynthesisVoice *v=[AVSpeechSynthesisVoice voiceWithIdentifier:vid];
    if (v) return v;
  }
  // Final fallback: pick first system voice matching language
  for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
    if ([v.language hasPrefix:@"en"] && v.gender==gender) return v;
  }
  return nil;
}

- (void)readPage:(WKWebView *)wv {
  if (self.speaking) { [self stop]; return; }
  [wv evaluateJavaScript:
    @"(function(){"
    @"var sel=window.getSelection&&window.getSelection().toString().trim();"
    @"if(sel&&sel.length>0)return sel;"
    @"var a=document.querySelector('article')||document.querySelector('main')||document.body;"
    @"return (a?a.innerText:'').replace(/\\s+/g,' ').trim().slice(0,8000);"
    @"})()"
    completionHandler:^(id r,NSError *e){
      if(e||![r isKindOfClass:[NSString class]]||![(NSString*)r length]) return;
      AVSpeechUtterance *u=[AVSpeechUtterance speechUtteranceWithString:(NSString*)r];
      u.voice=[BBVoice preferredVoiceForGender:AVSpeechSynthesisVoiceGenderFemale];
      u.rate=0.52f;   // slightly slower than default (0.5) for clarity — between Ursa and Sol pacing
      u.pitchMultiplier=1.05f;
      u.volume=0.95f;
      self.speaking=YES;
      [self.synth speakUtterance:u];
  }];
}
- (void)stop { [self.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; self.speaking=NO; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u { self.speaking=NO; }
@end

// ── Support helpers ───────────────────────────────────────────────────────────
static NSString *BBSupportDir(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/BearBrowser"]; }
static NSString *BBLogDir(void)     { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/BearBrowser"]; }
static NSString *BBProvenancePath(void) { return [[BBSupportDir() stringByAppendingPathComponent:@"provenance"] stringByAppendingPathComponent:@"events.jsonl"]; }
static NSString *BBPolicyPath(void) { return [[BBSupportDir() stringByAppendingPathComponent:@"policy"] stringByAppendingPathComponent:@"actions.jsonl"]; }
static NSString *BBMemoryPath(void) { return [[BBSupportDir() stringByAppendingPathComponent:@"memory"] stringByAppendingPathComponent:@"candidates.jsonl"]; }
static NSString *BBTimestamp(void) {
  NSDateFormatter *f=[[NSDateFormatter alloc]init];
  f.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  f.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
  f.dateFormat=@"yyyy-MM-dd'T'HH:mm:ss'Z'";
  return [f stringFromDate:[NSDate date]];
}
static NSString *BBRandomHex(NSUInteger n) {
  NSMutableString *s=[NSMutableString stringWithCapacity:n*2];
  for (NSUInteger i=0;i<n;i++) [s appendFormat:@"%02x",(uint8_t)arc4random_uniform(256)];
  return s;
}
static NSString *BBShellQuote(NSString *v) {
  return [NSString stringWithFormat:@"'%@'",[v stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
static void BBAppendLine(NSString *path,NSString *line) {
  [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
    withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *s=[line stringByAppendingString:@"\n"];
  NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:path];
  if (!h) { [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
  [h seekToEndOfFile]; [h writeData:[s dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}
static NSString *BBJSON(NSDictionary *d) {
  NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
  return data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:@"{}";
}
static void BBLog(NSString *msg) {
  [[NSFileManager defaultManager] createDirectoryAtPath:BBLogDir() withIntermediateDirectories:YES attributes:nil error:nil];
  BBAppendLine([BBLogDir() stringByAppendingPathComponent:@"launcher.log"],
               [NSString stringWithFormat:@"%@ %@",[NSDate date],msg]);
}
static void BBEmitEvent(NSString *type,NSString *decision,NSString *reason,NSDictionary *payload) {
  BBAppendLine(BBProvenancePath(),BBJSON(@{
    @"schemaVersion":@"bearbrowser.provenance.v1",
    @"eventId":[@"evt-" stringByAppendingString:BBRandomHex(16)],
    @"timestamp":BBTimestamp(),@"product":@"BearBrowser",@"surface":@"native-shell",@"profile":@"bootstrap",
    @"eventType":type,@"actor":@{@"type":@"system",@"id":NSUserName()?:@"local-user"},
    @"policy":@{@"decision":decision,@"decisionId":[@"local-" stringByAppendingString:BBRandomHex(8)],@"mode":@"local-default",@"reason":reason},
    @"redaction":@{@"secretValuesPresent":@NO,@"secretValuesLogged":@NO,@"payloadClass":@"metadata"},
    @"payload":payload?:@{}
  }));
}
static void BBProposeAction(NSString *aType,NSString *tKind,NSString *label,NSString *url,NSString *risk,NSString *decision,BOOL req,NSString *reason) {
  NSMutableDictionary *t=[@{@"kind":tKind?:@"page"} mutableCopy];
  if (label.length) t[@"label"]=label; if (url.length) t[@"url"]=url;
  BBAppendLine(BBPolicyPath(),BBJSON(@{
    @"schemaVersion":@"bearbrowser.policy_action.v1",
    @"actionId":[@"act-" stringByAppendingString:BBRandomHex(16)],
    @"timestamp":BBTimestamp(),@"actionType":aType,
    @"requestedBy":@{@"type":@"human",@"id":NSUserName()?:@"local-user"},
    @"target":t,@"risk":@{@"level":risk,@"requiresUserApproval":@(req),@"reason":reason},
    @"decision":@{@"state":decision,@"decisionId":[@"local-" stringByAppendingString:BBRandomHex(8)],@"mode":@"local-default",@"reason":reason}
  }));
}
static BOOL BBMemoryLooksSensitive(NSString *t) {
  NSString *l=[t lowercaseString];
  for (NSString *m in @[@"password",@"secret",@"token",@"cookie",@"credential",@"payment"])
    if ([l containsString:m]) return YES;
  return NO;
}
static void BBCreateMemoryCandidate(NSString *text,NSString *srcURL,NSString *srcLabel) {
  BOOL sensitive=BBMemoryLooksSensitive(text?:@"");
  NSString *memId=[@"mem-" stringByAppendingString:BBRandomHex(16)];
  NSMutableDictionary *src=[@{@"kind":@"page"} mutableCopy];
  if (srcURL.length) src[@"url"]=srcURL; if (srcLabel.length) src[@"label"]=srcLabel;
  BBAppendLine(BBMemoryPath(),BBJSON(@{
    @"schemaVersion":@"bearbrowser.memory_candidate.v1",@"memoryId":memId,
    @"timestamp":BBTimestamp(),@"product":@"BearBrowser",@"state":@"candidate",
    @"actor":@{@"type":@"human",@"id":NSUserName()?:@"local-user"},@"source":src,
    @"classification":@{@"payloadClass":sensitive?@"secret-blocked":@"metadata",@"secretLikeDetected":@(sensitive),@"persistentWriteRequiresApproval":@YES},
    @"text":sensitive?@"<REDACTED-SENSITIVE-MEMORY-CANDIDATE>":text?:@"",
    @"policy":@{@"decision":@"hold",@"decisionId":[@"local-" stringByAppendingString:BBRandomHex(8)],@"mode":@"local-default",@"reason":@"Candidates require explicit commit or reject."}
  }));
  BBEmitEvent(@"memory.candidate_created",@"hold",@"Held memory candidate.",@{@"memoryId":memId,@"url":srcURL?:@""});
}

// ── Layout constants ──────────────────────────────────────────────────────────
static const CGFloat kToolbarH  = 52.0;
static const CGFloat kTabBarH   = 36.0;
static const CGFloat kFindBarH  = 44.0;
static const CGFloat kBMBarH    = 30.0;
static const CGFloat kDLPanelW  = 280.0;
static const CGFloat kTabMaxW   = 220.0;
static const CGFloat kTabPinnedW = 36.0;  // fixed width for pinned tabs (icon-only)
static const CGFloat kTabMinW   = 80.0;
static const CGFloat kTabHardMinW = 44.0; // favicon-only floor when many tabs are open
static const CGFloat kTabCompactW = 72.0; // below this width a tab drops its title/close (favicon-only)

// ── BBTab ─────────────────────────────────────────────────────────────────────
@interface BBTab : NSObject
@property(strong) WKWebView *webView;
@property(copy)   NSString  *title;
@property(strong) NSImage   *favicon;
@property(assign) BOOL       isLoading;
@property(assign) BOOL       isPrivate;
@property(assign) NSInteger  dialogCount;
@property(assign) BOOL       dialogsSuppressed;
// Tab suspension — frees WKWebView memory for background tabs
@property(assign) BOOL       suspended;
@property(copy)   NSString  *suspendedURL;    // URL to reload on wake
@property(strong) NSDate    *lastActiveAt;    // nil = never focused
@property(assign) BOOL       muted;           // JS-level audio/video mute
@property(assign) BOOL       pinned;          // pinned = fixed-width icon-only, no Cmd+W
@property(assign) BOOL       isPlayingAudio;  // page has active audio (tab badge)
@property(assign) BOOL       genpassOffered;  // password-generator prompt already shown for this page load
@property(assign) BOOL       translateOffered;// translate prompt already shown for this page load
@property(assign) BOOL       editableFocus;   // last-known editable focus state (for native spell-check fallback)
@property(copy)   NSString  *groupName;       // tab group label (nil/"" = no group)
@property(assign) NSInteger  groupColorIdx;   // 0..7 color slot; only relevant when groupName set
@property(assign) BOOL       collapsedInGroup;// when YES, render as a small group-color chip
@end
@implementation BBTab
- (instancetype)init { self=[super init]; _title=@"New Tab"; _lastActiveAt=[NSDate date]; return self; }
@end

// ── BBTabItemView ─────────────────────────────────────────────────────────────
@protocol BBTabItemDelegate <NSObject>
- (void)tabItemDidSelect:(NSInteger)index;
- (void)tabItemDidClose:(NSInteger)index;
@optional
- (void)tabItemDidMiddleClick:(NSInteger)index;       // middle-click closes (Chrome)
- (NSMenu *)tabItemContextMenu:(NSInteger)index;      // right-click tab menu
- (void)tabItemMovedFrom:(NSInteger)from to:(NSInteger)to; // drag-to-reorder
- (void)tabBarDidDropURL:(NSString *)urlString;            // URL dragged onto tab strip
- (void)tabItemDidHoverEnter:(NSInteger)index fromView:(NSView *)view;
- (void)tabItemDidHoverExit:(NSInteger)index;
@end

@interface BBTabItemView : NSView
@property(assign) NSInteger index;
@property(nonatomic,assign) BOOL isActive;
@property(nonatomic,assign) BOOL isHovered;
@property(nonatomic,assign) BOOL isPrivate;
@property(assign) BOOL compact; // favicon-only mode for very narrow tabs
@property(strong) NSImageView *faviconView;
@property(strong) NSProgressIndicator *loadingSpinner;
@property(strong) NSTextField *titleLabel;
@property(strong) NSButton    *closeButton;
@property(strong) NSColor    *groupColor;
@property(weak)   id<BBTabItemDelegate> delegate;
- (void)setTabTitle:(NSString *)title favicon:(NSImage *)favicon loading:(BOOL)loading;
@end

@implementation BBTabItemView
- (instancetype)initWithFrame:(NSRect)f index:(NSInteger)idx delegate:(id<BBTabItemDelegate>)d {
  self=[super initWithFrame:f]; _index=idx; _delegate=d;
  _compact=(f.size.width < kTabCompactW);
  [self addTrackingArea:[[NSTrackingArea alloc]initWithRect:self.bounds
    options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect
    owner:self userInfo:nil]];
  // Favicon (16×16). Centered in compact mode, left-aligned otherwise.
  CGFloat favX=_compact?floor((f.size.width-16)/2):8;
  _faviconView=[[NSImageView alloc]initWithFrame:NSMakeRect(favX,10,16,16)];
  _faviconView.imageScaling=NSImageScaleProportionallyUpOrDown;
  if (_compact) _faviconView.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin;
  [self addSubview:_faviconView];
  // Animated loading spinner (overlaps favicon, hidden when not loading).
  _loadingSpinner=[[NSProgressIndicator alloc]initWithFrame:NSMakeRect(favX,10,16,16)];
  _loadingSpinner.style=NSProgressIndicatorStyleSpinning;
  _loadingSpinner.controlSize=NSControlSizeMini; _loadingSpinner.hidden=YES;
  if (_compact) _loadingSpinner.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin;
  [self addSubview:_loadingSpinner];
  // Title — hidden in compact mode.
  _titleLabel=[[NSTextField alloc]initWithFrame:NSMakeRect(28,8,MAX(0,f.size.width-54),20)];
  _titleLabel.autoresizingMask=NSViewWidthSizable;
  _titleLabel.bordered=NO; _titleLabel.editable=NO; _titleLabel.selectable=NO;
  _titleLabel.backgroundColor=[NSColor clearColor];
  _titleLabel.font=[NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
  _titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
  _titleLabel.hidden=_compact;
  [self addSubview:_titleLabel];
  // Close button — hidden in compact mode unless active/hovered (toggled below).
  _closeButton=[[NSButton alloc]initWithFrame:NSMakeRect(f.size.width-26,9,18,18)];
  _closeButton.autoresizingMask=NSViewMinXMargin;
  _closeButton.bezelStyle=NSBezelStyleCircular; _closeButton.bordered=NO;
  NSImage *xi=[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close Tab"];
  xi=[xi imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:8 weight:NSFontWeightMedium]];
  [xi setTemplate:YES]; _closeButton.image=xi; _closeButton.imagePosition=NSImageOnly;
  _closeButton.target=self; _closeButton.action=@selector(closeTab:); _closeButton.toolTip=@"Close Tab";
  _closeButton.hidden=_compact; // shown on hover in compact mode
  [self addSubview:_closeButton];
  self.toolTip=@""; // set in setTabTitle so narrow/compact tabs still reveal their title
  return self;
}
- (void)setTabTitle:(NSString *)title favicon:(NSImage *)favicon loading:(BOOL)loading {
  self.titleLabel.stringValue=title.length?title:@"New Tab";
  self.toolTip=title.length?title:@"New Tab"; // reveals full title on narrow/compact tabs
  self.titleLabel.textColor=self.isActive?[NSColor labelColor]:[NSColor secondaryLabelColor];
  if (loading && !self.isPrivate) {
    // Animated NSProgressIndicator beats the static SF symbol
    self.faviconView.hidden=YES;
    self.loadingSpinner.hidden=NO;
    [self.loadingSpinner startAnimation:nil];
  } else {
    [self.loadingSpinner stopAnimation:nil];
    self.loadingSpinner.hidden=YES;
    self.faviconView.hidden=NO;
    if (self.isPrivate) {
      NSImage *priv=[NSImage imageWithSystemSymbolName:@"eyeglasses" accessibilityDescription:@"Private"];
      [priv setTemplate:YES]; self.faviconView.image=priv;
    } else if (favicon) {
      self.faviconView.image=favicon;
    } else {
      NSImage *globe=[NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:@"Page"];
      [globe setTemplate:YES]; self.faviconView.image=globe;
    }
  }
}
- (void)setIsActive:(BOOL)active {
  _isActive=active; [self setNeedsDisplay:YES];
  self.titleLabel.textColor=active?[NSColor labelColor]:[NSColor secondaryLabelColor];
  self.titleLabel.font=[NSFont systemFontOfSize:12 weight:active?NSFontWeightMedium:NSFontWeightRegular];
}
- (void)drawRect:(NSRect)r {
  if (self.isActive) {
    [[NSColor windowBackgroundColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:7 yRadius:7] fill];
    [[NSColor separatorColor] setStroke];
    NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:7 yRadius:7];
    p.lineWidth=0.5; [p stroke];
    if (self.isPrivate) {
      [[NSColor colorWithRed:0.2 green:0.1 blue:0.3 alpha:0.12] setFill];
      [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:7 yRadius:7] fill];
    }
  } else if (self.isHovered) {
    [[NSColor colorWithWhite:0.5 alpha:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:7 yRadius:7] fill];
  }
  // Tab-group indicator: 3px coloured bar at the bottom edge.
  if (self.groupColor) {
    [self.groupColor setFill];
    NSRect bar=NSMakeRect(2,1,self.bounds.size.width-4,3);
    [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1.5 yRadius:1.5] fill];
  }
}
- (void)mouseEntered:(NSEvent *)e {
  self.isHovered=YES;  [self setNeedsDisplay:YES];
  // In compact mode reveal the close button (over the favicon) on hover.
  if (self.compact) { self.closeButton.hidden=NO; self.faviconView.hidden=YES; }
  if ([self.delegate respondsToSelector:@selector(tabItemDidHoverEnter:fromView:)])
    [self.delegate tabItemDidHoverEnter:self.index fromView:self];
}
- (void)mouseExited:(NSEvent *)e  {
  self.isHovered=NO;   [self setNeedsDisplay:YES];
  if (self.compact) { self.closeButton.hidden=YES; self.faviconView.hidden=NO; }
  if ([self.delegate respondsToSelector:@selector(tabItemDidHoverExit:)])
    [self.delegate tabItemDidHoverExit:self.index];
}
- (void)mouseDown:(NSEvent *)e {
  // Run a tracking loop on the live item FIRST (selecting up front would reload the
  // bar and destroy this view mid-gesture). If the user drags past a threshold we
  // live-reorder; otherwise it's a plain click and we select on mouse-up. This lets
  // any tab — active or not — be dragged immediately, Chrome-style.
  NSView *strip=self.superview;
  NSInteger count=0; for (NSView *v in strip.subviews) if ([v isKindOfClass:[BBTabItemView class]]) count++;
  BOOL canReorder=(strip && count>=2 && [self.delegate respondsToSelector:@selector(tabItemMovedFrom:to:)]);
  CGFloat stride=self.frame.size.width+2;
  NSPoint start=e.locationInWindow; CGFloat startX=self.frame.origin.x;
  BOOL dragging=NO; NSInteger from=self.index, target=from;
  while (1) {
    NSEvent *ev=[self.window nextEventMatchingMask:NSEventMaskLeftMouseUp|NSEventMaskLeftMouseDragged];
    if (!ev || ev.type==NSEventTypeLeftMouseUp) break;
    if (!canReorder) continue;
    CGFloat dx=ev.locationInWindow.x-start.x;
    if (!dragging && fabs(dx)>5) { dragging=YES; [strip addSubview:self positioned:NSWindowAbove relativeTo:nil]; self.alphaValue=0.9; }
    if (dragging) {
      NSRect fr=self.frame; fr.origin.x=startX+dx; self.frame=fr;
      target=(NSInteger)llround((fr.origin.x+fr.size.width/2)/stride);
      if (target<0) target=0; if (target>count-1) target=count-1;
    }
  }
  self.alphaValue=1.0;
  if (dragging && target!=from) [self.delegate tabItemMovedFrom:from to:target];
  else [self.delegate tabItemDidSelect:from]; // plain click selects (or snaps back)
}
- (void)otherMouseDown:(NSEvent *)e {
  if (e.buttonNumber==2) [self.delegate tabItemDidMiddleClick:self.index]; // middle-click closes
}
- (void)rightMouseDown:(NSEvent *)e {
  if (![self.delegate respondsToSelector:@selector(tabItemContextMenu:)]) return;
  NSMenu *m=[self.delegate tabItemContextMenu:self.index];
  if (m) [NSMenu popUpContextMenu:m withEvent:e forView:self];
}
- (void)closeTab:(id)s            { [self.delegate tabItemDidClose:self.index]; }
@end

// ── BBChromeBGView ─────────────────────────────────────────────────────────────
// Background fill that resolves at draw time — never set CGColor at init time
// since NSColor.windowBackgroundColor.CGColor is nil before the view has a window.
@interface BBChromeBGView : NSView @end
@implementation BBChromeBGView
- (void)drawRect:(NSRect)r { [[NSColor windowBackgroundColor] setFill]; NSRectFill(r); }
@end

// ── BBTabBarView ──────────────────────────────────────────────────────────────
// NSVisualEffectView with Sidebar material (NOT Titlebar — no click interception).
@interface BBTabBarView : NSVisualEffectView<BBTabItemDelegate>
@property(strong) NSMutableArray<BBTabItemView *> *items;
@property(assign) NSInteger activeIndex;
@property(strong) NSButton *addTabButton;
@property(strong) NSScrollView *tabScroll;   // horizontal scroller for overflow
@property(strong) NSView *tabStrip;          // document view holding the tab items
@property(weak)   id<BBTabItemDelegate> outerDelegate;
- (void)reloadWithTabs:(NSArray<BBTab *> *)tabs activeIndex:(NSInteger)active;
@end
@implementation BBTabBarView
- (instancetype)initWithFrame:(NSRect)f delegate:(id<BBTabItemDelegate>)d {
  self=[super initWithFrame:f];
  self.material=NSVisualEffectMaterialSidebar;
  self.blendingMode=NSVisualEffectBlendingModeWithinWindow;
  self.state=NSVisualEffectStateActive;
  NSBox *sep=[[NSBox alloc]initWithFrame:NSMakeRect(0,0,f.size.width,1)];
  sep.autoresizingMask=NSViewWidthSizable; sep.boxType=NSBoxSeparator; [self addSubview:sep];
  _items=[NSMutableArray array]; _outerDelegate=d;
  // Tab strip lives in a horizontal scroll view so a large number of tabs scroll
  // (Chrome-style) instead of shrinking to unreadable slivers.
  _tabScroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,1,f.size.width-40,f.size.height-2)];
  _tabScroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  _tabScroll.drawsBackground=NO; _tabScroll.hasVerticalScroller=NO;
  _tabScroll.hasHorizontalScroller=YES; _tabScroll.scrollerStyle=NSScrollerStyleOverlay;
  _tabScroll.horizontalScrollElasticity=NSScrollElasticityAllowed;
  _tabScroll.verticalScrollElasticity=NSScrollElasticityNone;
  _tabStrip=[[NSView alloc]initWithFrame:NSMakeRect(0,0,f.size.width-40,f.size.height-2)];
  _tabScroll.documentView=_tabStrip;
  [self addSubview:_tabScroll];
  _addTabButton=[[NSButton alloc]initWithFrame:NSMakeRect(f.size.width-34,4,28,28)];
  _addTabButton.autoresizingMask=NSViewMinXMargin;
  NSImage *pi=[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New Tab"];
  pi=[pi imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]];
  [pi setTemplate:YES]; _addTabButton.image=pi; _addTabButton.imagePosition=NSImageOnly;
  _addTabButton.bezelStyle=NSBezelStyleToolbar; _addTabButton.bordered=NO;
  _addTabButton.toolTip=@"New Tab (⌘T)"; [self addSubview:_addTabButton];
  // Accept URL drags onto the tab bar — open dropped URLs as new tabs (Chrome parity).
  [self registerForDraggedTypes:@[NSPasteboardTypeURL,NSPasteboardTypeString]];
  return self;
}
- (void)reloadWithTabs:(NSArray<BBTab *> *)tabs activeIndex:(NSInteger)active {
  for (BBTabItemView *v in self.items) [v removeFromSuperview];
  [self.items removeAllObjects];
  self.activeIndex=active;
  CGFloat addX=self.bounds.size.width-34;
  self.addTabButton.frame=NSMakeRect(addX,4,28,28);
  CGFloat clipW=addX-2, clipH=self.bounds.size.height-2;
  self.tabScroll.frame=NSMakeRect(0,1,clipW,clipH);
  NSInteger count=tabs.count;
  if (!count) { self.tabStrip.frame=NSMakeRect(0,0,clipW,clipH); return; }

  // Pinned tabs occupy fixed kTabPinnedW each at the left; regular tabs share the rest.
  NSInteger pinnedCount=0;
  for (BBTab *t in tabs) if (t.pinned) pinnedCount++;
  NSInteger regularCount=count-pinnedCount;
  CGFloat pinnedTotalW=pinnedCount*kTabPinnedW;
  CGFloat availW=clipW-pinnedTotalW;
  CGFloat tabW=regularCount>0?MIN(kTabMaxW,MAX(kTabHardMinW,floor(availW/regularCount))):0;
  CGFloat regularTotalW=tabW*regularCount;
  CGFloat stripW=MAX(clipW, pinnedTotalW+regularTotalW);
  self.tabStrip.frame=NSMakeRect(0,0,stripW,clipH);

  BBTabItemView *activeItem=nil;
  CGFloat pinnedX=0, regularX=pinnedTotalW;
  NSInteger regularIdx=0;
  for (NSInteger i=0;i<count;i++) {
    BBTab *tab=tabs[i];
    CGFloat x, w;
    BOOL isPinned=tab.pinned;
    if (isPinned) {
      x=pinnedX; w=kTabPinnedW-2; pinnedX+=kTabPinnedW;
    } else {
      x=regularX;
      BOOL isLast=(regularIdx==regularCount-1);
      w=isLast?MAX(kTabHardMinW-2,floor(pinnedTotalW+regularTotalW)-x-2):floor(tabW)-2;
      regularX+=floor(tabW); regularIdx++;
    }
    BBTabItemView *item=[[BBTabItemView alloc]initWithFrame:NSMakeRect(x,0,w,clipH) index:i delegate:self];
    item.isActive=(i==active); item.isPrivate=tab.isPrivate;
    if (tab.groupName.length) {
      static NSArray<NSColor *> *_palette=nil; static dispatch_once_t _o; dispatch_once(&_o,^{
        _palette=@[[NSColor systemBlueColor],[NSColor systemRedColor],[NSColor systemGreenColor],
                   [NSColor systemOrangeColor],[NSColor systemPurpleColor],[NSColor systemTealColor],
                   [NSColor systemPinkColor],[NSColor systemYellowColor]];
      });
      item.groupColor=_palette[((NSUInteger)tab.groupColorIdx)%_palette.count];
    }
    if (isPinned) { item.compact=YES; item.closeButton.hidden=YES; } // pinned = icon-only, no close
    // Override favicon: 💤 suspended, 🔇 muted, 🔊 playing audio
    NSImage *fav=tab.favicon;
    if (tab.suspended && !tab.isLoading) {
      fav=[NSImage imageWithSystemSymbolName:@"moon.zzz" accessibilityDescription:@"Suspended"];
      [fav setTemplate:YES];
    } else if (tab.muted) {
      fav=[NSImage imageWithSystemSymbolName:@"speaker.slash.fill" accessibilityDescription:@"Muted"];
      [fav setTemplate:YES];
    } else if (tab.isPlayingAudio) {
      fav=[NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:@"Playing Audio"];
      [fav setTemplate:YES];
    }
    [item setTabTitle:(isPinned?@"":tab.title) favicon:fav loading:tab.isLoading];
    [self.tabStrip addSubview:item]; [self.items addObject:item];
    if (i==active) activeItem=item;
  }
  if (activeItem && stripW>clipW)
    [self.tabStrip scrollRectToVisible:NSInsetRect(activeItem.frame,-tabW,0)];
}
- (void)tabItemDidSelect:(NSInteger)i { [self.outerDelegate tabItemDidSelect:i]; }
- (void)tabItemDidClose:(NSInteger)i  { [self.outerDelegate tabItemDidClose:i]; }
- (void)tabItemDidHoverEnter:(NSInteger)i fromView:(NSView *)v {
  if ([self.outerDelegate respondsToSelector:@selector(tabItemDidHoverEnter:fromView:)])
    [self.outerDelegate tabItemDidHoverEnter:i fromView:v];
}
- (void)tabItemDidHoverExit:(NSInteger)i {
  if ([self.outerDelegate respondsToSelector:@selector(tabItemDidHoverExit:)])
    [self.outerDelegate tabItemDidHoverExit:i];
}
- (void)tabItemDidMiddleClick:(NSInteger)i {
  if ([self.outerDelegate respondsToSelector:@selector(tabItemDidMiddleClick:)]) [self.outerDelegate tabItemDidMiddleClick:i];
}
- (NSMenu *)tabItemContextMenu:(NSInteger)i {
  return [self.outerDelegate respondsToSelector:@selector(tabItemContextMenu:)] ? [self.outerDelegate tabItemContextMenu:i] : nil;
}
- (void)tabItemMovedFrom:(NSInteger)from to:(NSInteger)to {
  if ([self.outerDelegate respondsToSelector:@selector(tabItemMovedFrom:to:)]) [self.outerDelegate tabItemMovedFrom:from to:to];
}
// Double-click on the empty tab-strip area opens a new tab (Chrome behavior).
- (void)mouseDown:(NSEvent *)e {
  if (e.clickCount==2) {
    NSPoint pt=[self.tabStrip convertPoint:e.locationInWindow fromView:nil];
    BOOL onTab=NO;
    for (NSView *v in self.tabStrip.subviews) {
      if ([v isKindOfClass:[BBTabItemView class]] && NSPointInRect(pt,v.frame)) { onTab=YES; break; }
    }
    if (!onTab) [NSApp sendAction:self.addTabButton.action to:self.addTabButton.target from:self];
  }
  [super mouseDown:e];
}
// Drag-and-drop: open dropped URLs (from another app, a link in the page, etc.) as new tabs.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  NSPasteboard *pb=sender.draggingPasteboard;
  if ([pb canReadObjectForClasses:@[[NSURL class]] options:nil]) return NSDragOperationCopy;
  if ([pb canReadObjectForClasses:@[[NSString class]] options:nil]) return NSDragOperationCopy;
  return NSDragOperationNone;
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSPasteboard *pb=sender.draggingPasteboard;
  NSArray *urls=[pb readObjectsForClasses:@[[NSURL class]] options:nil];
  NSString *dropped=nil;
  if (urls.count) dropped=[urls.firstObject absoluteString];
  else {
    NSArray *strs=[pb readObjectsForClasses:@[[NSString class]] options:nil];
    if (strs.count) dropped=[strs.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  }
  if (!dropped.length) return NO;
  if ([self.outerDelegate respondsToSelector:@selector(tabBarDidDropURL:)])
    [self.outerDelegate tabBarDidDropURL:dropped];
  return YES;
}
@end

// ── BBFindBar ─────────────────────────────────────────────────────────────────
@interface BBFindBar : NSView
@property(strong) NSTextField *queryField;
@property(strong) NSTextField *resultLabel;
@property(strong) NSButton *prevButton, *nextButton, *closeButton;
@end
@implementation BBFindBar
- (instancetype)initWithFrame:(NSRect)f {
  self=[super initWithFrame:f]; self.wantsLayer=YES;
  self.layer.backgroundColor=[NSColor windowBackgroundColor].CGColor;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:)
    name:NSSystemColorsDidChangeNotification object:nil];
  NSBox *sep=[[NSBox alloc]initWithFrame:NSMakeRect(0,f.size.height-1,f.size.width,1)];
  sep.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin; sep.boxType=NSBoxSeparator;
  [self addSubview:sep];
  CGFloat x=10, y=9;
  _closeButton=[[NSButton alloc]initWithFrame:NSMakeRect(x,y,22,22)]; x+=28;
  NSImage *xi=[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"Close"];
  [xi setTemplate:YES]; _closeButton.image=xi; _closeButton.imagePosition=NSImageOnly;
  _closeButton.bezelStyle=NSBezelStyleToolbar; _closeButton.bordered=NO; [self addSubview:_closeButton];
  _queryField=[[NSTextField alloc]initWithFrame:NSMakeRect(x,y,240,26)];
  _queryField.bezelStyle=NSTextFieldRoundedBezel; _queryField.placeholderString=@"Find on page";
  _queryField.font=[NSFont systemFontOfSize:13]; [self addSubview:_queryField]; x+=246;
  _prevButton=[[NSButton alloc]initWithFrame:NSMakeRect(x,y,28,26)]; x+=30;
  NSImage *ui=[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous"];
  ui=[ui imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium]];
  [ui setTemplate:YES]; _prevButton.image=ui; _prevButton.imagePosition=NSImageOnly;
  _prevButton.bezelStyle=NSBezelStyleToolbar; _prevButton.bordered=YES; [self addSubview:_prevButton];
  _nextButton=[[NSButton alloc]initWithFrame:NSMakeRect(x,y,28,26)]; x+=36;
  NSImage *di=[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next"];
  di=[di imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium]];
  [di setTemplate:YES]; _nextButton.image=di; _nextButton.imagePosition=NSImageOnly;
  _nextButton.bezelStyle=NSBezelStyleToolbar; _nextButton.bordered=YES; [self addSubview:_nextButton];
  _resultLabel=[[NSTextField alloc]initWithFrame:NSMakeRect(x,y+2,120,22)];
  _resultLabel.bordered=NO; _resultLabel.editable=NO; _resultLabel.selectable=NO;
  _resultLabel.backgroundColor=[NSColor clearColor]; _resultLabel.font=[NSFont systemFontOfSize:12];
  _resultLabel.textColor=[NSColor secondaryLabelColor]; _resultLabel.stringValue=@"";
  [self addSubview:_resultLabel];
  return self;
}
- (void)themeChanged:(NSNotification *)n { self.layer.backgroundColor=[NSColor windowBackgroundColor].CGColor; }
@end

// ── BBBookmarksStore ──────────────────────────────────────────────────────────
@interface BBBookmark : NSObject
@property(copy) NSString *title, *urlString;
@property(strong) NSDate *addedAt;
@property(copy) NSString *folder;  // nil/"" = bookmarks bar root; otherwise folder name (one level deep)
@end
@implementation BBBookmark
@end

// ── BBPasswordStore ───────────────────────────────────────────────────────────
// Keychain-backed login save/fill. One Keychain item per (host, username) pair,
// kSecClass=GenericPassword, service="BearBrowser-login:<host>", account=<username>,
// data=<password UTF-8>. macOS Keychain handles encryption-at-rest + user gating
// (login keychain unlocks automatically; if Touch ID/passcode is required on this
// Mac, the system prompts on first access per session — we never see the password
// outside the moment we fill it into a page form).
@interface BBPasswordEntry : NSObject
@property(copy) NSString *host, *username, *password;
@end
@implementation BBPasswordEntry
@end
@interface BBPasswordStore : NSObject
+ (instancetype)shared;
- (NSString *)serviceForHost:(NSString *)host;
- (BOOL)saveHost:(NSString *)host username:(NSString *)user password:(NSString *)pass;
- (NSArray<BBPasswordEntry *> *)entriesForHost:(NSString *)host;
- (BOOL)removeHost:(NSString *)host username:(NSString *)user;
- (NSArray<BBPasswordEntry *> *)allEntries;  // for Settings → Saved Passwords
@end
@implementation BBPasswordStore
+ (instancetype)shared { static BBPasswordStore *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (NSString *)serviceForHost:(NSString *)host {
  NSString *h=host.lowercaseString?:@"";
  if ([h hasPrefix:@"www."]) h=[h substringFromIndex:4];
  return [@"BearBrowser-login:" stringByAppendingString:h];
}
- (BOOL)saveHost:(NSString *)host username:(NSString *)user password:(NSString *)pass {
  if (!host.length||!user.length||!pass.length) return NO;
  NSString *svc=[self serviceForHost:host];
  NSData *pwData=[pass dataUsingEncoding:NSUTF8StringEncoding];
  // Delete any existing item for (svc, user) so we can update-by-recreate.
  NSDictionary *del=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                      (__bridge id)kSecAttrService:svc,
                      (__bridge id)kSecAttrAccount:user};
  SecItemDelete((__bridge CFDictionaryRef)del);
  NSDictionary *add=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                      (__bridge id)kSecAttrService:svc,
                      (__bridge id)kSecAttrAccount:user,
                      (__bridge id)kSecValueData:pwData,
                      (__bridge id)kSecAttrLabel:[NSString stringWithFormat:@"BearBrowser — %@",host]};
  OSStatus rc=SecItemAdd((__bridge CFDictionaryRef)add,NULL);
  return rc==errSecSuccess;
}
- (NSArray<BBPasswordEntry *> *)entriesForHost:(NSString *)host {
  if (!host.length) return @[];
  NSString *svc=[self serviceForHost:host];
  NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService:svc,
                    (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitAll,
                    (__bridge id)kSecReturnAttributes:@YES,
                    (__bridge id)kSecReturnData:@YES};
  CFTypeRef result=NULL;
  OSStatus rc=SecItemCopyMatching((__bridge CFDictionaryRef)q,&result);
  if (rc!=errSecSuccess||!result) return @[];
  NSArray *items=(__bridge_transfer NSArray *)result;
  NSMutableArray *out=[NSMutableArray array];
  for (NSDictionary *d in items) {
    BBPasswordEntry *e=[BBPasswordEntry new];
    e.host=host;
    e.username=d[(__bridge id)kSecAttrAccount]?:@"";
    NSData *pwData=d[(__bridge id)kSecValueData];
    e.password=pwData?[[NSString alloc]initWithData:pwData encoding:NSUTF8StringEncoding]:@"";
    if (e.username.length && e.password.length) [out addObject:e];
  }
  return out;
}
- (BOOL)removeHost:(NSString *)host username:(NSString *)user {
  if (!host.length||!user.length) return NO;
  NSDictionary *del=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                      (__bridge id)kSecAttrService:[self serviceForHost:host],
                      (__bridge id)kSecAttrAccount:user};
  return SecItemDelete((__bridge CFDictionaryRef)del)==errSecSuccess;
}
- (NSArray<BBPasswordEntry *> *)allEntries {
  NSDictionary *q=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitAll,
                    (__bridge id)kSecReturnAttributes:@YES};
  CFTypeRef result=NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)q,&result)!=errSecSuccess||!result) return @[];
  NSArray *items=(__bridge_transfer NSArray *)result;
  NSMutableArray *out=[NSMutableArray array];
  for (NSDictionary *d in items) {
    NSString *svc=d[(__bridge id)kSecAttrService]?:@"";
    if (![svc hasPrefix:@"BearBrowser-login:"]) continue;
    BBPasswordEntry *e=[BBPasswordEntry new];
    e.host=[svc substringFromIndex:18];
    e.username=d[(__bridge id)kSecAttrAccount]?:@"";
    e.password=@""; // listing doesn't fetch passwords (avoid bulk Keychain prompts)
    [out addObject:e];
  }
  return out;
}
@end

// ── BBProfileStore ────────────────────────────────────────────────────────────
// One stored "address profile" (name, email, phone, street, city, region, postal,
// country, organization). Lives in NSUserDefaults at BBProfile_v1 — non-sensitive
// PII (compared to passwords) and the user already chose to type these values into
// forms once. Filled into matching autocomplete-tagged fields on focus.
@interface BBProfile : NSObject
@property(copy) NSString *name, *email, *phone;
@property(copy) NSString *street, *city, *region, *postal, *country, *organization;
- (NSDictionary *)toDict;
+ (instancetype)fromDict:(NSDictionary *)d;
- (BOOL)isEmpty;
@end
@implementation BBProfile
- (NSDictionary *)toDict {
  return @{@"name":_name?:@"",@"email":_email?:@"",@"phone":_phone?:@"",
           @"street":_street?:@"",@"city":_city?:@"",@"region":_region?:@"",
           @"postal":_postal?:@"",@"country":_country?:@"",@"organization":_organization?:@""};
}
+ (instancetype)fromDict:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]]) return nil;
  BBProfile *p=[BBProfile new];
  p.name=d[@"name"]; p.email=d[@"email"]; p.phone=d[@"phone"];
  p.street=d[@"street"]; p.city=d[@"city"]; p.region=d[@"region"];
  p.postal=d[@"postal"]; p.country=d[@"country"]; p.organization=d[@"organization"];
  return p;
}
- (BOOL)isEmpty {
  return !(_name.length||_email.length||_phone.length||_street.length||_city.length||
           _region.length||_postal.length||_country.length||_organization.length);
}
@end
@interface BBProfileStore : NSObject
+ (instancetype)shared;
- (BBProfile *)profile;
- (void)setProfile:(BBProfile *)p;
@end
@implementation BBProfileStore {
  BBProfile *_p;
}
+ (instancetype)shared { static BBProfileStore *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (instancetype)init {
  self=[super init];
  NSDictionary *d=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BBProfile_v1"];
  _p=[BBProfile fromDict:d]?:[BBProfile new];
  return self;
}
- (BBProfile *)profile { return _p; }
- (void)setProfile:(BBProfile *)p {
  _p=p?:[BBProfile new];
  [[NSUserDefaults standardUserDefaults] setObject:[_p toDict] forKey:@"BBProfile_v1"];
}
@end

// Datasource/delegate for the Saved Passwords table in Settings → Manage Saved Passwords.
@interface BBSavedPasswordsDS : NSObject <NSTableViewDataSource,NSTableViewDelegate>
@property(strong) NSMutableArray<BBPasswordEntry *> *entries;
@property(weak)   NSTableView *tv;
- (instancetype)initWithEntries:(NSMutableArray<BBPasswordEntry *> *)e tableView:(NSTableView *)tv;
- (void)removeSelected:(id)sender;
@end
@implementation BBSavedPasswordsDS
- (instancetype)initWithEntries:(NSMutableArray<BBPasswordEntry *> *)e tableView:(NSTableView *)tv {
  self=[super init]; _entries=e?:[NSMutableArray array]; _tv=tv; return self;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return _entries.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  if (row<0||row>=(NSInteger)_entries.count) return nil;
  BBPasswordEntry *e=_entries[row];
  NSTextField *t=[NSTextField labelWithString:[col.identifier isEqualToString:@"site"]?e.host:e.username];
  t.font=[NSFont systemFontOfSize:12]; return t;
}
- (void)removeSelected:(id)sender {
  NSInteger row=_tv.selectedRow; if (row<0||row>=(NSInteger)_entries.count) return;
  BBPasswordEntry *e=_entries[row];
  [[BBPasswordStore shared] removeHost:e.host username:e.username];
  [_entries removeObjectAtIndex:row]; [_tv reloadData];
}
@end

@interface BBBookmarksStore : NSObject
@property(strong) NSMutableArray<BBBookmark *> *items;
+ (instancetype)shared;
- (void)addTitle:(NSString *)t url:(NSString *)u;
- (void)addTitle:(NSString *)t url:(NSString *)u folder:(NSString *)f;
- (NSArray<NSString *> *)folders;
- (void)setFolder:(NSString *)f forURL:(NSString *)u;
- (void)removeAtIndex:(NSInteger)i;
- (void)removeURL:(NSString *)u;
- (BOOL)isBookmarked:(NSString *)u;
@end
@implementation BBBookmarksStore
+ (instancetype)shared { static BBBookmarksStore *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (instancetype)init {
  self=[super init]; _items=[NSMutableArray array];
  NSString *path=[BBSupportDir() stringByAppendingPathComponent:@"bookmarks.json"];
  NSData *d=[NSData dataWithContentsOfFile:path];
  if (d) for (NSDictionary *r in [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]) {
    BBBookmark *b=[BBBookmark new]; b.title=r[@"title"]?:@""; b.urlString=r[@"url"]?:@"";
    b.addedAt=[NSDate dateWithTimeIntervalSince1970:[r[@"t"] doubleValue]];
    b.folder=r[@"folder"]?:@"";
    [_items addObject:b];
  }
  return self;
}
- (void)addTitle:(NSString *)t url:(NSString *)u {
  [self addTitle:t url:u folder:nil];
}
- (void)addTitle:(NSString *)t url:(NSString *)u folder:(NSString *)f {
  BBBookmark *b=[BBBookmark new]; b.title=t?:@""; b.urlString=u?:@""; b.addedAt=[NSDate date];
  b.folder=f?:@"";
  [self.items addObject:b]; [self save];
}
- (NSArray<NSString *> *)folders {
  NSMutableOrderedSet *set=[NSMutableOrderedSet orderedSet];
  for (BBBookmark *b in self.items) if (b.folder.length) [set addObject:b.folder];
  return [set array];
}
- (void)setFolder:(NSString *)f forURL:(NSString *)u {
  for (BBBookmark *b in self.items) if ([b.urlString isEqualToString:u]) b.folder=f?:@"";
  [self save];
}
- (void)removeAtIndex:(NSInteger)i { if(i>=0&&i<(NSInteger)self.items.count){[self.items removeObjectAtIndex:i];[self save];} }
- (void)removeURL:(NSString *)u {
  for (NSInteger i=(NSInteger)self.items.count-1;i>=0;i--) if([self.items[i].urlString isEqualToString:u]){[self.items removeObjectAtIndex:i];}
  [self save];
}
- (BOOL)isBookmarked:(NSString *)u { for(BBBookmark *b in self.items) if([b.urlString isEqualToString:u]) return YES; return NO; }
- (void)save {
  NSMutableArray *arr=[NSMutableArray array];
  for (BBBookmark *b in self.items) [arr addObject:@{@"title":b.title?:@"",@"url":b.urlString?:@"",@"t":@(b.addedAt.timeIntervalSince1970),@"folder":b.folder?:@""}];
  NSData *d=[NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
  [[NSFileManager defaultManager] createDirectoryAtPath:BBSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
  [d writeToFile:[BBSupportDir() stringByAppendingPathComponent:@"bookmarks.json"] atomically:YES];
}
@end

// ── BBReadingList ─────────────────────────────────────────────────────────────
// Persistent "save for later" list, distinct from bookmarks: items have a read/
// unread state, and the UI defaults to unread. Stored at readinglist.json.
@interface BBReadingItem : NSObject
@property(copy) NSString *title, *urlString;
@property(strong) NSDate *addedAt;
@property(assign) BOOL    read;
@end
@implementation BBReadingItem
@end
@interface BBReadingList : NSObject
@property(strong) NSMutableArray<BBReadingItem *> *items;
+ (instancetype)shared;
- (void)addTitle:(NSString *)t url:(NSString *)u;
- (void)removeAtIndex:(NSInteger)i;
- (void)toggleReadAtIndex:(NSInteger)i;
- (NSInteger)unreadCount;
- (BOOL)contains:(NSString *)u;
- (void)save;
@end
@implementation BBReadingList
+ (instancetype)shared { static BBReadingList *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (instancetype)init {
  self=[super init]; _items=[NSMutableArray array];
  NSData *d=[NSData dataWithContentsOfFile:[BBSupportDir() stringByAppendingPathComponent:@"readinglist.json"]];
  if (d) for (NSDictionary *r in [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]) {
    BBReadingItem *it=[BBReadingItem new];
    it.title=r[@"title"]?:@""; it.urlString=r[@"url"]?:@"";
    it.addedAt=[NSDate dateWithTimeIntervalSince1970:[r[@"t"] doubleValue]];
    it.read=[r[@"read"] boolValue];
    [_items addObject:it];
  }
  return self;
}
- (void)addTitle:(NSString *)t url:(NSString *)u {
  if (!u.length) return;
  for (BBReadingItem *it in _items) if ([it.urlString isEqualToString:u]) return; // de-dupe
  BBReadingItem *it=[BBReadingItem new];
  it.title=t.length?t:u; it.urlString=u; it.addedAt=[NSDate date]; it.read=NO;
  [_items addObject:it]; [self save];
}
- (void)removeAtIndex:(NSInteger)i { if(i>=0&&i<(NSInteger)_items.count){[_items removeObjectAtIndex:i];[self save];} }
- (void)toggleReadAtIndex:(NSInteger)i { if(i>=0&&i<(NSInteger)_items.count){_items[i].read=!_items[i].read;[self save];} }
- (NSInteger)unreadCount { NSInteger n=0; for (BBReadingItem *it in _items) if (!it.read) n++; return n; }
- (BOOL)contains:(NSString *)u { for (BBReadingItem *it in _items) if ([it.urlString isEqualToString:u]) return YES; return NO; }
- (void)save {
  NSMutableArray *arr=[NSMutableArray array];
  for (BBReadingItem *it in _items) [arr addObject:@{@"title":it.title?:@"",@"url":it.urlString?:@"",
    @"t":@(it.addedAt.timeIntervalSince1970),@"read":@(it.read)}];
  NSData *d=[NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
  [[NSFileManager defaultManager] createDirectoryAtPath:BBSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
  [d writeToFile:[BBSupportDir() stringByAppendingPathComponent:@"readinglist.json"] atomically:YES];
}
@end

// Datasource/delegate for the Settings → Site Data manager. Asynchronously
// fetches all WKWebsiteDataRecords, groups by display name (domain), supports
// case-insensitive filter, and deletes per-record on demand.
@interface BBSiteDataDS : NSObject <NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate>
@property(strong) NSMutableArray<WKWebsiteDataRecord *> *all, *shown;
@property(weak) NSTableView *tv;
@property(weak) NSSearchField *sf;
- (instancetype)initWithTableView:(NSTableView *)tv searchField:(NSSearchField *)sf;
- (void)reload;
- (void)removeSelected;
- (void)removeAll;
@end
@implementation BBSiteDataDS
- (instancetype)initWithTableView:(NSTableView *)tv searchField:(NSSearchField *)sf {
  self=[super init]; _tv=tv; _sf=sf; _all=[NSMutableArray array]; _shown=[NSMutableArray array]; return self;
}
- (void)reload {
  NSSet *all=[WKWebsiteDataStore allWebsiteDataTypes];
  [[WKWebsiteDataStore defaultDataStore] fetchDataRecordsOfTypes:all completionHandler:^(NSArray<WKWebsiteDataRecord *> *recs){
    NSArray *sorted=[recs sortedArrayUsingComparator:^NSComparisonResult(WKWebsiteDataRecord *a,WKWebsiteDataRecord *b){
      return [a.displayName caseInsensitiveCompare:b.displayName];
    }];
    self.all=[sorted mutableCopy];
    [self applyFilter];
  }];
}
- (void)applyFilter {
  NSString *q=self.sf.stringValue.lowercaseString?:@"";
  if (!q.length) { self.shown=[self.all mutableCopy]; }
  else {
    NSMutableArray *out=[NSMutableArray array];
    for (WKWebsiteDataRecord *r in self.all) if ([r.displayName.lowercaseString containsString:q]) [out addObject:r];
    self.shown=out;
  }
  [self.tv reloadData];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return self.shown.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  if (row<0||row>=(NSInteger)self.shown.count) return nil;
  WKWebsiteDataRecord *r=self.shown[row];
  if ([col.identifier isEqualToString:@"domain"]) {
    NSTextField *f=[NSTextField labelWithString:r.displayName?:@""];
    f.font=[NSFont systemFontOfSize:12]; return f;
  }
  // Summarise the type set (Cookies/Local Storage/IndexedDB/Cache).
  NSMutableArray *parts=[NSMutableArray array];
  if ([r.dataTypes containsObject:WKWebsiteDataTypeCookies])           [parts addObject:@"cookies"];
  if ([r.dataTypes containsObject:WKWebsiteDataTypeLocalStorage])      [parts addObject:@"local"];
  if ([r.dataTypes containsObject:WKWebsiteDataTypeIndexedDBDatabases])[parts addObject:@"indexedDB"];
  if ([r.dataTypes containsObject:WKWebsiteDataTypeDiskCache])         [parts addObject:@"cache"];
  if ([r.dataTypes containsObject:WKWebsiteDataTypeServiceWorkerRegistrations]) [parts addObject:@"sw"];
  if (!parts.count) [parts addObject:@(r.dataTypes.count).stringValue];
  NSTextField *f=[NSTextField labelWithString:[parts componentsJoinedByString:@", "]];
  f.font=[NSFont systemFontOfSize:11]; f.textColor=[NSColor secondaryLabelColor];
  return f;
}
- (void)searchFieldDidEndSearching:(NSSearchField *)sender { [self applyFilter]; }
- (void)controlTextDidChange:(NSNotification *)n { if (n.object==self.sf) [self applyFilter]; }
- (void)removeSelected {
  NSInteger row=self.tv.selectedRow; if (row<0||row>=(NSInteger)self.shown.count) return;
  WKWebsiteDataRecord *r=self.shown[row];
  [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:r.dataTypes forDataRecords:@[r] completionHandler:^{
    dispatch_async(dispatch_get_main_queue(),^{ [self reload]; });
  }];
}
- (void)removeAll {
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Remove all site data?";
  a.informativeText=@"Cookies, local storage, IndexedDB, cache, and service workers for every site will be erased.";
  [a addButtonWithTitle:@"Remove All"]; [a addButtonWithTitle:@"Cancel"];
  if ([a runModal]!=NSAlertFirstButtonReturn) return;
  NSSet *all=[WKWebsiteDataStore allWebsiteDataTypes];
  [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:all modifiedSince:[NSDate distantPast] completionHandler:^{
    dispatch_async(dispatch_get_main_queue(),^{ [self reload]; });
  }];
}
@end

// Datasource/delegate for the Reading List sheet (defined here so it can see
// BBReadingItem/BBReadingList declared just above).
@interface BBReadingListDS : NSObject <NSTableViewDataSource,NSTableViewDelegate>
@property(weak) WKWebView *webView;
@property(weak) NSWindow *win;
@property(weak) NSTableView *tv;
- (instancetype)initWithWebView:(WKWebView *)wv window:(NSWindow *)w tableView:(NSTableView *)tv;
- (void)openSelected;
- (void)removeSelected;
- (void)toggleReadSelected;
@end
@implementation BBReadingListDS
- (instancetype)initWithWebView:(WKWebView *)wv window:(NSWindow *)w tableView:(NSTableView *)tv {
  self=[super init]; _webView=wv; _win=w; _tv=tv; return self;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return [BBReadingList shared].items.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  NSArray<BBReadingItem *> *items=[BBReadingList shared].items;
  if (row<0||row>=(NSInteger)items.count) return nil;
  BBReadingItem *it=items[row];
  if ([col.identifier isEqualToString:@"read"]) {
    NSImageView *iv=[[NSImageView alloc]initWithFrame:NSMakeRect(0,0,18,18)];
    NSImage *img=[NSImage imageWithSystemSymbolName:it.read?@"checkmark.circle.fill":@"circle" accessibilityDescription:@"Read"];
    [img setTemplate:YES]; iv.image=img;
    return iv;
  }
  NSTextField *f=[NSTextField labelWithString:[col.identifier isEqualToString:@"title"]?(it.title?:it.urlString):it.urlString];
  f.font=[NSFont systemFontOfSize:12];
  f.textColor=it.read?[NSColor tertiaryLabelColor]:[NSColor labelColor];
  return f;
}
- (void)openSelected {
  NSInteger row=_tv.selectedRow; NSArray<BBReadingItem *> *items=[BBReadingList shared].items;
  if (row<0||row>=(NSInteger)items.count) return;
  NSURL *u=[NSURL URLWithString:items[row].urlString]; if (!u) return;
  [_webView loadRequest:[NSURLRequest requestWithURL:u]];
  if (!items[row].read) { [[BBReadingList shared] toggleReadAtIndex:row]; [_tv reloadData]; }
  [_win.sheetParent endSheet:_win];
}
- (void)removeSelected {
  NSInteger row=_tv.selectedRow;
  [[BBReadingList shared] removeAtIndex:row];
  [_tv reloadData];
}
- (void)toggleReadSelected {
  NSInteger row=_tv.selectedRow;
  [[BBReadingList shared] toggleReadAtIndex:row];
  [_tv reloadData];
}
@end

// ── BBResearchSession ─────────────────────────────────────────────────────────
// A named pile of URLs with per-item status. Not bookmarks — designed for
// research workflows: open 500 tabs, collapse to a session, curate, hand to agent.
typedef NS_ENUM(NSInteger, BBResearchStatus) {
  BBResearchStatusUnread=0, BBResearchStatusReading, BBResearchStatusDone, BBResearchStatusDismissed
};
@interface BBResearchItem : NSObject
@property(copy)   NSString         *urlString;
@property(copy)   NSString         *title;
@property(copy)   NSString         *note;        // user annotation
@property(assign) BBResearchStatus  status;
@property(strong) NSDate           *addedAt;
- (NSDictionary *)toDict;
+ (BBResearchItem *)fromDict:(NSDictionary *)d;
@end
@implementation BBResearchItem
- (NSDictionary *)toDict {
  return @{@"url":_urlString?:@"",@"title":_title?:@"",@"note":_note?:@"",
           @"status":@(_status),@"t":@(_addedAt.timeIntervalSince1970)};
}
+ (BBResearchItem *)fromDict:(NSDictionary *)d {
  BBResearchItem *it=[BBResearchItem new];
  it.urlString=d[@"url"]?:@""; it.title=d[@"title"]?:@""; it.note=d[@"note"]?:@"";
  it.status=(BBResearchStatus)[d[@"status"] integerValue];
  it.addedAt=[NSDate dateWithTimeIntervalSince1970:[d[@"t"] doubleValue]];
  return it;
}
@end

@interface BBResearchSession : NSObject
@property(copy)   NSString                       *name;
@property(strong) NSMutableArray<BBResearchItem*> *items;
@property(strong) NSDate                          *createdAt;
- (NSDictionary *)toDict;
+ (BBResearchSession *)fromDict:(NSDictionary *)d;
- (NSUInteger)unreadCount;
- (NSString *)exportMarkdown;
@end
@implementation BBResearchSession
- (instancetype)initWithName:(NSString *)name {
  self=[super init]; _name=name; _items=[NSMutableArray array]; _createdAt=[NSDate date]; return self;
}
- (NSDictionary *)toDict {
  NSMutableArray *arr=[NSMutableArray array];
  for (BBResearchItem *it in _items) [arr addObject:[it toDict]];
  return @{@"name":_name?:@"",@"t":@(_createdAt.timeIntervalSince1970),@"items":arr};
}
+ (BBResearchSession *)fromDict:(NSDictionary *)d {
  BBResearchSession *s=[[BBResearchSession alloc] initWithName:d[@"name"]?:@"Session"];
  s.createdAt=[NSDate dateWithTimeIntervalSince1970:[d[@"t"] doubleValue]];
  for (NSDictionary *id_ in d[@"items"]) [s.items addObject:[BBResearchItem fromDict:id_]];
  return s;
}
- (NSUInteger)unreadCount {
  NSUInteger n=0; for (BBResearchItem *it in _items) if(it.status==BBResearchStatusUnread) n++; return n;
}
- (NSString *)exportMarkdown {
  NSMutableString *md=[NSMutableString string];
  [md appendFormat:@"# %@\n\n",_name];
  static NSArray *labels; if(!labels) labels=@[@"☐",@"…",@"✓",@"✗"];
  for (BBResearchItem *it in _items) {
    [md appendFormat:@"- %@ [%@](%@)",labels[it.status],it.title.length?it.title:it.urlString,it.urlString];
    if (it.note.length) [md appendFormat:@"  \n  > %@",it.note];
    [md appendString:@"\n"];
  }
  return md;
}
@end

@interface BBResearchStore : NSObject
@property(strong) NSMutableArray<BBResearchSession*> *sessions;
+ (instancetype)shared;
- (void)save;
- (BBResearchSession *)sessionNamed:(NSString *)name create:(BOOL)create;
@end
@implementation BBResearchStore
+ (instancetype)shared { static BBResearchStore *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (instancetype)init {
  self=[super init]; _sessions=[NSMutableArray array];
  NSString *path=[BBSupportDir() stringByAppendingPathComponent:@"research-sessions.json"];
  NSData *d=[NSData dataWithContentsOfFile:path];
  if (d) for (NSDictionary *r in [NSJSONSerialization JSONObjectWithData:d options:0 error:nil])
    [_sessions addObject:[BBResearchSession fromDict:r]];
  return self;
}
- (void)save {
  NSMutableArray *arr=[NSMutableArray array];
  for (BBResearchSession *s in _sessions) [arr addObject:[s toDict]];
  NSData *d=[NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
  [[NSFileManager defaultManager] createDirectoryAtPath:BBSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
  [d writeToFile:[BBSupportDir() stringByAppendingPathComponent:@"research-sessions.json"] atomically:YES];
}
- (BBResearchSession *)sessionNamed:(NSString *)name create:(BOOL)create {
  for (BBResearchSession *s in _sessions) if ([s.name isEqualToString:name]) return s;
  if (!create) return nil;
  BBResearchSession *s=[[BBResearchSession alloc] initWithName:name];
  [_sessions addObject:s]; [self save]; return s;
}
@end

// ── BBHistoryStore ────────────────────────────────────────────────────────────
@interface BBHistoryEntry : NSObject
@property(copy) NSString *title, *urlString;
@property(strong) NSDate *visitedAt;
@end
@implementation BBHistoryEntry
@end

@interface BBHistoryStore : NSObject
@property(strong) NSMutableArray<BBHistoryEntry *> *entries; // newest-last, capped 20k
+ (instancetype)shared;
- (void)recordTitle:(NSString *)t url:(NSString *)u;
- (void)updateTitle:(NSString *)t forURL:(NSString *)u;
- (void)clearAll;
- (NSArray<BBHistoryEntry *> *)search:(NSString *)q limit:(NSInteger)n;
@end
@implementation BBHistoryStore
+ (instancetype)shared { static BBHistoryStore *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (instancetype)init {
  self=[super init]; _entries=[NSMutableArray array];
  NSString *path=[[BBSupportDir() stringByAppendingPathComponent:@"history"] stringByAppendingPathComponent:@"history.jsonl"];
  NSString *raw=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  NSArray *lines=[raw componentsSeparatedByString:@"\n"];
  NSInteger start=MAX(0,(NSInteger)lines.count-20000);
  for (NSInteger i=start;i<(NSInteger)lines.count;i++) {
    NSData *d=[lines[i] dataUsingEncoding:NSUTF8StringEncoding]; if(!d.length) continue;
    NSDictionary *obj=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; if(!obj) continue;
    BBHistoryEntry *e=[BBHistoryEntry new]; e.urlString=obj[@"url"]?:@""; e.title=obj[@"title"]?:@"";
    e.visitedAt=[NSDate dateWithTimeIntervalSince1970:[obj[@"t"] doubleValue]];
    [_entries addObject:e];
  }
  return self;
}
- (void)persist:(BBHistoryEntry *)e {
  NSString *dir=[BBSupportDir() stringByAppendingPathComponent:@"history"];
  BBAppendLine([dir stringByAppendingPathComponent:@"history.jsonl"],
    BBJSON(@{@"url":e.urlString,@"title":e.title?:@"",@"t":@(e.visitedAt.timeIntervalSince1970)}));
}
- (void)recordTitle:(NSString *)t url:(NSString *)u {
  if (!u.length||[u hasPrefix:@"bearbrowser://"]) return;
  // Collapse a reload / immediate re-visit of the same URL into the existing
  // entry instead of stacking duplicate consecutive rows.
  BBHistoryEntry *last=self.entries.lastObject;
  if (last && [last.urlString isEqualToString:u]) {
    if (t.length) last.title=t;
    last.visitedAt=[NSDate date];
    [self persist:last];
    return;
  }
  BBHistoryEntry *e=[BBHistoryEntry new]; e.title=t?:@""; e.urlString=u; e.visitedAt=[NSDate date];
  [self.entries addObject:e]; if(self.entries.count>20000) [self.entries removeObjectAtIndex:0];
  [self persist:e];
}
// The page title usually arrives (via title KVO) AFTER didFinishNavigation already
// recorded the visit with an empty/placeholder title. Patch the latest matching entry.
- (void)updateTitle:(NSString *)t forURL:(NSString *)u {
  if (!t.length||!u.length||[u hasPrefix:@"bearbrowser://"]) return;
  for (NSInteger i=self.entries.count-1;i>=0;i--) {
    BBHistoryEntry *e=self.entries[i];
    if (![e.urlString isEqualToString:u]) continue;
    if ([e.title isEqualToString:t]) return;   // already current
    e.title=t; [self persist:e]; return;
  }
}
- (void)clearAll {
  [self.entries removeAllObjects];
  NSString *path=[[BBSupportDir() stringByAppendingPathComponent:@"history"] stringByAppendingPathComponent:@"history.jsonl"];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}
- (NSArray<BBHistoryEntry *> *)search:(NSString *)q limit:(NSInteger)n {
  if(!q.length) return @[];
  NSString *ql=[q lowercaseString]; NSMutableArray *r=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set];
  for (NSInteger i=self.entries.count-1;i>=0&&(NSInteger)r.count<n;i--) {
    BBHistoryEntry *e=self.entries[i];
    if([seen containsObject:e.urlString]) continue;
    if([[e.urlString lowercaseString] containsString:ql]||[[e.title lowercaseString] containsString:ql])
      { [r addObject:e]; [seen addObject:e.urlString]; }
  }
  return r;
}
@end

// ── BBDownloadItem + BBDownloadPanel ──────────────────────────────────────────
typedef NS_ENUM(NSInteger, BBDownloadState) { BBDownloadStatePending, BBDownloadStateActive, BBDownloadStateDone, BBDownloadStateFailed };

@interface BBDownloadItem : NSObject
@property(copy)   NSString *filename;
@property(strong) NSURL    *destURL;
@property(assign) long long  totalBytes, writtenBytes;
@property(assign) BBDownloadState state;
@property(copy)   NSString *errorMessage;
@property(strong) WKDownload *download;
@property(strong) NSDate *startedAt;
@end
@implementation BBDownloadItem
@end

@interface BBDownloadPanel : NSView
@property(strong) NSMutableArray<BBDownloadItem *> *items;
@property(strong) NSScrollView *scroll;
@property(strong) NSStackView  *stack;
@property(strong) NSTimer      *pollTimer;
- (void)addItem:(BBDownloadItem *)item;
- (void)refresh;
- (void)show;
- (void)hide;
@end

@implementation BBDownloadPanel
- (instancetype)initWithFrame:(NSRect)f {
  self=[super initWithFrame:f];
  self.wantsLayer=YES; self.layer.backgroundColor=[NSColor windowBackgroundColor].CGColor;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:)
    name:NSSystemColorsDidChangeNotification object:nil];
  _items=[NSMutableArray array];
  // Header
  NSTextField *hdr=[[NSTextField alloc]initWithFrame:NSMakeRect(12,f.size.height-36,f.size.width-24,24)];
  hdr.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  hdr.stringValue=@"Downloads"; hdr.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  hdr.bordered=NO; hdr.editable=NO; hdr.selectable=NO; hdr.backgroundColor=[NSColor clearColor];
  [self addSubview:hdr];
  // Separator
  NSBox *sep=[[NSBox alloc]initWithFrame:NSMakeRect(0,f.size.height-38,f.size.width,1)];
  sep.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin; sep.boxType=NSBoxSeparator; [self addSubview:sep];
  // Scrollable stack
  _stack=[NSStackView new]; _stack.orientation=NSUserInterfaceLayoutOrientationVertical;
  _stack.alignment=NSLayoutAttributeLeading; _stack.spacing=1;
  _stack.translatesAutoresizingMaskIntoConstraints=NO;
  _scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,f.size.width,f.size.height-40)];
  _scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  _scroll.hasVerticalScroller=YES; _scroll.drawsBackground=NO;
  _scroll.documentView=_stack; [self addSubview:_scroll];
  [NSLayoutConstraint activateConstraints:@[
    [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentView.leadingAnchor],
    [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentView.trailingAnchor],
    [_stack.topAnchor constraintEqualToAnchor:_scroll.contentView.topAnchor],
  ]];
  return self;
}
- (void)themeChanged:(NSNotification *)n { self.layer.backgroundColor=[NSColor windowBackgroundColor].CGColor; }
- (void)updateDockBadge {
  NSInteger active=0;
  for (BBDownloadItem *it in self.items) if (it.state==BBDownloadStateActive) active++;
  [NSApp dockTile].badgeLabel=active>0?[NSString stringWithFormat:@"%ld",(long)active]:@"";
}
- (void)addItem:(BBDownloadItem *)item {
  [self.items addObject:item];
  if (!self.pollTimer) self.pollTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(pollFileSizes) userInfo:nil repeats:YES];
  [self updateDockBadge]; [self refresh]; [self show];
}
- (void)pollFileSizes {
  BOOL anyActive=NO;
  for (BBDownloadItem *item in self.items) {
    if (item.state==BBDownloadStateActive && item.destURL) {
      NSDictionary *attr=[[NSFileManager defaultManager] attributesOfItemAtPath:item.destURL.path error:nil];
      if (attr) item.writtenBytes=[attr[NSFileSize] longLongValue];
      anyActive=YES;
    }
  }
  if (!anyActive) { [self.pollTimer invalidate]; self.pollTimer=nil; }
  dispatch_async(dispatch_get_main_queue(),^{ [self updateDockBadge]; [self refresh]; });
}
- (void)refresh {
  for (NSView *v in self.stack.arrangedSubviews) [self.stack removeArrangedSubview:v];
  for (NSView *v in self.stack.arrangedSubviews.copy) [v removeFromSuperview];
  for (BBDownloadItem *item in self.items.reverseObjectEnumerator.allObjects) {
    NSView *row=[self rowForItem:item]; [self.stack addArrangedSubview:row];
    [NSLayoutConstraint activateConstraints:@[
      [row.leadingAnchor constraintEqualToAnchor:self.stack.leadingAnchor],
      [row.trailingAnchor constraintEqualToAnchor:self.stack.trailingAnchor],
      [row.heightAnchor constraintEqualToConstant:68],
    ]];
  }
}
- (NSView *)rowForItem:(BBDownloadItem *)item {
  NSView *row=[[NSView alloc]initWithFrame:NSZeroRect]; row.wantsLayer=YES;
  row.layer.backgroundColor=[NSColor controlBackgroundColor].CGColor;
  // Filename
  NSTextField *name=[[NSTextField alloc]initWithFrame:NSZeroRect];
  name.translatesAutoresizingMaskIntoConstraints=NO;
  name.stringValue=item.filename?:@"file"; name.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
  name.bordered=NO; name.editable=NO; name.selectable=NO; name.backgroundColor=[NSColor clearColor];
  name.lineBreakMode=NSLineBreakByTruncatingMiddle; [row addSubview:name];
  // Status label
  NSTextField *status=[[NSTextField alloc]initWithFrame:NSZeroRect];
  status.translatesAutoresizingMaskIntoConstraints=NO;
  status.stringValue=[self statusStringForItem:item];
  status.font=[NSFont systemFontOfSize:11]; status.textColor=[NSColor secondaryLabelColor];
  status.bordered=NO; status.editable=NO; status.selectable=NO; status.backgroundColor=[NSColor clearColor];
  [row addSubview:status];
  // Progress bar
  NSProgressIndicator *bar=[[NSProgressIndicator alloc]initWithFrame:NSZeroRect];
  bar.translatesAutoresizingMaskIntoConstraints=NO;
  bar.style=NSProgressIndicatorStyleBar; bar.minValue=0; bar.maxValue=1;
  bar.controlSize=NSControlSizeSmall;
  double pct=(item.totalBytes>0)?(double)item.writtenBytes/item.totalBytes:(item.state==BBDownloadStateDone?1.0:0.0);
  bar.indeterminate=(item.state==BBDownloadStateActive&&item.totalBytes<=0);
  bar.doubleValue=pct; if(bar.indeterminate)[bar startAnimation:nil];
  bar.hidden=(item.state==BBDownloadStateFailed);
  [row addSubview:bar];
  // Action button
  NSButton *btn=[[NSButton alloc]initWithFrame:NSZeroRect];
  btn.translatesAutoresizingMaskIntoConstraints=NO;
  btn.bezelStyle=NSBezelStyleToolbar; btn.bordered=NO;
  NSString *sym=(item.state==BBDownloadStateDone)?@"arrow.down.circle.fill":
                (item.state==BBDownloadStateFailed)?@"arrow.clockwise":@"xmark.circle";
  NSImage *img=[NSImage imageWithSystemSymbolName:sym accessibilityDescription:@"Action"];
  img=[img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]];
  [img setTemplate:YES]; btn.image=img;
  btn.target=self; btn.action=@selector(downloadAction:);
  // tag = display row index (0 = newest shown at top)
  NSInteger displayIdx=[self.items.reverseObjectEnumerator.allObjects indexOfObject:item];
  btn.tag=(displayIdx==NSNotFound)?0:(NSInteger)displayIdx;
  [row addSubview:btn];
  // Layout
  [NSLayoutConstraint activateConstraints:@[
    [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
    [name.trailingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:-4],
    [name.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
    [status.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
    [status.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],
    [status.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],
    [bar.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
    [bar.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],
    [bar.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:5],
    [btn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
    [btn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [btn.widthAnchor constraintEqualToConstant:28],
    [btn.heightAnchor constraintEqualToConstant:28],
  ]];
  return row;
}
- (NSString *)statusStringForItem:(BBDownloadItem *)item {
  if (item.state==BBDownloadStateFailed) return item.errorMessage?:@"Failed";
  if (item.state==BBDownloadStateDone) return [NSString stringWithFormat:@"Done — %@",[self sizeStr:item.writtenBytes]];
  if (item.totalBytes>0) return [NSString stringWithFormat:@"%@ of %@",[self sizeStr:item.writtenBytes],[self sizeStr:item.totalBytes]];
  return item.writtenBytes>0?[self sizeStr:item.writtenBytes]:@"Waiting…";
}
- (NSString *)sizeStr:(long long)b {
  if(b<1024) return [NSString stringWithFormat:@"%lld B",b];
  if(b<1024*1024) return [NSString stringWithFormat:@"%.1f KB",(double)b/1024];
  if(b<1024*1024*1024) return [NSString stringWithFormat:@"%.1f MB",(double)b/(1024*1024)];
  return [NSString stringWithFormat:@"%.2f GB",(double)b/(1024*1024*1024)];
}
- (void)downloadAction:(NSButton *)btn {
  NSInteger idx=self.items.count-1-btn.tag; // rows displayed newest-first
  if(idx<0||idx>=(NSInteger)self.items.count) return;
  BBDownloadItem *item=self.items[idx];
  if (item.state==BBDownloadStateDone && item.destURL) {
    // Offer Open + Show in Finder (Chrome's completed-download menu).
    NSMenu *m=[[NSMenu alloc]init];
    NSMenuItem *o=[m addItemWithTitle:@"Open" action:@selector(dlOpen:) keyEquivalent:@""];
    o.target=self; o.representedObject=item.destURL;
    NSMenuItem *r=[m addItemWithTitle:@"Show in Finder" action:@selector(dlReveal:) keyEquivalent:@""];
    r.target=self; r.representedObject=item.destURL;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(btn.bounds)) inView:btn];
  }
  else if (item.state==BBDownloadStateFailed)
    { item.state=BBDownloadStateActive; [self refresh]; }
  else if (item.download)
    [item.download cancel:^(NSData *rd){}];
}
- (void)dlOpen:(NSMenuItem *)s   { if([s.representedObject isKindOfClass:[NSURL class]]) [[NSWorkspace sharedWorkspace] openURL:s.representedObject]; }
- (void)dlReveal:(NSMenuItem *)s { if([s.representedObject isKindOfClass:[NSURL class]]) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[s.representedObject]]; }
- (void)show { self.hidden=NO; }
- (void)hide { self.hidden=YES; }
@end

// ── BBSearch ──────────────────────────────────────────────────────────────────
// Search-engine registry. Declared here (before the address dropdown) so the
// dropdown can route suggestions to the chosen engine. BBDelegate exposes thin
// wrappers (searchEngines / searchEngineName / searchURLForQuery:) over this.
@interface BBSearch : NSObject
+ (NSArray<NSDictionary*> *)engines;
+ (NSString *)engineName;
+ (NSString *)urlForQuery:(NSString *)q;
+ (NSString *)urlForKeywordQuery:(NSString *)raw;
+ (NSString *)keywordLabel:(NSString *)raw;
+ (NSString *)calculatorResultForQuery:(NSString *)q;
@end
@implementation BBSearch
+ (NSArray<NSDictionary*> *)engines {
  return @[
    @{@"name":@"DuckDuckGo",  @"id":@"ddg",    @"url":@"https://duckduckgo.com/?q=%@"},
    @{@"name":@"Kagi",        @"id":@"kagi",   @"url":@"https://kagi.com/search?q=%@"},
    @{@"name":@"Brave",       @"id":@"brave",  @"url":@"https://search.brave.com/search?q=%@"},
    @{@"name":@"Startpage",   @"id":@"start",  @"url":@"https://www.startpage.com/search?q=%@"},
  ];
}
+ (NSString *)engineName {
  NSString *eid=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBSearchEngine"]?:@"ddg";
  for (NSDictionary *e in [self engines]) if ([e[@"id"] isEqualToString:eid]) return e[@"name"];
  return @"DuckDuckGo";
}
+ (NSString *)urlForQuery:(NSString *)q {
  NSString *eid=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBSearchEngine"]?:@"ddg";
  NSString *enc=[q stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]?:@"";
  for (NSDictionary *e in [self engines])
    if ([e[@"id"] isEqualToString:eid]) return [NSString stringWithFormat:e[@"url"],enc];
  return [NSString stringWithFormat:@"https://duckduckgo.com/?q=%@",enc];
}
// Type "wiki foo" / "yt foo" / "gh foo" / "ddg foo" / "kagi foo" → site-scoped search.
// Returns nil if the input doesn't start with a recognised keyword + space.
+ (NSString *)urlForKeywordQuery:(NSString *)raw {
  NSRange sp=[raw rangeOfString:@" "];
  if (sp.location==NSNotFound||sp.location<1) return nil;
  NSString *kw=[[raw substringToIndex:sp.location] lowercaseString];
  NSString *rest=[[raw substringFromIndex:sp.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!rest.length) return nil;
  NSString *enc=[rest stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]?:@"";
  static NSDictionary *kws=nil; static dispatch_once_t o; dispatch_once(&o,^{
    kws=@{@"wiki":@"https://en.wikipedia.org/w/index.php?search=%@",
          @"yt":  @"https://www.youtube.com/results?search_query=%@",
          @"gh":  @"https://github.com/search?q=%@",
          @"npm": @"https://www.npmjs.com/search?q=%@",
          @"so":  @"https://stackoverflow.com/search?q=%@",
          @"mdn": @"https://developer.mozilla.org/en-US/search?q=%@",
          @"ddg": @"https://duckduckgo.com/?q=%@",
          @"kagi":@"https://kagi.com/search?q=%@",
          @"g":   @"https://www.google.com/search?q=%@",
          @"map": @"https://www.openstreetmap.org/search?query=%@",
          @"amzn":@"https://www.amazon.com/s?k=%@",
          @"hn":  @"https://hn.algolia.com/?q=%@"};
  });
  NSString *fmt=kws[kw]; if (!fmt) return nil;
  return [NSString stringWithFormat:fmt,enc];
}
+ (NSString *)keywordLabel:(NSString *)raw {
  NSRange sp=[raw rangeOfString:@" "]; if (sp.location==NSNotFound) return nil;
  NSString *kw=[[raw substringToIndex:sp.location] lowercaseString];
  static NSDictionary *labels=nil; static dispatch_once_t o; dispatch_once(&o,^{
    labels=@{@"wiki":@"Wikipedia",@"yt":@"YouTube",@"gh":@"GitHub",@"npm":@"npm",
             @"so":@"Stack Overflow",@"mdn":@"MDN",@"ddg":@"DuckDuckGo",@"kagi":@"Kagi",
             @"g":@"Google",@"map":@"OpenStreetMap",@"amzn":@"Amazon",@"hn":@"Hacker News"};
  });
  return labels[kw];
}
// Arithmetic-only expression → NSExpression-evaluated result; returns nil if it's
// not a pure arithmetic input. Restricts the grammar to digits/operators/whitespace
// to avoid mistaking URLs ("foo.com") for numeric exprs.
+ (NSString *)calculatorResultForQuery:(NSString *)q {
  NSString *trimmed=[q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmed.length<3) return nil;
  // Must contain at least one operator and only allowed characters.
  NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"0123456789.+-*/%()^ "];
  if ([trimmed rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) return nil;
  NSCharacterSet *ops=[NSCharacterSet characterSetWithCharactersInString:@"+-*/%^"];
  if ([trimmed rangeOfCharacterFromSet:ops].location==NSNotFound) return nil;
  // NSExpression treats "^" as XOR on integers — translate it to ** which works on doubles.
  NSString *expr=[trimmed stringByReplacingOccurrencesOfString:@"^" withString:@"**"];
  @try {
    NSExpression *e=[NSExpression expressionWithFormat:expr];
    id v=[e expressionValueWithObject:nil context:nil];
    if ([v isKindOfClass:[NSNumber class]]) {
      double d=[(NSNumber*)v doubleValue];
      if (isnan(d)||isinf(d)) return nil;
      if (d==floor(d) && fabs(d)<1e15) return [NSString stringWithFormat:@"%lld",(long long)d];
      return [NSString stringWithFormat:@"%g",d];
    }
  } @catch(...) {}
  return nil;
}
@end

// ── BBAddressField — NSTextField subclass with Paste-and-Go context menu ─────
@protocol BBAddressFieldDelegate <NSObject>
- (void)addressFieldPasteAndGo:(NSString *)url;
@end
@interface BBAddressField : NSTextField <NSDraggingSource>
@property(weak) id<BBAddressFieldDelegate> pasteDelegate;
@end
@implementation BBAddressField
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c {
  return NSDragOperationCopy;
}
- (void)mouseDown:(NSEvent *)e {
  // Only intercept when the field isn't currently being edited — preserve normal
  // text-editing click-to-focus behavior otherwise.
  if ([self.window firstResponder]==self || self.currentEditor) { [super mouseDown:e]; return; }
  NSPoint start=e.locationInWindow;
  // Walk events until drag threshold or release.
  NSEvent *evt=e;
  while (evt) {
    evt=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
    if (evt.type==NSEventTypeLeftMouseUp) { [super mouseDown:e]; return; }
    if (evt.type==NSEventTypeLeftMouseDragged) {
      NSPoint p=evt.locationInWindow;
      if (hypot(p.x-start.x,p.y-start.y)>6) break;
    }
  }
  // Initiate a drag carrying the current URL.
  NSString *url=self.stringValue;
  if (!url.length || [url rangeOfString:@" "].location!=NSNotFound) { [super mouseDown:e]; return; }
  NSPasteboardItem *pi=[[NSPasteboardItem alloc]init];
  if ([url hasPrefix:@"http"]||[url hasPrefix:@"file://"]) [pi setString:url forType:NSPasteboardTypeURL];
  [pi setString:url forType:NSPasteboardTypeString];
  NSDraggingItem *di=[[NSDraggingItem alloc]initWithPasteboardWriter:pi];
  NSImage *icon=[NSImage imageWithSystemSymbolName:@"link" accessibilityDescription:@"URL"];
  [di setDraggingFrame:NSMakeRect(start.x-16,start.y-16,32,32) contents:icon];
  [self beginDraggingSessionWithItems:@[di] event:e source:self];
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSMenu *m=[super menuForEvent:event];
  if (!m) m=[[NSMenu alloc]init];
  NSString *clip=[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
  if (clip.length) {
    [m insertItemWithTitle:@"Paste and Go" action:@selector(bbPasteAndGo:) keyEquivalent:@"" atIndex:0];
    [m itemAtIndex:0].target=self;
    [m insertItem:[NSMenuItem separatorItem] atIndex:1];
  }
  return m;
}
- (void)bbPasteAndGo:(id)s {
  NSString *clip=[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
  if (clip.length && self.pasteDelegate) [self.pasteDelegate addressFieldPasteAndGo:clip];
}
@end

// ── BBAddressDropdown ─────────────────────────────────────────────────────────
@interface BBAddressSuggestion : NSObject
@property(copy) NSString *title, *urlString, *badge; // badge: "Bookmark", "History", "Search"
@end
@implementation BBAddressSuggestion
@end

@protocol BBAddressDropdownDelegate <NSObject>
- (void)dropdownSelectedURL:(NSString *)urlString;
@end

// NSView-based overlay — no child window, no focus theft.
@interface BBAddressDropdown : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(strong) NSView      *overlay;     // lives in main window's contentView
@property(strong) NSTableView *table;
@property(strong) NSMutableArray<BBAddressSuggestion *> *suggestions;
@property(weak)   id<BBAddressDropdownDelegate> delegate;
@property(strong) NSTimer *ddgTimer;
@property(assign) BOOL remoteSuggestEnabled; // set per-keystroke by the owner (off in private / when disabled)
@property(strong) NSArray<NSDictionary *> *openTabsSnapshot; // owner sets before each updateForQuery
- (void)updateForQuery:(NSString *)q belowField:(NSTextField *)field inWindow:(NSWindow *)win;
- (void)hide;
- (BOOL)selectNext;
- (BOOL)selectPrev;
- (BOOL)confirmSelection;
@end

@implementation BBAddressDropdown
- (instancetype)init {
  self=[super init]; _suggestions=[NSMutableArray array];
  // Overlay container — added to contentView on first show
  _overlay=[[NSView alloc]initWithFrame:NSZeroRect];
  _overlay.wantsLayer=YES;
  _overlay.hidden=YES;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:)
    name:NSSystemColorsDidChangeNotification object:nil];
  NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:_overlay.bounds];
  scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  scroll.hasVerticalScroller=NO; scroll.drawsBackground=NO;
  _table=[[NSTableView alloc]init]; _table.headerView=nil;
  _table.rowHeight=40; _table.intercellSpacing=NSMakeSize(0,0);
  _table.backgroundColor=[NSColor clearColor];
  NSTableColumn *col=[[NSTableColumn alloc]initWithIdentifier:@"row"]; col.width=600;
  [_table addTableColumn:col]; _table.dataSource=self; _table.delegate=self;
  scroll.documentView=_table; [_overlay addSubview:scroll];
  return self;
}
- (void)themeChanged:(NSNotification *)n { [_overlay setNeedsDisplay:YES]; }
- (void)updateForQuery:(NSString *)q belowField:(NSTextField *)field inWindow:(NSWindow *)win {
  [_suggestions removeAllObjects];
  if (!q.length) { [self hide]; return; }
  // Calculator chip — pure arithmetic input renders the answer at the top of the dropdown.
  NSString *calc=[BBSearch calculatorResultForQuery:q];
  if (calc.length) {
    BBAddressSuggestion *s=[BBAddressSuggestion new];
    s.title=[NSString stringWithFormat:@"= %@",calc];
    s.urlString=calc; // selecting copies the answer (handled by the delegate's URL-load fallback)
    s.badge=@"∑"; [_suggestions addObject:s];
  }
  // Search-engine keywords: "wiki foo" → Wikipedia search row.
  NSString *kwLabel=[BBSearch keywordLabel:q];
  NSString *kwURL=kwLabel?[BBSearch urlForKeywordQuery:q]:nil;
  if (kwURL.length) {
    BBAddressSuggestion *s=[BBAddressSuggestion new];
    NSString *q2=[q substringFromIndex:[q rangeOfString:@" "].location+1];
    s.title=[NSString stringWithFormat:@"Search %@: %@",kwLabel,q2];
    s.urlString=kwURL; s.badge=@"⌕"; [_suggestions addObject:s];
  }
  // "Switch to this tab" — when a typed query matches an already-open tab.
  for (NSDictionary *t in self.openTabsSnapshot) {
    NSString *title=[t[@"title"] isKindOfClass:[NSString class]]?t[@"title"]:@"";
    NSString *url=[t[@"url"] isKindOfClass:[NSString class]]?t[@"url"]:@"";
    if ([title.lowercaseString containsString:q.lowercaseString] ||
        [url.lowercaseString   containsString:q.lowercaseString]) {
      BBAddressSuggestion *s=[BBAddressSuggestion new];
      s.title=[NSString stringWithFormat:@"Switch to tab: %@",title.length?title:url];
      s.urlString=[NSString stringWithFormat:@"bb-switch-tab:%@",t[@"idx"]];
      s.badge=@"⇄"; [_suggestions addObject:s];
      if (_suggestions.count>=2) break;
    }
  }
  // Bookmarks first
  for (BBBookmark *b in [BBBookmarksStore shared].items) {
    if ([[b.urlString lowercaseString] containsString:q.lowercaseString]||
        [[b.title lowercaseString] containsString:q.lowercaseString]) {
      BBAddressSuggestion *s=[BBAddressSuggestion new]; s.title=b.title; s.urlString=b.urlString; s.badge=@"★";
      [_suggestions addObject:s]; if(_suggestions.count>=3) break;
    }
  }
  // History
  for (BBHistoryEntry *e in [[BBHistoryStore shared] search:q limit:6]) {
    BBAddressSuggestion *s=[BBAddressSuggestion new]; s.title=e.title.length?e.title:e.urlString;
    s.urlString=e.urlString; s.badge=@"↺"; [_suggestions addObject:s];
    if(_suggestions.count>=9) break;
  }
  // Search row always last — routed to the user's chosen search engine.
  BBAddressSuggestion *search=[BBAddressSuggestion new];
  search.title=[NSString stringWithFormat:@"Search %@: %@",[BBSearch engineName],q];
  search.urlString=[BBSearch urlForQuery:q];
  search.badge=@"⌕"; [_suggestions addObject:search];
  [_table reloadData]; [_table deselectAll:nil];
  // Position overlay in contentView coordinates below the address field
  NSView *cv=win.contentView;
  if (_overlay.superview!=cv) [cv addSubview:_overlay positioned:NSWindowAbove relativeTo:nil];
  NSRect fieldInContent=[field.superview convertRect:field.frame toView:cv];
  CGFloat rowH=40; CGFloat h=MIN((CGFloat)_suggestions.count*rowH,280);
  _overlay.frame=NSMakeRect(fieldInContent.origin.x,
                            fieldInContent.origin.y-h,
                            fieldInContent.size.width, h);
  _overlay.hidden=NO;
  // Remote search-suggestions (privacy-sensitive: sends keystrokes to the suggest
  // endpoint). Only when enabled by the owner — off in private tabs or if the user
  // disabled it in Settings.
  [_ddgTimer invalidate];
  if (self.remoteSuggestEnabled) {
    NSString *qc=q;
    _ddgTimer=[NSTimer scheduledTimerWithTimeInterval:0.25 repeats:NO block:^(NSTimer *t){
      [self fetchDDGSuggestions:qc];
    }];
  }
}
- (void)fetchDDGSuggestions:(NSString *)q {
  NSString *eq=[q stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://duckduckgo.com/ac/?q=%@&type=list",eq]];
  [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *d,NSURLResponse *r,NSError *e){
    if(e||!d) return;
    NSArray *resp=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSArray *terms=(resp.count>1&&[resp[1] isKindOfClass:[NSArray class]])?resp[1]:@[];
    dispatch_async(dispatch_get_main_queue(),^{
      // Replace old DDG completions (not the search row) with fresh ones
      [self.suggestions removeObjectsAtIndexes:[self.suggestions indexesOfObjectsPassingTest:
        ^BOOL(BBAddressSuggestion *s,NSUInteger i,BOOL *stop){
          return [s.badge isEqualToString:@"⌕"] && ![s.title hasPrefix:@"Search DuckDuckGo"];}]];
      NSInteger ins=MAX(0,(NSInteger)self.suggestions.count-1);
      for (NSString *term in terms) {
        if(![term isKindOfClass:[NSString class]]||!term.length) continue;
        BBAddressSuggestion *s=[BBAddressSuggestion new]; s.title=term; s.badge=@"⌕";
        s.urlString=[BBSearch urlForQuery:term]; // route to the chosen engine
        if(ins<(NSInteger)self.suggestions.count) [self.suggestions insertObject:s atIndex:ins++];
        if(self.suggestions.count>=12) break;
      }
      if(terms.count) [self.table reloadData];
    });
  }] resume];
}
- (void)hide {
  [_ddgTimer invalidate]; _ddgTimer=nil;
  _overlay.hidden=YES; [_table deselectAll:nil];
}
- (BOOL)selectNext {
  if(!_suggestions.count||_overlay.hidden) return NO;
  NSInteger row=MIN(_table.selectedRow+1,(NSInteger)_suggestions.count-1);
  [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  [_table scrollRowToVisible:row]; return YES;
}
- (BOOL)selectPrev {
  if(!_suggestions.count||_overlay.hidden) return NO;
  NSInteger row=_table.selectedRow;
  if(row<=0){[_table deselectAll:nil];return YES;}
  row=MAX(row-1,0);
  [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  [_table scrollRowToVisible:row]; return YES;
}
- (BOOL)confirmSelection {
  NSInteger row=_table.selectedRow;
  if(row<0||row>=(NSInteger)_suggestions.count||_overlay.hidden) return NO;
  NSString *url=_suggestions[row].urlString;
  [self hide]; [self.delegate dropdownSelectedURL:url]; return YES;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return _suggestions.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  NSTableCellView *cell=[tv makeViewWithIdentifier:@"dd" owner:self];
  if (!cell) {
    cell=[[NSTableCellView alloc]initWithFrame:NSMakeRect(0,0,560,40)]; cell.identifier=@"dd";
    NSTextField *badge=[[NSTextField alloc]initWithFrame:NSMakeRect(8,10,20,20)];
    badge.tag=1; badge.bordered=NO; badge.editable=NO; badge.selectable=NO;
    badge.backgroundColor=[NSColor clearColor]; badge.font=[NSFont systemFontOfSize:11];
    badge.textColor=[NSColor tertiaryLabelColor]; badge.alignment=NSTextAlignmentCenter;
    [cell addSubview:badge];
    NSTextField *title=[[NSTextField alloc]initWithFrame:NSMakeRect(32,22,496,16)];
    title.tag=2; title.bordered=NO; title.editable=NO; title.selectable=NO;
    title.backgroundColor=[NSColor clearColor]; title.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    title.lineBreakMode=NSLineBreakByTruncatingTail; [cell addSubview:title];
    NSTextField *urlLbl=[[NSTextField alloc]initWithFrame:NSMakeRect(32,4,496,16)];
    urlLbl.tag=3; urlLbl.bordered=NO; urlLbl.editable=NO; urlLbl.selectable=NO;
    urlLbl.backgroundColor=[NSColor clearColor]; urlLbl.font=[NSFont systemFontOfSize:10];
    urlLbl.textColor=[NSColor secondaryLabelColor]; urlLbl.lineBreakMode=NSLineBreakByTruncatingTail;
    [cell addSubview:urlLbl];
  }
  BBAddressSuggestion *s=_suggestions[row];
  ((NSTextField *)[cell viewWithTag:1]).stringValue=s.badge?:@"";
  ((NSTextField *)[cell viewWithTag:2]).stringValue=s.title?:@"";
  ((NSTextField *)[cell viewWithTag:3]).stringValue=s.urlString?:@"";
  return cell;
}
- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row { return 40; }
- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row { return YES; }
- (void)tableViewSelectionDidChange:(NSNotification *)n {
  // Mouse click in the table — navigate immediately
  NSInteger row=_table.selectedRow;
  if(row>=0&&row<(NSInteger)_suggestions.count&&!_overlay.hidden)
    [self.delegate dropdownSelectedURL:_suggestions[row].urlString];
}
@end

// ── BBHistoryPanelDS ──────────────────────────────────────────────────────────
// A lightweight datasource/delegate for the history NSTableView.
@interface BBHistoryPanelDS : NSObject <NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate>
@property(strong) NSMutableArray<BBHistoryEntry *> *all, *shown;
@property(strong) NSTableView *tv;
@property(weak)   NSWindow    *win;
@property(weak)   WKWebView   *webView;
- (instancetype)initWithEntries:(NSMutableArray<BBHistoryEntry *> *)e tableView:(NSTableView *)tv searchField:(NSSearchField *)sf window:(NSWindow *)w webView:(WKWebView *)wv;
@end
@implementation BBHistoryPanelDS
- (instancetype)initWithEntries:(NSMutableArray<BBHistoryEntry *> *)e tableView:(NSTableView *)tv searchField:(NSSearchField *)sf window:(NSWindow *)w webView:(WKWebView *)wv {
  self=[super init]; _all=e; _shown=[e mutableCopy]; _tv=tv; _win=w; _webView=wv; return self;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return _shown.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  NSTextField *f=[tv makeViewWithIdentifier:col.identifier owner:self];
  if (!f) { f=[[NSTextField alloc]init]; f.identifier=col.identifier; f.bordered=NO; f.editable=NO; f.selectable=NO; f.backgroundColor=[NSColor clearColor]; f.lineBreakMode=NSLineBreakByTruncatingTail; }
  BBHistoryEntry *e=_shown[row];
  NSDateFormatter *df=[NSDateFormatter new]; df.timeStyle=NSDateFormatterShortStyle; df.dateStyle=NSDateFormatterShortStyle;
  if ([col.identifier isEqualToString:@"title"]) f.stringValue=e.title.length?e.title:e.urlString;
  else if ([col.identifier isEqualToString:@"url"]) f.stringValue=e.urlString;
  else f.stringValue=[df stringFromDate:e.visitedAt]?:@"";
  return f;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
  NSInteger row=_tv.selectedRow;
  if(row<0||row>=(NSInteger)_shown.count) return;
  NSURL *u=[NSURL URLWithString:_shown[row].urlString]; if(!u) return;
  [_webView loadRequest:[NSURLRequest requestWithURL:u]];
  [_win.sheetParent endSheet:_win]; [_win orderOut:nil];
}
- (void)controlTextDidChange:(NSNotification *)n {
  NSString *q=((NSSearchField *)n.object).stringValue;
  if(!q.length) { _shown=[_all mutableCopy]; [_tv reloadData]; return; }
  NSString *ql=q.lowercaseString;
  _shown=[[_all objectsAtIndexes:[_all indexesOfObjectsPassingTest:^BOOL(BBHistoryEntry *e,NSUInteger i,BOOL *s){
    return [[e.urlString lowercaseString] containsString:ql]||[[e.title lowercaseString] containsString:ql];
  }]] mutableCopy];
  [_tv reloadData];
}
@end

// ── BBBookmarksPanelDS ────────────────────────────────────────────────────────
// Datasource/delegate for the Bookmark Manager table. Reads the shared store live.
@interface BBBookmarksPanelDS : NSObject <NSTableViewDataSource,NSTableViewDelegate>
@property(strong) NSTableView *tv;
@property(weak)   NSWindow    *win;
@property(weak)   WKWebView   *webView;
@end
@implementation BBBookmarksPanelDS
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return [BBBookmarksStore shared].items.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  NSTextField *f=[tv makeViewWithIdentifier:col.identifier owner:self];
  if (!f) { f=[[NSTextField alloc]init]; f.identifier=col.identifier; f.bordered=NO; f.editable=NO; f.selectable=NO; f.backgroundColor=[NSColor clearColor]; f.lineBreakMode=NSLineBreakByTruncatingTail; }
  NSArray<BBBookmark*> *items=[BBBookmarksStore shared].items;
  if (row<0||row>=(NSInteger)items.count) { f.stringValue=@""; return f; }
  BBBookmark *b=items[row];
  if ([col.identifier isEqualToString:@"title"])       f.stringValue=b.title.length?b.title:b.urlString;
  else if ([col.identifier isEqualToString:@"folder"]) f.stringValue=b.folder?:@"";
  else                                                  f.stringValue=b.urlString;
  return f;
}
- (void)moveSelectedToFolder {
  NSInteger row=self.tv.selectedRow; NSArray<BBBookmark*> *items=[BBBookmarksStore shared].items;
  if (row<0||row>=(NSInteger)items.count) return;
  BBBookmark *b=items[row];
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Move to Folder";
  a.informativeText=@"Leave blank for the bookmarks-bar root.";
  NSComboBox *cb=[[NSComboBox alloc]initWithFrame:NSMakeRect(0,0,260,24)];
  cb.usesDataSource=NO; cb.completes=YES; cb.stringValue=b.folder?:@"";
  [cb addItemWithObjectValue:@""];
  for (NSString *f in [[BBBookmarksStore shared] folders]) [cb addItemWithObjectValue:f];
  a.accessoryView=cb;
  [a addButtonWithTitle:@"Move"]; [a addButtonWithTitle:@"Cancel"];
  if ([a runModal]!=NSAlertFirstButtonReturn) return;
  NSString *target=[cb.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  [[BBBookmarksStore shared] setFolder:target forURL:b.urlString];
  [self.tv reloadData];
}
- (void)openSelected {
  NSInteger row=self.tv.selectedRow; NSArray<BBBookmark*> *items=[BBBookmarksStore shared].items;
  if (row<0||row>=(NSInteger)items.count) return;
  NSURL *u=[NSURL URLWithString:items[row].urlString]; if(!u) return;
  [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
  [self.win close];
}
- (void)removeSelected {
  NSInteger row=self.tv.selectedRow;
  [[BBBookmarksStore shared] removeAtIndex:row];
  [self.tv reloadData];
}
@end

// ── BBResearchManagerDS ───────────────────────────────────────────────────────
// Combined NSTableViewDataSource/Delegate for both the session list (left) and
// the item list (right) in the Research Session Manager window.
@interface BBResearchManagerDS : NSObject <NSTableViewDataSource,NSTableViewDelegate>
@property(weak)   NSWindow *rw;
@property(weak)   id        delegate;
@property(strong) NSTableView *sessTV;
@property(strong) NSTableView *itemTV;
@end
@implementation BBResearchManagerDS
- (instancetype)initWithWindow:(NSWindow *)w delegate:(id)d {
  self=[super init];
  _rw=w; _delegate=d;
  _sessTV=objc_getAssociatedObject(w,"sessTV");
  _itemTV=objc_getAssociatedObject(w,"itemTV");
  return self;
}
- (BBResearchSession *)currentSession {
  NSInteger row=_sessTV.selectedRow;
  NSArray *s=[BBResearchStore shared].sessions;
  if(row<0||row>=(NSInteger)s.count) return nil;
  return s[row];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
  if (tv==_sessTV) return (NSInteger)[BBResearchStore shared].sessions.count;
  BBResearchSession *s=[self currentSession]; return s?(NSInteger)s.items.count:0;
}
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  NSTextField *f=[tv makeViewWithIdentifier:col.identifier owner:self];
  if (!f) {
    f=[[NSTextField alloc]init]; f.identifier=col.identifier; f.bordered=NO;
    f.editable=NO; f.selectable=NO; f.backgroundColor=[NSColor clearColor];
    f.lineBreakMode=NSLineBreakByTruncatingTail;
  }
  if (tv==_sessTV) {
    NSArray *s=[BBResearchStore shared].sessions;
    if (row<0||row>=(NSInteger)s.count) { f.stringValue=@""; return f; }
    BBResearchSession *sess=s[row];
    f.stringValue=[NSString stringWithFormat:@"%@ (%lu)",sess.name,(unsigned long)[sess unreadCount]];
  } else {
    BBResearchSession *sess=[self currentSession]; if (!sess) { f.stringValue=@""; return f; }
    if (row<0||row>=(NSInteger)sess.items.count) { f.stringValue=@""; return f; }
    BBResearchItem *it=sess.items[row];
    NSString *cid=col.identifier;
    if ([cid isEqualToString:@"status"]) {
      static NSArray *icons; if(!icons) icons=@[@"☐",@"…",@"✓",@"✗"];
      f.stringValue=icons[it.status]; f.alignment=NSTextAlignmentCenter;
    } else if ([cid isEqualToString:@"title"]) {
      f.stringValue=it.title.length?it.title:it.urlString;
    } else {
      f.stringValue=it.urlString; f.textColor=[NSColor secondaryLabelColor];
    }
  }
  return f;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
  if (n.object==_sessTV) [_itemTV reloadData];
}
- (BOOL)tableView:(NSTableView *)tv shouldEditTableColumn:(NSTableColumn *)c row:(NSInteger)r { return NO; }

// Single-click: if the click landed on the status column, cycle that item's status
- (void)itemTableClicked:(id)s {
  NSInteger col=_itemTV.clickedColumn, row=_itemTV.clickedRow;
  if (col!=0||row<0) return;
  BBResearchSession *sess=[self currentSession]; if(!sess) return;
  if (row>=(NSInteger)sess.items.count) return;
  BBResearchItem *it=sess.items[row];
  it.status=(BBResearchStatus)((it.status+1)%4);
  [[BBResearchStore shared] save]; [_itemTV reloadData];
}

// Double-click any item row: open URL in a new tab and mark as Reading
- (void)openItemDoubleClick:(id)s {
  NSInteger row=_itemTV.clickedRow; if (row<0) return;
  BBResearchSession *sess=[self currentSession]; if(!sess) return;
  if (row>=(NSInteger)sess.items.count) return;
  BBResearchItem *it=sess.items[row];
  if (![NSURL URLWithString:it.urlString]) return;
  it.status=BBResearchStatusReading; [[BBResearchStore shared] save]; [_itemTV reloadData];
  [[NSNotificationCenter defaultCenter]
    postNotificationName:@"BBResearchOpenURL" object:nil
    userInfo:@{@"url":it.urlString}];
}
@end

// ── BBConnectionRecord ────────────────────────────────────────────────────────
typedef NS_ENUM(NSInteger,BBConnCategory){
  BBConnCategoryFirstParty=0,BBConnCategoryTracker,BBConnCategoryAnalytics,
  BBConnCategoryCDN,BBConnCategoryUnknown
};
@interface BBConnectionRecord : NSObject
@property(copy)   NSString        *domain;
@property(copy)   NSString        *pageURL;
@property(copy)   NSString        *resourceType;
@property(strong) NSDate          *timestamp;
@property(assign) BOOL             blocked;
@property(assign) BBConnCategory   category;
+(NSString*)etldForHost:(NSString*)host;
+(BBConnCategory)classify:(NSString*)etld;
@end
@implementation BBConnectionRecord
+(NSString*)etldForHost:(NSString*)host {
  if(!host.length) return @"";
  NSArray *p=[host componentsSeparatedByString:@"."];
  if(p.count<2) return host;
  return [NSString stringWithFormat:@"%@.%@",p[p.count-2],p[p.count-1]];
}
+(BBConnCategory)classify:(NSString*)etld {
  static NSSet *trackers=nil,*analytics=nil,*cdns=nil;
  static dispatch_once_t once;
  dispatch_once(&once,^{
    trackers=[NSSet setWithArray:@[@"doubleclick.net",@"googlesyndication.com",@"connect.facebook.net",
      @"criteo.com",@"adnxs.com",@"rubiconproject.com",@"pubmatic.com",@"openx.net",
      @"taboola.com",@"outbrain.com",@"moatads.com",@"scorecardresearch.com",
      @"quantserve.com",@"turn.com",@"bidswitch.net",@"casalemedia.com"]];
    analytics=[NSSet setWithArray:@[@"google-analytics.com",@"googletagmanager.com",@"mixpanel.com",
      @"amplitude.com",@"segment.io",@"segment.com",@"heap.io",@"hotjar.com",
      @"fullstory.com",@"logrocket.com",@"smartlook.com"]];
    cdns=[NSSet setWithArray:@[@"cloudflare.com",@"fastly.net",@"cloudfront.net",
      @"akamaized.net",@"jsdelivr.net",@"unpkg.com",@"amazonaws.com",
      @"googleapis.com",@"gstatic.com",@"bootstrapcdn.com",@"jquery.com",
      @"cdnjs.cloudflare.com",@"azureedge.net",@"stackpath.bootstrapcdn.com"]];
  });
  if([trackers  containsObject:etld]) return BBConnCategoryTracker;
  if([analytics containsObject:etld]) return BBConnCategoryAnalytics;
  if([cdns      containsObject:etld]) return BBConnCategoryCDN;
  return BBConnCategoryUnknown;
}
@end

// ── BBNetworkMonitor ──────────────────────────────────────────────────────────
@interface BBNetworkMonitor : NSObject
+(instancetype)shared;
-(void)record:(NSString*)domain page:(NSString*)page type:(NSString*)type blocked:(BOOL)blocked;
-(NSArray<BBConnectionRecord*>*)snapshot;
-(void)clear;
@property(copy) void(^onNewRecord)(BBConnectionRecord*);
@end
@implementation BBNetworkMonitor {
  NSMutableArray<BBConnectionRecord*> *_recs;
  dispatch_queue_t _q;
}
+(instancetype)shared{static BBNetworkMonitor*s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}
-(instancetype)init{
  self=[super init];
  _recs=[NSMutableArray arrayWithCapacity:2000];
  _q=dispatch_queue_create("io.bearbrowser.netmon",DISPATCH_QUEUE_SERIAL);
  return self;
}
-(void)record:(NSString*)domain page:(NSString*)page type:(NSString*)type blocked:(BOOL)blocked {
  if(!domain.length) return;
  NSString *etld=[BBConnectionRecord etldForHost:domain];
  BBConnectionRecord *r=[BBConnectionRecord new];
  r.domain=etld; r.pageURL=page?:@""; r.resourceType=type?:@"";
  r.timestamp=[NSDate date]; r.blocked=blocked;
  r.category=[BBConnectionRecord classify:etld];
  dispatch_async(_q,^{
    if(_recs.count>=5000)[_recs removeObjectsInRange:NSMakeRange(0,500)];
    [_recs addObject:r];
  });
  if(self.onNewRecord) dispatch_async(dispatch_get_main_queue(),^{self.onNewRecord(r);});
}
-(NSArray<BBConnectionRecord*>*)snapshot{__block NSArray*s;dispatch_sync(_q,^{s=[_recs copy];});return s;}
-(void)clear{dispatch_async(_q,^{[_recs removeAllObjects];});}
@end

// ── BBSecurityMonitor ─────────────────────────────────────────────────────────
typedef NS_ENUM(NSInteger,BBSecSeverity){BBSecLow=0,BBSecMedium,BBSecHigh,BBSecCritical};

@interface BBSecurityEvent : NSObject
@property(copy)   NSString     *type;         // eval, script_inject, beacon, form_submit, …
@property(copy)   NSString     *pageURL;
@property(copy)   NSString     *detail;       // truncated snippet / url / field list
@property(strong) NSDate       *timestamp;
@property(assign) BBSecSeverity severity;
@end
@implementation BBSecurityEvent @end

@interface BBSecurityMonitor : NSObject
+(instancetype)shared;
-(void)record:(NSString*)type page:(NSString*)page detail:(NSString*)detail severity:(BBSecSeverity)sev;
-(NSArray<BBSecurityEvent*>*)snapshot;
@property(copy) void(^onNewEvent)(BBSecurityEvent*);
@end

@implementation BBSecurityMonitor {
  NSMutableArray<BBSecurityEvent*> *_evts;
  dispatch_queue_t _q;
}
+(instancetype)shared{static BBSecurityMonitor*s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}
-(instancetype)init{self=[super init];_evts=[NSMutableArray array];_q=dispatch_queue_create("io.bearbrowser.secmon",DISPATCH_QUEUE_SERIAL);return self;}
-(void)record:(NSString*)type page:(NSString*)page detail:(NSString*)detail severity:(BBSecSeverity)sev {
  BBSecurityEvent *e=[BBSecurityEvent new];
  e.type=type; e.pageURL=page; e.detail=detail; e.severity=sev; e.timestamp=[NSDate date];
  dispatch_async(_q,^{
    [_evts addObject:e];
    if(_evts.count>2000)[_evts removeObjectAtIndex:0];
    if(self.onNewEvent) dispatch_async(dispatch_get_main_queue(),^{self.onNewEvent(e);});
  });
}
-(NSArray<BBSecurityEvent*>*)snapshot{__block NSArray*s;dispatch_sync(_q,^{s=[_evts copy];});return s;}
@end

// Heuristic severity classifier — runs on JS-side metadata, not full AST parse
static BBSecSeverity BBSecClassify(NSString *type, NSString *detail) {
  if ([type isEqualToString:@"credentials_get"] ||
      [type isEqualToString:@"credentials_create"]) return BBSecCritical;
  if ([type isEqualToString:@"eval"] || [type isEqualToString:@"Function"]) {
    // Obfuscation / exfil patterns in eval'd body → critical
    NSArray *hotPats = @[@"atob(", @"btoa(", @"document.cookie", @"localStorage",
                         @"sendBeacon", @"keydown", @"keypress", @"fromCharCode"];
    for (NSString *p in hotPats)
      if ([detail containsString:p]) return BBSecCritical;
    return BBSecHigh;
  }
  if ([type isEqualToString:@"beacon"])      return BBSecHigh;
  if ([type isEqualToString:@"keylistener"]) return BBSecCritical;
  if ([type isEqualToString:@"script_inject"]) {
    // Inline script with obfuscation patterns
    NSArray *obfPats = @[@"eval(", @"atob(", @"String.fromCharCode", @"\\x", @"unescape("];
    for (NSString *p in obfPats)
      if ([detail containsString:p]) return BBSecHigh;
    return BBSecMedium;
  }
  if ([type isEqualToString:@"form_submit"])      return BBSecMedium;
  if ([type isEqualToString:@"document_write"])   return BBSecMedium;
  if ([type isEqualToString:@"localstorage_auth"])return BBSecMedium;
  if ([type isEqualToString:@"cookie_auth"])      return BBSecMedium;
  return BBSecLow;
}

// ── BBFirewall ────────────────────────────────────────────────────────────────
typedef NS_ENUM(NSInteger,BBFirewallDecision){BBFWAsk=0,BBFWAllow,BBFWBlock};
@interface BBFirewall : NSObject
+(instancetype)shared;
-(BBFirewallDecision)decisionFor:(NSString*)domain;
-(void)set:(BBFirewallDecision)d for:(NSString*)domain;
-(NSDictionary<NSString*,NSNumber*>*)allRules;
@end
@implementation BBFirewall{NSMutableDictionary<NSString*,NSNumber*>*_rules;}
+(instancetype)shared{static BBFirewall*s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}
-(instancetype)init{
  self=[super init];
  NSDictionary *saved=[[NSUserDefaults standardUserDefaults]dictionaryForKey:@"BBFirewallRules"];
  _rules=[NSMutableDictionary dictionaryWithDictionary:saved?:@{}];
  return self;
}
-(BBFirewallDecision)decisionFor:(NSString*)d{NSNumber*n=_rules[d];return n?n.integerValue:BBFWAsk;}
-(void)set:(BBFirewallDecision)d for:(NSString*)domain{
  if(d==BBFWAsk)[_rules removeObjectForKey:domain]; else _rules[domain]=@(d);
  [[NSUserDefaults standardUserDefaults]setObject:[_rules copy] forKey:@"BBFirewallRules"];
}
-(NSDictionary<NSString*,NSNumber*>*)allRules{return[_rules copy];}
@end

// ── BBPacketCapture ───────────────────────────────────────────────────────────
@interface BBPacketCapture : NSObject
+(BOOL)available;           // tshark or tcpdump present?
+(NSString*)captureBinary;
-(void)startCapturingHost:(NSString*)host output:(void(^)(NSString*))lineHandler;
-(void)stop;
-(NSURL*)savePcapAndGetURL;  // write captured data to ~/Desktop and return URL
@end
@implementation BBPacketCapture{
  NSTask *_task;
  NSFileHandle *_fh;
  NSMutableData *_pcapBuf;
}
+(BOOL)available{return [self captureBinary].length>0;}
+(NSString*)captureBinary{
  for(NSString*p in @[@"/opt/homebrew/bin/tshark",@"/usr/local/bin/tshark",
                       @"/opt/homebrew/bin/tcpdump",@"/usr/sbin/tcpdump"])
    if([[NSFileManager defaultManager]isExecutableFileAtPath:p]) return p;
  return @"";
}
-(void)startCapturingHost:(NSString*)host output:(void(^)(NSString*))handler{
  [self stop];
  _pcapBuf=[NSMutableData data];
  NSString *bin=[BBPacketCapture captureBinary];
  if(!bin.length) return;
  _task=[[NSTask alloc]init];
  _task.launchPath=bin;
  BOOL isTshark=[bin containsString:@"tshark"];
  if(isTshark){
    _task.arguments=host.length
      ? @[@"-i",@"any",@"-Y",[NSString stringWithFormat:@"ip.host contains \"%@\"",host],
          @"-T",@"fields",@"-e",@"frame.time_relative",@"-e",@"ip.src",@"-e",@"ip.dst",
          @"-e",@"tcp.dstport",@"-e",@"frame.len",@"-E",@"separator= | "]
      : @[@"-i",@"any",@"-T",@"fields",@"-e",@"frame.time_relative",@"-e",@"ip.src",
          @"-e",@"ip.dst",@"-e",@"tcp.dstport",@"-e",@"frame.len",@"-E",@"separator= | "];
  } else {
    _task.arguments=host.length
      ? @[@"-l",@"-n",@"-i",@"any",@"host",host]
      : @[@"-l",@"-n",@"-i",@"any",@"port",@"443",@"or",@"port",@"80"];
  }
  NSPipe *pipe=[NSPipe pipe];
  _task.standardOutput=pipe; _task.standardError=pipe;
  __weak BBPacketCapture *weakCapture=self;
  [[NSNotificationCenter defaultCenter]addObserverForName:NSFileHandleDataAvailableNotification
    object:pipe.fileHandleForReading queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification*n){
      BBPacketCapture *strong=weakCapture; if(!strong) return;
      NSData *d=pipe.fileHandleForReading.availableData;
      if(d.length){
        [strong->_pcapBuf appendData:d];
        NSString *s=[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding]?:@"";
        for(NSString *line in[s componentsSeparatedByString:@"\n"])
          if(line.length) handler(line);
        [pipe.fileHandleForReading waitForDataInBackgroundAndNotify];
      }
    }];
  [pipe.fileHandleForReading waitForDataInBackgroundAndNotify];
  NSError *err=nil;
  [_task launchAndReturnError:&err];
  if(err) handler([NSString stringWithFormat:@"Error: %@",err.localizedDescription]);
}
-(void)stop{if(_task.isRunning)[_task terminate]; _task=nil;}
-(NSURL*)savePcapAndGetURL{
  if(!_pcapBuf.length) return nil;
  NSString *ts=[NSString stringWithFormat:@"bearbrowser-capture-%ld.txt",(long)[[NSDate date]timeIntervalSince1970]];
  NSURL *dest=[NSURL fileURLWithPath:[[@"~/Desktop" stringByExpandingTildeInPath] stringByAppendingPathComponent:ts]];
  [_pcapBuf writeToURL:dest atomically:YES];
  return dest;
}
@end

// ── BBNetworkMapPanel ─────────────────────────────────────────────────────────
@interface BBNetworkMapPanel : NSObject <NSTableViewDataSource,NSTableViewDelegate,WKScriptMessageHandler>
+(instancetype)shared;
-(void)showOrFocus;
-(void)pushRecord:(BBConnectionRecord*)r;
@end

static NSString *kMapHTML(void) {
  return
  @"<!doctype html><html><head><meta charset='utf-8'>"
  @"<style>"
  @"*{margin:0;padding:0;box-sizing:border-box;}"
  @"html,body{width:100%;height:100%;background:#1c1c1e;overflow:hidden;font-family:-apple-system,sans-serif;}"
  @"#wrap{position:relative;width:100%;height:100%;}"
  @"canvas{display:block;position:absolute;top:0;left:0;}"
  @"#legend{position:absolute;bottom:10px;left:10px;display:flex;flex-direction:column;gap:4px;}"
  @".li{display:flex;align-items:center;gap:6px;font-size:11px;color:#98989d;}"
  @".dot{width:8px;height:8px;border-radius:50%;flex-shrink:0;}"
  @"#tooltip{position:absolute;background:rgba(44,44,46,.95);border:1px solid rgba(255,255,255,.12);"
  @"  border-radius:8px;padding:8px 12px;font-size:12px;color:#f5f5f7;pointer-events:none;"
  @"  display:none;max-width:260px;line-height:1.6;}"
  @"</style></head><body>"
  @"<div id='wrap'><canvas id='g'></canvas>"
  @"<div id='legend'>"
  @"<div class='li'><div class='dot' style='background:#1D9E75'></div>First-party</div>"
  @"<div class='li'><div class='dot' style='background:#378ADD'></div>CDN</div>"
  @"<div class='li'><div class='dot' style='background:#EF9F27'></div>Analytics</div>"
  @"<div class='li'><div class='dot' style='background:#E24B4A'></div>Tracker</div>"
  @"<div class='li'><div class='dot' style='background:#888780'></div>Unknown</div>"
  @"<div class='li'><div class='dot' style='background:#501313'></div>Blocked</div>"
  @"</div>"
  @"<div id='tooltip'></div></div>"
  @"<script>"
  @"const CAT_COLOR={'first-party':'#1D9E75','cdn':'#378ADD','analytics':'#EF9F27',"
  @"  'tracker':'#E24B4A','unknown':'#888780','blocked':'#501313'};"
  @"let nodes={},edges=[],W=0,H=0,dpr=devicePixelRatio||1;"
  @"let canvas,ctx,tip,hovered=null,selected=null;"
  @"function init(){"
  @"  canvas=document.getElementById('g');ctx=canvas.getContext('2d');"
  @"  tip=document.getElementById('tooltip');"
  @"  resize();window.addEventListener('resize',resize);"
  @"  canvas.addEventListener('mousemove',onHover);"
  @"  canvas.addEventListener('click',onClick);"
  @"  requestAnimationFrame(tick);"
  @"}"
  @"function resize(){"
  @"  W=canvas.parentElement.clientWidth;H=canvas.parentElement.clientHeight;"
  @"  canvas.width=W*dpr;canvas.height=H*dpr;"
  @"  canvas.style.width=W+'px';canvas.style.height=H+'px';"
  @"  ctx.setTransform(dpr,0,0,dpr,0,0);"
  @"}"
  @"function updateGraph(data){"
  @"  for(const n of data.nodes){"
  @"    if(!nodes[n.id]){"
  @"      const ang=Math.random()*Math.PI*2,r=80+Math.random()*120;"
  @"      nodes[n.id]={id:n.id,cat:n.cat,count:n.count,blocked:n.blocked,"
  @"        x:W/2+Math.cos(ang)*r,y:H/2+Math.sin(ang)*r,vx:0,vy:0,page:n.page};"
  @"    } else { nodes[n.id].count=n.count;nodes[n.id].blocked=n.blocked; }"
  @"  }"
  @"  edges=data.edges;"
  @"}"
  @"function simulate(){"
  @"  const arr=Object.values(nodes);"
  @"  for(let i=0;i<arr.length;i++){"
  @"    for(let j=i+1;j<arr.length;j++){"
  @"      const a=arr[i],b=arr[j];"
  @"      let dx=a.x-b.x,dy=a.y-b.y,d=Math.sqrt(dx*dx+dy*dy)||1;"
  @"      const f=-200/(d*d),fx=f*dx/d,fy=f*dy/d;"
  @"      a.vx+=fx;a.vy+=fy;b.vx-=fx;b.vy-=fy;"
  @"    }"
  @"  }"
  @"  for(const e of edges){"
  @"    const a=nodes[e.s],b=nodes[e.t];if(!a||!b)continue;"
  @"    let dx=b.x-a.x,dy=b.y-a.y,d=Math.sqrt(dx*dx+dy*dy)||1;"
  @"    const f=(d-90)*0.04,fx=f*dx/d,fy=f*dy/d;"
  @"    a.vx+=fx;a.vy+=fy;b.vx-=fx;b.vy-=fy;"
  @"  }"
  @"  for(const n of arr){"
  @"    n.vx+=(W/2-n.x)*0.004;n.vy+=(H/2-n.y)*0.004;"
  @"    n.vx*=0.82;n.vy*=0.82;n.x+=n.vx;n.y+=n.vy;"
  @"    n.x=Math.max(30,Math.min(W-30,n.x));n.y=Math.max(30,Math.min(H-30,n.y));"
  @"  }"
  @"}"
  @"function draw(){"
  @"  ctx.clearRect(0,0,W,H);"
  @"  ctx.strokeStyle='rgba(255,255,255,0.07)';ctx.lineWidth=1;"
  @"  for(const e of edges){"
  @"    const a=nodes[e.s],b=nodes[e.t];if(!a||!b)continue;"
  @"    ctx.beginPath();ctx.moveTo(a.x,a.y);ctx.lineTo(b.x,b.y);ctx.stroke();"
  @"  }"
  @"  for(const n of Object.values(nodes)){"
  @"    const r=Math.max(5,Math.min(22,5+Math.sqrt(n.count)*2.5));"
  @"    const col=n.blocked?'#501313':(CAT_COLOR[n.cat]||'#888780');"
  @"    ctx.beginPath();ctx.arc(n.x,n.y,r,0,Math.PI*2);"
  @"    ctx.fillStyle=col;ctx.fill();"
  @"    if(n===hovered||n===selected){"
  @"      ctx.strokeStyle='rgba(255,255,255,0.8)';ctx.lineWidth=1.5;ctx.stroke();"
  @"    }"
  @"    if(r>10||n===selected){"
  @"      ctx.fillStyle='rgba(245,245,247,0.85)';ctx.font='10px -apple-system';"
  @"      ctx.textAlign='center';"
  @"      const lbl=n.id.length>22?n.id.slice(0,20)+'..':n.id;"
  @"      ctx.fillText(lbl,n.x,n.y+r+11);"
  @"    }"
  @"  }"
  @"}"
  @"function tick(){simulate();draw();requestAnimationFrame(tick);}"
  @"function nodeAt(mx,my){"
  @"  for(const n of Object.values(nodes)){"
  @"    const r=Math.max(5,Math.min(22,5+Math.sqrt(n.count)*2.5))+4;"
  @"    if((mx-n.x)**2+(my-n.y)**2<r*r)return n;"
  @"  }return null;"
  @"}"
  @"function onHover(e){"
  @"  const b=canvas.getBoundingClientRect();"
  @"  const mx=e.clientX-b.left,my=e.clientY-b.top;"
  @"  hovered=nodeAt(mx,my);"
  @"  canvas.style.cursor=hovered?'pointer':'default';"
  @"  if(hovered){"
  @"    const catLabel={'first-party':'First-party','cdn':'CDN','analytics':'Analytics',"
  @"      'tracker':'Tracker','unknown':'Unknown'};"
  @"    tip.innerHTML='<b>'+hovered.id+'</b><br>'"
  @"      +'Type: '+(catLabel[hovered.cat]||hovered.cat)+'<br>'"
  @"      +'Connections: '+hovered.count+(hovered.blocked?' <span style=\"color:#ff453a\">[BLOCKED]</span>':'');"
  @"    tip.style.display='block';"
  @"    tip.style.left=Math.min(mx+14,W-tip.offsetWidth-10)+'px';"
  @"    tip.style.top=Math.min(my-10,H-tip.offsetHeight-10)+'px';"
  @"  } else { tip.style.display='none'; }"
  @"}"
  @"function onClick(e){"
  @"  const b=canvas.getBoundingClientRect();"
  @"  const n=nodeAt(e.clientX-b.left,e.clientY-b.top);"
  @"  if(!n)return;"
  @"  selected=n;"
  @"  try{window.webkit.messageHandlers.mapAction.postMessage({action:'select',domain:n.id,blocked:n.blocked});}catch(ex){}"
  @"}"
  @"window.addEventListener('load',init);"
  @"</script></body></html>";
}

@implementation BBNetworkMapPanel {
  NSPanel         *_panel;
  NSTableView     *_table;
  WKWebView       *_graphView;
  NSTextField     *_statsLabel;
  NSButton        *_monitorBtn;
  BBPacketCapture *_capture;
  NSPanel         *_capturePanel;
  NSTextView      *_captureOutput;
  // Domain-level aggregation for the table
  NSMutableArray<NSMutableDictionary*> *_domains; // [{domain,count,blocked,cat}]
  NSMutableDictionary<NSString*,NSMutableDictionary*> *_domainMap;
}
+(instancetype)shared{static BBNetworkMapPanel*s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}
-(instancetype)init{
  self=[super init];
  _domains=[NSMutableArray array];
  _domainMap=[NSMutableDictionary dictionary];
  _capture=[[BBPacketCapture alloc]init];
  return self;
}
-(void)buildPanelIfNeeded {
  if(_panel) return;
  NSRect r=NSMakeRect(200,200,900,560);
  _panel=[[NSPanel alloc]initWithContentRect:r
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable)
    backing:NSBackingStoreBuffered defer:NO];
  _panel.releasedWhenClosed=NO; // ARC owns it; avoid the legacy close-time over-release
  _panel.title=@"BearBrowser Network Monitor";
  _panel.minSize=NSMakeSize(600,400);
  _panel.becomesKeyOnlyIfNeeded=YES;

  NSView *cv=_panel.contentView; cv.wantsLayer=YES;
  cv.layer.backgroundColor=[NSColor colorWithWhite:0.11 alpha:1].CGColor;
  CGFloat W=cv.bounds.size.width, H=cv.bounds.size.height;

  // ── Top toolbar ──
  NSView *bar=[[NSView alloc]initWithFrame:NSMakeRect(0,H-44,W,44)];
  bar.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  bar.wantsLayer=YES; bar.layer.backgroundColor=[NSColor colorWithWhite:0.14 alpha:1].CGColor;
  [cv addSubview:bar];

  _statsLabel=[[NSTextField alloc]initWithFrame:NSMakeRect(12,12,260,20)];
  _statsLabel.editable=NO; _statsLabel.bordered=NO; _statsLabel.backgroundColor=[NSColor clearColor];
  _statsLabel.textColor=[NSColor colorWithWhite:0.6 alpha:1];
  _statsLabel.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  _statsLabel.stringValue=@"No connections yet"; [bar addSubview:_statsLabel];

  // Clear button
  NSButton *clearBtn=[NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearAll:)];
  clearBtn.frame=NSMakeRect(W-280,8,60,26); clearBtn.autoresizingMask=NSViewMinXMargin;
  clearBtn.bezelStyle=NSBezelStyleRounded;
  clearBtn.font=[NSFont systemFontOfSize:12]; [bar addSubview:clearBtn];

  // Firewall button
  NSButton *fwBtn=[NSButton buttonWithTitle:@"Firewall Rules" target:self action:@selector(openFirewall:)];
  fwBtn.frame=NSMakeRect(W-210,8,100,26); fwBtn.autoresizingMask=NSViewMinXMargin;
  fwBtn.bezelStyle=NSBezelStyleRounded;
  fwBtn.font=[NSFont systemFontOfSize:12]; [bar addSubview:fwBtn];

  // Capture button
  _monitorBtn=[NSButton buttonWithTitle:@"Start Capture" target:self action:@selector(toggleCapture:)];
  _monitorBtn.frame=NSMakeRect(W-100,8,90,26); _monitorBtn.autoresizingMask=NSViewMinXMargin;
  _monitorBtn.bezelStyle=NSBezelStyleRounded;
  _monitorBtn.font=[NSFont systemFontOfSize:12]; [bar addSubview:_monitorBtn];

  // ── Split view ──
  NSSplitView *split=[[NSSplitView alloc]initWithFrame:NSMakeRect(0,0,W,H-44)];
  split.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  split.vertical=YES; split.dividerStyle=NSSplitViewDividerStyleThin;
  [cv addSubview:split];

  // Left: domain table
  NSScrollView *sv=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,220,H-44)];
  sv.hasVerticalScroller=YES; sv.autohidesScrollers=YES;
  sv.drawsBackground=NO;
  _table=[[NSTableView alloc]initWithFrame:sv.contentView.bounds];
  _table.backgroundColor=[NSColor colorWithWhite:0.13 alpha:1];
  _table.gridColor=[NSColor colorWithWhite:0.18 alpha:1];
  _table.gridStyleMask=NSTableViewSolidHorizontalGridLineMask;
  _table.rowHeight=26; _table.headerView=nil;
  _table.dataSource=self; _table.delegate=self;
  _table.allowsEmptySelection=YES;
  NSTableColumn *domCol=[[NSTableColumn alloc]initWithIdentifier:@"domain"];
  domCol.width=120; [_table addTableColumn:domCol];
  NSTableColumn *cntCol=[[NSTableColumn alloc]initWithIdentifier:@"count"];
  cntCol.width=40; [_table addTableColumn:cntCol];
  NSTableColumn *stCol=[[NSTableColumn alloc]initWithIdentifier:@"status"];
  stCol.width=16; [_table addTableColumn:stCol];
  sv.documentView=_table;
  [split addSubview:sv];

  // Right: network graph
  WKWebViewConfiguration *cfg=[[WKWebViewConfiguration alloc]init];
  [cfg.userContentController addScriptMessageHandler:self name:@"mapAction"];
  _graphView=[[WKWebView alloc]initWithFrame:NSMakeRect(0,0,W-220,H-44) configuration:cfg];
  _graphView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  [_graphView loadHTMLString:kMapHTML() baseURL:nil];
  [split addSubview:_graphView];
  [split setPosition:220 ofDividerAtIndex:0];
}
-(void)showOrFocus {
  [self buildPanelIfNeeded];
  if(!_panel.visible)[_panel orderFront:nil];
  [_panel makeKeyAndOrderFront:nil];
  [self refreshTable];
}
-(void)pushRecord:(BBConnectionRecord*)r {
  dispatch_async(dispatch_get_main_queue(),^{
    NSMutableDictionary *entry=self->_domainMap[r.domain];
    if(!entry){
      entry=[NSMutableDictionary dictionaryWithDictionary:@{
        @"domain":r.domain, @"count":@1, @"blocked":@(r.blocked),
        @"cat":[self catString:r.category], @"page":r.pageURL
      }];
      self->_domainMap[r.domain]=entry;
      [self->_domains addObject:entry];
    } else {
      entry[@"count"]=@([entry[@"count"] integerValue]+1);
      if(r.blocked) entry[@"blocked"]=@YES;
    }
    if(self->_panel.visible){
      [self refreshTable];
      [self pushGraphUpdate];
    }
  });
}
-(NSString*)catString:(BBConnCategory)c {
  switch(c){
    case BBConnCategoryFirstParty: return @"first-party";
    case BBConnCategoryTracker:    return @"tracker";
    case BBConnCategoryAnalytics:  return @"analytics";
    case BBConnCategoryCDN:        return @"cdn";
    default:                       return @"unknown";
  }
}
-(void)refreshTable {
  // Sort by count desc
  [_domains sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
    return [b[@"count"] compare:a[@"count"]];
  }];
  [_table reloadData];
  NSInteger total=0,blocked=0;
  for(NSDictionary *d in _domains){total+=((NSNumber*)d[@"count"]).integerValue;if([d[@"blocked"]boolValue])blocked++;}
  _statsLabel.stringValue=[NSString stringWithFormat:@"%ld domains · %ld reqs · %ld blocked",(long)_domains.count,(long)total,(long)blocked];
}
-(void)pushGraphUpdate {
  NSMutableArray *nodeArr=[NSMutableArray array];
  NSMutableArray *edgeArr=[NSMutableArray array];
  // find the current page domain for the center node
  NSString *center=@"this-page";
  for(NSDictionary *d in _domains){
    [nodeArr addObject:@{@"id":d[@"domain"],@"cat":d[@"cat"],
      @"count":d[@"count"],@"blocked":d[@"blocked"],@"page":d[@"page"]}];
    if(![d[@"domain"] isEqualToString:center])
      [edgeArr addObject:@{@"s":center,@"t":d[@"domain"]}];
  }
  if(nodeArr.count){
    [nodeArr insertObject:@{@"id":center,@"cat":@"first-party",@"count":@1,@"blocked":@NO,@"page":@""} atIndex:0];
  }
  NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"nodes":nodeArr,@"edges":edgeArr} options:0 error:nil];
  NSString *js=[NSString stringWithFormat:@"updateGraph(%@);",
    [[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding]];
  [_graphView evaluateJavaScript:js completionHandler:nil];
}
-(void)clearAll:(id)s {
  [_domains removeAllObjects];
  [_domainMap removeAllObjects];
  [BBNetworkMonitor.shared clear];
  [_table reloadData];
  _statsLabel.stringValue=@"Cleared";
  [_graphView evaluateJavaScript:@"nodes={};edges=[];" completionHandler:nil];
}

// ── Firewall panel ───────────────────────────────────────────────────────────
-(void)openFirewall:(id)s {
  NSWindow *fw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,480,400)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:NO];
  fw.releasedWhenClosed=NO;
  fw.title=@"BearBrowser Firewall Rules";
  NSScrollView *sv=[[NSScrollView alloc]initWithFrame:fw.contentView.bounds];
  sv.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  sv.hasVerticalScroller=YES;
  NSTableView *tv=[[NSTableView alloc]initWithFrame:sv.contentView.bounds];
  tv.rowHeight=22;
  NSTableColumn *dc=[[NSTableColumn alloc]initWithIdentifier:@"dom"]; dc.title=@"Domain"; dc.width=250; [tv addTableColumn:dc];
  NSTableColumn *ac=[[NSTableColumn alloc]initWithIdentifier:@"act"]; ac.title=@"Rule"; ac.width=100; [tv addTableColumn:ac];
  NSTableColumn *xc=[[NSTableColumn alloc]initWithIdentifier:@"del"]; xc.title=@""; xc.width=60; [tv addTableColumn:xc];
  NSDictionary<NSString*,NSNumber*> *rules=[BBFirewall.shared allRules];
  NSArray *ruleKeys=rules.allKeys;
  // Simple static datasource closure
  __block NSArray *keys=ruleKeys;
  tv.dataSource=(id<NSTableViewDataSource>)[[NSObject alloc]init];
  // Can't easily do inline datasource; use a quick-and-dirty approach
  // Just show an NSAlert with the rules list for now
  [sv removeFromSuperview];
  NSMutableString *summary=[NSMutableString string];
  for(NSString *k in ruleKeys){
    NSInteger d=rules[k].integerValue;
    [summary appendFormat:@"%@  →  %@\n", k, d==BBFWAllow?@"ALLOW":d==BBFWBlock?@"BLOCK":@"ASK"];
  }
  if(!summary.length)[summary appendString:@"No custom rules yet.\nDomain rules are set from the Network Monitor by clicking on a domain."];
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Firewall Rules";
  NSScrollView *scr=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,400,200)];
  scr.hasVerticalScroller=YES;
  NSTextView *txt=[[NSTextView alloc]initWithFrame:scr.contentView.bounds];
  txt.string=summary; txt.editable=NO; txt.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  scr.documentView=txt; a.accessoryView=scr;
  [a addButtonWithTitle:@"OK"];
  [a addButtonWithTitle:@"Clear All Rules"];
  [a beginSheetModalForWindow:_panel completionHandler:^(NSModalResponse r){
    if(r==NSAlertSecondButtonReturn){
      for(NSString *k in keys)[BBFirewall.shared set:BBFWAsk for:k];
    }
  }];
}

// ── Packet capture panel ─────────────────────────────────────────────────────
-(void)toggleCapture:(id)s {
  if(_capture && _capturePanel.visible){
    [_capture stop];
    [_capturePanel close]; _capturePanel=nil;
    _monitorBtn.title=@"Start Capture"; return;
  }
  if(![BBPacketCapture available]){
    NSAlert *a=[[NSAlert alloc]init];
    a.messageText=@"Packet Capture Not Available";
    a.informativeText=@"Install Wireshark (tshark) or ensure tcpdump is accessible:\n\nbrew install wireshark\n\nYou may also need to run:\nsudo chmod +r /dev/bpf*\nor add yourself to the access_bpf group.";
    [a addButtonWithTitle:@"OK"];
    [a addButtonWithTitle:@"Open Wireshark Website"];
    [a beginSheetModalForWindow:_panel completionHandler:^(NSModalResponse r){
      if(r==NSAlertSecondButtonReturn)
        [[NSWorkspace sharedWorkspace]openURL:[NSURL URLWithString:@"https://www.wireshark.org/download.html"]];
    }]; return;
  }
  // Build capture output panel
  NSRect pr=NSMakeRect(_panel.frame.origin.x+_panel.frame.size.width+8,
                       _panel.frame.origin.y,440,_panel.frame.size.height);
  _capturePanel=[[NSPanel alloc]initWithContentRect:pr
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:NO];
  _capturePanel.releasedWhenClosed=NO;
  _capturePanel.title=@"Packet Capture";
  NSView *cpv=_capturePanel.contentView;
  NSScrollView *csvw=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,36,cpv.bounds.size.width,cpv.bounds.size.height-36)];
  csvw.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  csvw.hasVerticalScroller=YES; csvw.hasHorizontalScroller=YES;
  _captureOutput=[[NSTextView alloc]initWithFrame:csvw.contentView.bounds];
  _captureOutput.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  _captureOutput.editable=NO; _captureOutput.backgroundColor=[NSColor colorWithWhite:0.1 alpha:1];
  _captureOutput.textColor=[NSColor colorWithRed:0.3 green:1 blue:0.3 alpha:1];
  _captureOutput.font=[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
  csvw.documentView=_captureOutput; [cpv addSubview:csvw];
  NSButton *saveBtn=[NSButton buttonWithTitle:@"Save to Desktop" target:self action:@selector(saveCapture:)];
  saveBtn.frame=NSMakeRect(8,6,120,24); saveBtn.bezelStyle=NSBezelStyleRounded; [cpv addSubview:saveBtn];
  NSButton *wiresharkBtn=[NSButton buttonWithTitle:@"Open in Wireshark" target:self action:@selector(openInWireshark:)];
  wiresharkBtn.frame=NSMakeRect(136,6,140,24); wiresharkBtn.bezelStyle=NSBezelStyleRounded; [cpv addSubview:wiresharkBtn];
  [_capturePanel orderFront:nil];
  _monitorBtn.title=@"Stop Capture";
  __weak BBNetworkMapPanel *weakPanel=self;
  [_capture startCapturingHost:@"" output:^(NSString*line){
    dispatch_async(dispatch_get_main_queue(),^{
      BBNetworkMapPanel *strong=weakPanel; if(!strong||!strong->_captureOutput) return;
      NSString *appended=[NSString stringWithFormat:@"%@\n",line];
      NSAttributedString *as=[[NSAttributedString alloc]initWithString:appended
        attributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular],
                     NSForegroundColorAttributeName:[NSColor colorWithRed:0.3 green:1 blue:0.3 alpha:1]}];
      [strong->_captureOutput.textStorage appendAttributedString:as];
      [strong->_captureOutput scrollToEndOfDocument:nil];
    });
  }];
}
-(void)saveCapture:(id)s { NSURL *u=[_capture savePcapAndGetURL]; if(u)[[NSWorkspace sharedWorkspace]activateFileViewerSelectingURLs:@[u]]; }
-(void)openInWireshark:(id)s {
  NSURL *u=[_capture savePcapAndGetURL]; if(!u) return;
  if(![[NSWorkspace sharedWorkspace]openURL:u]){
    NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Wireshark Not Found";
    a.informativeText=@"File saved to Desktop. Open it manually in Wireshark.";
    [a addButtonWithTitle:@"OK"]; [a runModal];
  }
}

// ── WKScriptMessageHandler (mapAction from graph) ────────────────────────────
-(void)userContentController:(WKUserContentController*)ucc didReceiveScriptMessage:(WKScriptMessage*)msg {
  if(![msg.name isEqualToString:@"mapAction"]) return;
  NSDictionary *body=[msg.body isKindOfClass:[NSDictionary class]]?msg.body:@{};
  NSString *domain=body[@"domain"]?:@"";
  if(!domain.length) return;
  BOOL currentlyBlocked=[body[@"blocked"] boolValue];
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[NSString stringWithFormat:@"%@",domain];
  BBFirewallDecision current=[BBFirewall.shared decisionFor:domain];
  a.informativeText=[NSString stringWithFormat:@"Current rule: %@\n\nSet a firewall rule for this domain:",
    current==BBFWAllow?@"Always allow":current==BBFWBlock?@"Always block":@"Default (follow blocklist)"];
  [a addButtonWithTitle:@"Block Always"];
  [a addButtonWithTitle:@"Allow Always"];
  [a addButtonWithTitle:@"Reset to Default"];
  [a beginSheetModalForWindow:_panel completionHandler:^(NSModalResponse r){
    if(r==NSAlertFirstButtonReturn)      [BBFirewall.shared set:BBFWBlock for:domain];
    else if(r==NSAlertSecondButtonReturn)[BBFirewall.shared set:BBFWAllow for:domain];
    else                                  [BBFirewall.shared set:BBFWAsk   for:domain];
  }];
}

// ── NSTableViewDataSource / Delegate ─────────────────────────────────────────
-(NSInteger)numberOfRowsInTableView:(NSTableView*)tv { return _domains.count; }
-(id)tableView:(NSTableView*)tv objectValueForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  if(row>=(NSInteger)_domains.count) return @"";
  NSDictionary *d=_domains[row];
  if([col.identifier isEqualToString:@"domain"]) return d[@"domain"];
  if([col.identifier isEqualToString:@"count"])  return d[@"count"];
  if([col.identifier isEqualToString:@"status"]) return [d[@"blocked"] boolValue]?@"🔴":@"🟢";
  return @"";
}
-(NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  if(row>=(NSInteger)_domains.count) return nil;
  NSDictionary *d=_domains[row];
  NSTextField *cell=[[NSTextField alloc]init];
  cell.editable=NO; cell.bordered=NO; cell.backgroundColor=[NSColor clearColor];
  cell.textColor=[NSColor colorWithWhite:0.85 alpha:1];
  cell.font=[NSFont systemFontOfSize:11];
  if([col.identifier isEqualToString:@"domain"]){
    cell.stringValue=d[@"domain"]?:@"";
    // color by category
    NSString *cat=d[@"cat"]?:@"";
    if([cat isEqualToString:@"tracker"])  cell.textColor=[NSColor colorWithRed:0.89 green:0.29 blue:0.29 alpha:1];
    else if([cat isEqualToString:@"analytics"]) cell.textColor=[NSColor colorWithRed:0.94 green:0.62 blue:0.15 alpha:1];
    else if([cat isEqualToString:@"cdn"]) cell.textColor=[NSColor colorWithRed:0.22 green:0.54 blue:0.87 alpha:1];
    else if([cat isEqualToString:@"first-party"]) cell.textColor=[NSColor colorWithRed:0.11 green:0.62 blue:0.46 alpha:1];
  } else if([col.identifier isEqualToString:@"count"]){
    cell.alignment=NSTextAlignmentRight; cell.stringValue=[d[@"count"] stringValue];
    cell.textColor=[NSColor colorWithWhite:0.5 alpha:1];
  } else {
    cell.stringValue=[d[@"blocked"] boolValue]?@"●":@"○";
    cell.textColor=[d[@"blocked"] boolValue]?[NSColor systemRedColor]:[NSColor colorWithWhite:0.3 alpha:1];
  }
  return cell;
}
-(void)tableViewSelectionDidChange:(NSNotification*)n {
  NSInteger row=_table.selectedRow;
  if(row<0||row>=(NSInteger)_domains.count) return;
  NSDictionary *d=_domains[row];
  NSString *dom=d[@"domain"]?:@"";
  // highlight in graph
  NSString *js=[NSString stringWithFormat:@"selected=nodes['%@'];",
    [dom stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
  [_graphView evaluateJavaScript:js completionHandler:nil];
}
@end

// ── BBSecurityPanel ───────────────────────────────────────────────────────────
@interface BBSecurityPanel : NSObject <NSTableViewDataSource,NSTableViewDelegate>
+(instancetype)shared;
-(void)show;
-(void)pushEvent:(BBSecurityEvent*)e;
@end

@implementation BBSecurityPanel {
  NSPanel             *_panel;
  NSTableView         *_table;
  NSMutableArray<BBSecurityEvent*> *_rows;
  NSTextField         *_badge;  // live count
}
+(instancetype)shared{static BBSecurityPanel*s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}

-(instancetype)init {
  self=[super init]; _rows=[NSMutableArray array];
  // Wire up live feed from monitor
  __weak BBSecurityPanel *weak=self;
  BBSecurityMonitor.shared.onNewEvent=^(BBSecurityEvent *e){
    BBSecurityPanel *s=weak; if(!s) return;
    [s pushEvent:e];
  };
  return self;
}

-(void)show {
  if (!_panel) [self buildPanel];
  // Sync existing events
  NSArray *snap=[BBSecurityMonitor.shared snapshot];
  [_rows removeAllObjects];
  [_rows addObjectsFromArray:snap];
  [_table reloadData];
  if (_rows.count) [_table scrollRowToVisible:_rows.count-1];
  [_panel makeKeyAndOrderFront:nil];
}

-(void)buildPanel {
  CGFloat W=820,H=540;
  _panel=[[NSPanel alloc]initWithContentRect:NSMakeRect(200,200,W,H)
    styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable|
              NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
    backing:NSBackingStoreBuffered defer:NO];
  _panel.releasedWhenClosed=NO;
  _panel.title=@"Security Monitor";
  _panel.minSize=NSMakeSize(600,340);

  NSView *root=_panel.contentView;

  // Toolbar strip
  NSView *bar=[[NSView alloc]initWithFrame:NSMakeRect(0,H-38,W,38)];
  bar.wantsLayer=YES; bar.layer.backgroundColor=[[NSColor colorWithWhite:0.13 alpha:1] CGColor];
  bar.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  [root addSubview:bar];

  NSTextField *title=[NSTextField labelWithString:@"JS Security Monitor"];
  title.font=[NSFont boldSystemFontOfSize:12];
  title.textColor=[NSColor colorWithWhite:0.9 alpha:1];
  title.frame=NSMakeRect(12,8,200,20);
  [bar addSubview:title];

  _badge=[NSTextField labelWithString:@"0 events"];
  _badge.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  _badge.textColor=[NSColor colorWithRed:0.9 green:0.6 blue:0.1 alpha:1];
  _badge.frame=NSMakeRect(220,8,200,20);
  [bar addSubview:_badge];

  NSButton *clr=[NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearEvents:)];
  clr.frame=NSMakeRect(W-80,6,68,26);
  clr.autoresizingMask=NSViewMinXMargin;
  [bar addSubview:clr];

  // Table
  NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,W,H-38)];
  scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  scroll.hasVerticalScroller=YES; scroll.hasHorizontalScroller=NO;
  scroll.autohidesScrollers=YES;
  [root addSubview:scroll];

  _table=[[NSTableView alloc]init];
  _table.dataSource=self; _table.delegate=self;
  _table.usesAlternatingRowBackgroundColors=NO;
  _table.backgroundColor=[NSColor colorWithWhite:0.10 alpha:1];
  _table.gridStyleMask=NSTableViewSolidHorizontalGridLineMask;
  _table.gridColor=[NSColor colorWithWhite:0.18 alpha:1];
  _table.rowHeight=18;
  _table.allowsMultipleSelection=NO;

  struct { NSString *id; NSString *title; CGFloat w; } cols[] = {
    {@"sev",   @"",           26},
    {@"time",  @"Time",       66},
    {@"type",  @"Type",      120},
    {@"page",  @"Page",      200},
    {@"detail",@"Detail",      0},  // flexible
  };
  for (int i=0;i<5;i++) {
    NSTableColumn *col=[[NSTableColumn alloc]initWithIdentifier:cols[i].id];
    col.title=cols[i].title;
    col.minWidth=cols[i].w; col.width=cols[i].w;
    if (i==4) col.resizingMask=NSTableColumnAutoresizingMask;
    else col.resizingMask=NSTableColumnNoResizing;
    [_table addTableColumn:col];
  }
  scroll.documentView=_table;
}

-(void)pushEvent:(BBSecurityEvent*)e {
  dispatch_async(dispatch_get_main_queue(),^{
    [_rows addObject:e];
    if (_panel&&_panel.isVisible) {
      [_table reloadData];
      [_table scrollRowToVisible:_rows.count-1];
    }
    NSInteger crit=(NSInteger)[[_rows filteredArrayUsingPredicate:
      [NSPredicate predicateWithFormat:@"severity >= %d",BBSecHigh]] count];
    _badge.stringValue=[NSString stringWithFormat:@"%ld events · %ld high/critical",
      (long)_rows.count,(long)crit];
    if (e.severity>=BBSecHigh)
      _badge.textColor=[NSColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
  });
}

-(void)clearEvents:(id)s {
  [_rows removeAllObjects];
  [_table reloadData];
  _badge.stringValue=@"0 events";
  _badge.textColor=[NSColor colorWithRed:0.9 green:0.6 blue:0.1 alpha:1];
}

// NSTableViewDataSource
-(NSInteger)numberOfRowsInTableView:(NSTableView*)tv { return _rows.count; }

-(NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  if (row>=(NSInteger)_rows.count) return nil;
  BBSecurityEvent *e=_rows[row];

  NSTextField *cell=[tv makeViewWithIdentifier:col.identifier owner:self];
  if (!cell) {
    cell=[NSTextField labelWithString:@""];
    cell.identifier=col.identifier;
    cell.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    cell.textColor=[NSColor colorWithWhite:0.85 alpha:1];
  }

  static NSColor *cCrit,*cHigh,*cMed,*cLow;
  if (!cCrit) {
    cCrit=[NSColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1];
    cHigh=[NSColor colorWithRed:1.0 green:0.6 blue:0.1 alpha:1];
    cMed =[NSColor colorWithRed:1.0 green:0.9 blue:0.2 alpha:1];
    cLow =[NSColor colorWithWhite:0.5 alpha:1];
  }
  NSColor *sevColor = e.severity==BBSecCritical?cCrit:
                      e.severity==BBSecHigh?cHigh:
                      e.severity==BBSecMedium?cMed:cLow;

  if ([col.identifier isEqualToString:@"sev"]) {
    cell.stringValue = e.severity==BBSecCritical?@"●":
                       e.severity==BBSecHigh?@"●":
                       e.severity==BBSecMedium?@"◑":@"○";
    cell.textColor=sevColor;
  } else if ([col.identifier isEqualToString:@"time"]) {
    NSDateFormatter *f=[[NSDateFormatter alloc]init];
    f.dateFormat=@"HH:mm:ss";
    cell.stringValue=[f stringFromDate:e.timestamp];
    cell.textColor=[NSColor colorWithWhite:0.5 alpha:1];
  } else if ([col.identifier isEqualToString:@"type"]) {
    cell.stringValue=e.type?:@"";
    cell.textColor=sevColor;
  } else if ([col.identifier isEqualToString:@"page"]) {
    NSString *pg=e.pageURL?:@"";
    NSURL *u=[NSURL URLWithString:pg];
    cell.stringValue=u.host?:[pg lastPathComponent]?:pg;
    cell.textColor=[NSColor colorWithWhite:0.65 alpha:1];
  } else {
    cell.stringValue=e.detail?:@"";
    cell.textColor=[NSColor colorWithWhite:0.78 alpha:1];
  }
  return cell;
}

-(CGFloat)tableView:(NSTableView*)tv heightOfRow:(NSInteger)row { return 18; }

-(BOOL)tableView:(NSTableView*)tv shouldSelectRow:(NSInteger)row {
  if (row>=(NSInteger)_rows.count) return NO;
  BBSecurityEvent *e=_rows[row];
  // Click → show full detail in NSAlert so developer can read the full payload
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[NSString stringWithFormat:@"%@ — %@",e.type,e.pageURL?:@""];
  a.informativeText=e.detail?:@"(no detail)";
  a.alertStyle=(e.severity>=BBSecHigh)?NSAlertStyleWarning:NSAlertStyleInformational;
  [a addButtonWithTitle:@"OK"];
  [a runModal];
  return NO;
}
@end

// ── BBAgentServer ─────────────────────────────────────────────────────────────
//
// Secure local Unix socket that lets agent processes (Claude Code, agent-plane,
// sidecar scripts) observe and propose browser actions.
//
// Security model — matches agent-sidecar/contract.yaml:
//   • Unix socket at BBSupportDir()/agent.sock — OS enforces 0600, owner-only
//   • Per-session token (256-bit) written to BBSupportDir()/.agent-token (0600)
//   • Every command classified by risk level from bearbrowser-propose-action defaults
//   • "observe.*" actions execute immediately (no mutation, no approval needed)
//   • "propose.*" actions go through BBProposeAction + native approval sheet
//   • All commands logged via BBEmitEvent with actor.type = "agent"
//   • credentials, cookies, secrets are never returned — redacted at boundary
//
// Wire protocol: newline-delimited JSON
//   → {"v":1,"token":"<hex>","action":"observe.url"}
//   ← {"status":"ok","result":{"url":"https://..."}}
//
//   → {"v":1,"token":"<hex>","action":"propose.navigate","url":"https://..."}
//   ← {"status":"hold","actionId":"act-xxx","message":"Awaiting user approval"}
//     (then after user approves/denies, a second line is sent)
//   ← {"status":"ok","result":{"navigated":true}}  |OR|  {"status":"denied"}

// Minimal protocol so BBAgentServer doesn't depend on the full BBDelegate @interface
@protocol BBAgentBrowserDelegate <NSObject>
@property(readonly) WKWebView  *webView;
@property(readonly) NSWindow   *window;
@property(readonly) NSArray    *tabs;
-(void)addTabPrivate:(BOOL)isPrivate;
@end

// Risk classification matching bearbrowser-propose-action.py DEFAULTS + AGENT_RUNTIME_OVERRIDES
typedef NS_ENUM(NSInteger, BBAgentRisk) {
  BBAgentRiskObserve = 0,  // no mutation, no approval — immediate
  BBAgentRiskLow,          // mutation allowed, but agent-runtime → hold
  BBAgentRiskHigh,         // holds, must approve
  BBAgentRiskCritical,     // always deny for agent-runtime
};

static BBAgentRisk BBRiskForAction(NSString *action) {
  if ([action hasPrefix:@"observe."]) return BBAgentRiskObserve;
  if ([action isEqualToString:@"propose.navigate"])   return BBAgentRiskLow;
  if ([action isEqualToString:@"propose.new_tab"])    return BBAgentRiskLow;
  if ([action isEqualToString:@"propose.evaluate_js"])return BBAgentRiskHigh;
  if ([action isEqualToString:@"propose.fill_form"])  return BBAgentRiskHigh;
  if ([action isEqualToString:@"propose.click"])      return BBAgentRiskHigh;
  if ([action isEqualToString:@"propose.screenshot"]) return BBAgentRiskLow;
  if ([action isEqualToString:@"propose.credential"]) return BBAgentRiskCritical;
  return BBAgentRiskHigh; // unknown → high
}

@interface BBAgentServer : NSObject
+(instancetype)shared;
-(void)startWithDelegate:(id<BBAgentBrowserDelegate>)delegate;
-(void)stop;
-(NSString*)tokenPath;
-(NSString*)socketPath;
@end

@implementation BBAgentServer {
  __weak id<BBAgentBrowserDelegate> _del;
  int               _serverFd;
  dispatch_source_t _acceptSource;
  NSString         *_token;
}

+(instancetype)shared{static BBAgentServer*s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}

-(NSString*)socketPath { return [BBSupportDir() stringByAppendingPathComponent:@"agent.sock"]; }
-(NSString*)tokenPath  { return [BBSupportDir() stringByAppendingPathComponent:@".agent-token"]; }

-(void)startWithDelegate:(id<BBAgentBrowserDelegate>)delegate {
  _del=delegate;
  // Generate per-session token
  _token=[self generateToken];
  [self writeToken:_token];
  [self listenOnSocket];
}

-(NSString*)generateToken {
  uint8_t buf[32]; (void)SecRandomCopyBytes(kSecRandomDefault,32,buf);
  NSMutableString *hex=[NSMutableString stringWithCapacity:64];
  for(int i=0;i<32;i++)[hex appendFormat:@"%02x",buf[i]];
  return hex;
}

-(void)writeToken:(NSString*)token {
  [[NSFileManager defaultManager]createDirectoryAtPath:BBSupportDir()
    withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *p=self.tokenPath;
  [token writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
  // 0600 — owner read/write only
  [[NSFileManager defaultManager]setAttributes:@{NSFilePosixPermissions:@(0600)}
    ofItemAtPath:p error:nil];
}

-(void)listenOnSocket {
  // Remove stale socket
  [[NSFileManager defaultManager]removeItemAtPath:self.socketPath error:nil];

  _serverFd=socket(AF_UNIX,SOCK_STREAM,0);
  if(_serverFd<0) return;

  struct sockaddr_un addr;
  memset(&addr,0,sizeof(addr));
  addr.sun_family=AF_UNIX;
  strlcpy(addr.sun_path,self.socketPath.UTF8String,sizeof(addr.sun_path));

  if(bind(_serverFd,(struct sockaddr*)&addr,sizeof(addr))<0){close(_serverFd);return;}
  // 0600 on the socket file
  [[NSFileManager defaultManager]setAttributes:@{NSFilePosixPermissions:@(0600)}
    ofItemAtPath:self.socketPath error:nil];

  if(listen(_serverFd,8)<0){close(_serverFd);return;}

  _acceptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,_serverFd,0,
    dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
  __weak BBAgentServer *weak=self;
  dispatch_source_set_event_handler(_acceptSource,^{
    BBAgentServer *s=weak; if(!s) return;
    int clientFd=accept(s->_serverFd,NULL,NULL);
    if(clientFd>=0)[s handleClient:clientFd];
  });
  dispatch_resume(_acceptSource);
}

-(void)handleClient:(int)fd {
  // Read until newline (one command per connection — simple, no framing complexity)
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
    NSMutableData *buf=[NSMutableData data];
    uint8_t byte; ssize_t n;
    while((n=read(fd,&byte,1))>0){
      if(byte=='\n') break;
      [buf appendBytes:&byte length:1];
      if(buf.length>65536) break; // cap at 64KB
    }
    if(!buf.length){close(fd);return;}
    NSDictionary *cmd=[NSJSONSerialization JSONObjectWithData:buf options:0 error:nil];
    [self dispatch:cmd fd:fd];
  });
}

// Validate token and version, then route
-(void)dispatch:(NSDictionary*)cmd fd:(int)fd {
  if(![cmd isKindOfClass:[NSDictionary class]]){[self respond:fd status:@"error" result:@{@"message":@"invalid JSON"}];return;}
  if(![cmd[@"v"] isEqual:@1]){[self respond:fd status:@"error" result:@{@"message":@"unsupported version"}];return;}
  NSString *tok=cmd[@"token"]?:@"";
  if(![tok isEqualToString:_token]){
    [self respond:fd status:@"denied" result:@{@"message":@"invalid token"}];
    BBEmitEventStatic(@"security.agent_auth_failure",@"deny",@"Agent connection with bad token.",@{});
    close(fd); return;
  }
  NSString *action=cmd[@"action"]?:@"";
  BBAgentRisk risk=BBRiskForAction(action);
  if(risk==BBAgentRiskCritical){
    [self respond:fd status:@"denied" result:@{@"message":@"action denied by policy — credential access not available to agent-runtime"}];
    BBEmitEventStatic([NSString stringWithFormat:@"automation.action_denied"],@"deny",
      [NSString stringWithFormat:@"Critical-risk agent action '%@' denied.",action],@{@"action":action});
    close(fd); return;
  }
  [self route:action cmd:cmd fd:fd risk:risk];
}

-(void)route:(NSString*)action cmd:(NSDictionary*)cmd fd:(int)fd risk:(BBAgentRisk)risk {
  id<BBAgentBrowserDelegate> d=_del; if(!d){[self respond:fd status:@"error" result:@{@"message":@"browser not ready"}];close(fd);return;}

  BBEmitEventStatic(@"automation.observed",@"observe",
    [NSString stringWithFormat:@"Agent command received: %@",action],
    @{@"action":action,@"risk":@[@"observe",@"low",@"high",@"critical"][risk]});

  // ── Observe actions — no mutation, immediate response ──────────────────────
  if([action isEqualToString:@"observe.url"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      NSString *u=d.webView.URL.absoluteString?:@"";
      [self respond:fd status:@"ok" result:@{@"url":u}]; close(fd);
    }); return;
  }
  if([action isEqualToString:@"observe.title"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      NSString *t=d.webView.title?:@"";
      [self respond:fd status:@"ok" result:@{@"title":t}]; close(fd);
    }); return;
  }
  if([action isEqualToString:@"observe.tabs"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      NSMutableArray *tabs=[NSMutableArray array];
      for(BBTab *t in d.tabs)
        [tabs addObject:@{@"url":t.webView.URL.absoluteString?:@"",
                          @"title":t.title?:@"",@"private":@(t.isPrivate)}];
      [self respond:fd status:@"ok" result:@{@"tabs":tabs}]; close(fd);
    }); return;
  }
  if([action isEqualToString:@"observe.page_text"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      [d.webView evaluateJavaScript:
        @"(document.body&&document.body.innerText?document.body.innerText:'').slice(0,32000)"
        completionHandler:^(id r,NSError*e){
          NSString *text=[r isKindOfClass:[NSString class]]?r:@"";
          [self respond:fd status:@"ok" result:@{@"text":text}]; close(fd);
        }];
    }); return;
  }
  if([action isEqualToString:@"observe.page_html"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      [d.webView evaluateJavaScript:@"document.documentElement.outerHTML.slice(0,256000)"
        completionHandler:^(id r,NSError*e){
          NSString *html=[r isKindOfClass:[NSString class]]?r:@"";
          [self respond:fd status:@"ok" result:@{@"html":html}]; close(fd);
        }];
    }); return;
  }
  if([action isEqualToString:@"observe.network_events"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      NSArray *snap=[BBNetworkMonitor.shared snapshot];
      NSMutableArray *out=[NSMutableArray array];
      NSInteger lim=MIN((NSInteger)snap.count,200);
      for(NSInteger i=snap.count-lim;i<(NSInteger)snap.count;i++){
        BBConnectionRecord *r=snap[i];
        [out addObject:@{@"domain":r.domain,@"type":r.resourceType,
          @"blocked":@(r.blocked),@"ts":@(r.timestamp.timeIntervalSince1970)}];
      }
      [self respond:fd status:@"ok" result:@{@"events":out}]; close(fd);
    }); return;
  }
  if([action isEqualToString:@"observe.provenance_tail"]) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
      // Return last 50 lines of provenance JSONL — redacted values only
      NSString *path=BBProvenancePath();
      NSString *raw=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]?:@"";
      NSArray *lines=[raw componentsSeparatedByString:@"\n"];
      NSInteger start=MAX(0,(NSInteger)lines.count-50);
      NSArray *tail=[lines subarrayWithRange:NSMakeRange(start,lines.count-start)];
      [self respond:fd status:@"ok" result:@{@"lines":tail}]; close(fd);
    }); return;
  }
  if([action isEqualToString:@"observe.security_events"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      NSArray *snap=[BBSecurityMonitor.shared snapshot];
      NSInteger lim=MIN((NSInteger)snap.count,100);
      NSMutableArray *out=[NSMutableArray array];
      for(NSInteger i=snap.count-lim;i<(NSInteger)snap.count;i++){
        BBSecurityEvent *e=snap[i];
        [out addObject:@{@"type":e.type,@"page":e.pageURL?:@"",
          @"detail":e.detail?:@"",
          @"severity":@[@"low",@"medium",@"high",@"critical"][e.severity],
          @"ts":@(e.timestamp.timeIntervalSince1970)}];
      }
      [self respond:fd status:@"ok" result:@{@"events":out}]; close(fd);
    }); return;
  }
  if([action isEqualToString:@"observe.dom_snapshot"]) {
    dispatch_async(dispatch_get_main_queue(),^{
      NSString *domJS=
        @"(function(){"
        @"function snap(el,depth){"
        @"  if(depth>4||!el)return null;"
        @"  var r={tag:(el.tagName||'#text').toLowerCase()};"
        @"  if(el.id)r.id=el.id;"
        @"  if(el.className&&typeof el.className==='string')r.cls=el.className.slice(0,60);"
        @"  if(el.href)r.href=el.href;"
        @"  if(el.src)r.src=el.src;"
        @"  if(el.type)r.type=el.type;"
        @"  if(el.name)r.name=el.name;"
        @"  if(el.getAttribute&&el.getAttribute('role'))r.role=el.getAttribute('role');"
        @"  if(el.getAttribute&&el.getAttribute('aria-label'))r.label=el.getAttribute('aria-label');"
        @"  var txt=(el.innerText||el.textContent||'').trim().slice(0,120);"
        @"  if(txt)r.text=txt;"
        @"  var kids=Array.from(el.children||[]).slice(0,12)"
        @"    .map(function(c){return snap(c,depth+1)}).filter(Boolean);"
        @"  if(kids.length)r.children=kids;"
        @"  return r;}"
        @"return JSON.stringify(snap(document.body,0));})()";
      [d.webView evaluateJavaScript:domJS completionHandler:^(id r,NSError*e){
        NSString *json=[r isKindOfClass:[NSString class]]?r:@"{}";
        [self respond:fd status:@"ok" result:@{@"dom":json}]; close(fd);
      }];
    }); return;
  }

  // ── Propose actions — require user approval ────────────────────────────────
  NSString *actionId=[NSString stringWithFormat:@"act-%@",BBRandomHexStatic(16)];
  // Immediately ACK with "hold" — user approval shown on main thread
  [self respond:fd status:@"hold" result:@{@"actionId":actionId,
    @"message":@"awaiting user approval"}];

  dispatch_async(dispatch_get_main_queue(),^{
    [self presentApproval:action cmd:cmd actionId:actionId fd:fd delegate:d];
  });
}

-(void)presentApproval:(NSString*)action cmd:(NSDictionary*)cmd
    actionId:(NSString*)actionId fd:(int)fd delegate:(id<BBAgentBrowserDelegate>)d {
  NSString *detail=@"";
  if([action isEqualToString:@"propose.navigate"])
    detail=[NSString stringWithFormat:@"Navigate to: %@",cmd[@"url"]?:@"?"];
  else if([action isEqualToString:@"propose.evaluate_js"])
    {NSString *sc=cmd[@"script"]?:@"?";
     detail=[NSString stringWithFormat:@"Run JS:\n%@",sc.length>200?[sc substringToIndex:200]:sc];}
  else if([action isEqualToString:@"propose.fill_form"])
    detail=@"Fill form fields on current page";
  else if([action isEqualToString:@"propose.click"])
    detail=[NSString stringWithFormat:@"Click element: %@",cmd[@"selector"]?:@"?"];
  else if([action isEqualToString:@"propose.new_tab"])
    detail=@"Open a new tab";
  else if([action isEqualToString:@"propose.screenshot"])
    detail=@"Capture a screenshot of the current page";

  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Agent Action Request";
  a.informativeText=[NSString stringWithFormat:@"An agent wants to:\n\n%@\n\nAllow this action?",detail];
  a.alertStyle=NSAlertStyleWarning;
  [a addButtonWithTitle:@"Allow"]; [a addButtonWithTitle:@"Deny"];
  [a beginSheetModalForWindow:d.window completionHandler:^(NSModalResponse r){
    BOOL allowed=(r==NSAlertFirstButtonReturn);
    BBEmitEventStatic(allowed?@"automation.action_approved":@"automation.action_denied",
      allowed?@"allow":@"deny",
      [NSString stringWithFormat:@"User %@ agent action '%@'",allowed?@"approved":@"denied",action],
      @{@"actionId":actionId,@"action":action});
    if(!allowed){
      [self respond:fd status:@"denied" result:@{@"actionId":actionId,@"message":@"denied by user"}];
      close(fd); return;
    }
    [self execute:action cmd:cmd fd:fd actionId:actionId delegate:d];
  }];
}

-(void)execute:(NSString*)action cmd:(NSDictionary*)cmd
    fd:(int)fd actionId:(NSString*)actionId delegate:(id<BBAgentBrowserDelegate>)d {
  if([action isEqualToString:@"propose.navigate"]) {
    NSString *url=cmd[@"url"]?:@"";
    NSURL *u=[NSURL URLWithString:url];
    if(!u||(!u.scheme)){[self respond:fd status:@"error" result:@{@"message":@"invalid url"}];close(fd);return;}
    [d.webView loadRequest:[NSURLRequest requestWithURL:u]];
    [self respond:fd status:@"ok" result:@{@"actionId":actionId,@"navigated":@YES}]; close(fd);
  } else if([action isEqualToString:@"propose.new_tab"]) {
    [d addTabPrivate:NO];
    [self respond:fd status:@"ok" result:@{@"actionId":actionId}]; close(fd);
  } else if([action isEqualToString:@"propose.evaluate_js"]) {
    NSString *script=cmd[@"script"]?:@"";
    [d.webView evaluateJavaScript:script completionHandler:^(id r,NSError*e){
      if(e){[self respond:fd status:@"error" result:@{@"message":e.localizedDescription}];}
      else {
        // Stringify result — never return DOM references or live objects
        NSString *res=[r isKindOfClass:[NSString class]]?r:
                      ([r isKindOfClass:[NSNumber class]]?[r stringValue]:
                      ([r isKindOfClass:[NSDictionary class]]||[r isKindOfClass:[NSArray class]]?
                        ([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:r options:0 error:nil]
                          encoding:NSUTF8StringEncoding]?:@"[object]"):@"null"));
        [self respond:fd status:@"ok" result:@{@"actionId":actionId,@"result":res}];
      }
      close(fd);
    }];
  } else if([action isEqualToString:@"propose.screenshot"]) {
    WKSnapshotConfiguration *cfg=[[WKSnapshotConfiguration alloc]init];
    [d.webView takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *img,NSError*e){
      if(!img||e){[self respond:fd status:@"error" result:@{@"message":e.localizedDescription?:@"snapshot failed"}];close(fd);return;}
      NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]initWithData:img.TIFFRepresentation];
      NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      NSString *b64=[png base64EncodedStringWithOptions:0];
      [self respond:fd status:@"ok" result:@{@"actionId":actionId,@"png_base64":b64?:@""}]; close(fd);
    }];
  } else {
    [self respond:fd status:@"error" result:@{@"message":@"unknown action"}]; close(fd);
  }
}

-(void)respond:(int)fd status:(NSString*)status result:(NSDictionary*)result {
  NSMutableDictionary *r=[NSMutableDictionary dictionaryWithDictionary:result];
  r[@"status"]=status;
  NSData *json=[NSJSONSerialization dataWithJSONObject:r options:0 error:nil];
  if(!json) return;
  NSMutableData *line=[NSMutableData dataWithData:json];
  uint8_t nl='\n'; [line appendBytes:&nl length:1];
  write(fd,line.bytes,line.length);
}

-(void)stop {
  if(_acceptSource){dispatch_source_cancel(_acceptSource);_acceptSource=nil;}
  if(_serverFd>0){close(_serverFd);_serverFd=0;}
  [[NSFileManager defaultManager]removeItemAtPath:self.socketPath error:nil];
}

// Static wrappers so BBAgentServer can call helpers defined at file scope
static void BBEmitEventStatic(NSString*type,NSString*dec,NSString*reason,NSDictionary*payload){
  BBEmitEvent(type,dec,reason,payload);
}
static NSString* BBRandomHexStatic(NSUInteger n){return BBRandomHex(n);}

@end

// ── BBDelegate ────────────────────────────────────────────────────────────────
@interface BBDelegate : NSObject <NSApplicationDelegate,NSWindowDelegate,WKNavigationDelegate,WKUIDelegate,WKDownloadDelegate,NSTextFieldDelegate,BBTabItemDelegate,BBAddressDropdownDelegate,BBAddressFieldDelegate,WKScriptMessageHandler,BBAgentBrowserDelegate,NSMenuDelegate>
@property(strong) NSWindow *window;
@property(strong) NSMutableArray<BBTab *> *tabs;
@property(strong) NSMutableArray<NSDictionary *> *recentlyClosed; // @{url,title}, newest last
@property(assign) NSInteger activeTabIndex;
@property(strong) NSView    *root;
@property(strong) NSView *toolbarBg;
@property(strong) BBTabBarView *tabBarView;
@property(strong) BBAddressField *address;
@property(strong) NSButton *backButton, *forwardButton, *reloadButton, *securityButton;
@property(strong) NSProgressIndicator *progressBar;
@property(strong) BBFindBar *findBar;
@property(assign) BOOL findBarVisible;
@property(strong) WKContentRuleList *contentRuleList;
// New
@property(strong) BBDownloadPanel   *downloadPanel;
@property(strong) BBAddressDropdown *addressDropdown;
@property(strong) NSView            *bookmarksBar;
@property(assign) BOOL               bookmarksBarVisible;
@property(strong) NSCache           *dnsBlockCache;   // Quad9 NXDOMAIN results
@property(assign) SecTrustRef      currentTrust;        // TLS trust for current page cert inspector
@property(strong) id               addrDismissMonitor;   // local event monitor (must be removed to avoid firing after teardown)
@property(strong) id               contextMenuMonitor;
@property(strong) id               middleClickMonitor;
@property(strong) id               ctrlScrollMonitor;    // Ctrl+scroll → page zoom (Chrome parity)
@property(strong) NSButton        *starButton;           // bookmark this page (address bar)
@property(strong) NSTextField     *statusBar;            // Chrome-style hovered-link bubble (bottom-left)
@property(strong) NSMutableDictionary<NSString*,NSNumber*> *zoomByHost; // per-site zoom memory
@property(assign) BOOL    readerMode;
@property(strong) NSURL  *readerOriginalURL;
@property(assign) BOOL    suppressInlineCompletion;
@property(strong) NSTimer *suspendTimer;         // periodic tab suspension sweep
@property(strong) NSTimer *sessionAutosaveTimer; // crash-safe periodic session flush
@property(strong) NSTimer *tabHoverTimer;        // delayed thumbnail preview
@property(strong) NSPanel *tabHoverPanel;        // borderless preview popover
@end

// Retains a controller for every open browser window. Both NSApplication.delegate
// and NSWindow.delegate are weak, so without an explicit owner a window opened via
// newWindow: would have its controller deallocated the moment the method returns
// (weak delegates go nil → the window's tabs/nav/address bar become inert).
static NSMutableArray *gBBWindowControllers;

@implementation BBDelegate

- (BBTab *)activeTab { return (self.activeTabIndex<(NSInteger)self.tabs.count)?self.tabs[self.activeTabIndex]:nil; }
- (WKWebView *)webView { return self.activeTab.webView; }
- (NSString *)currentURLString { return self.activeTab.webView.URL.absoluteString?:@"bearbrowser://start"; }
// Emit a navigation provenance event, but never persist the URL for a private tab —
// incognito must leave no on-disk trace of where you went. The event itself is still
// recorded (the provenance model knows a governed navigation happened) but redacted.
- (void)emitNav:(NSString *)type url:(NSString *)url reason:(NSString *)reason private:(BOOL)priv {
  if (priv) BBEmitEvent(type,@"allow",reason,@{@"private":@YES});
  else      BBEmitEvent(type,@"allow",reason,@{@"url":url?:@""});
}

// ── Menu ──────────────────────────────────────────────────────────────────────
- (void)buildMenu {
  // Menu bar laid out to mirror Google Chrome on macOS:
  // Chrome · File · Edit · View · History · Bookmarks · Tab · Window · Help
  NSMenu *bar=[[NSMenu alloc]init]; [NSApp setMainMenu:bar];
  void(^mi)(NSMenu*,NSString*,SEL,NSString*,NSUInteger)=^(NSMenu *m,NSString *t,SEL a,NSString *k,NSUInteger mod){
    NSMenuItem *i=[m addItemWithTitle:t action:a keyEquivalent:k]; if(mod) i.keyEquivalentModifierMask=mod;
  };
  NSMenu*(^submenu)(NSString*)=^NSMenu*(NSString *title){
    NSMenuItem *it=[[NSMenuItem alloc]init]; [bar addItem:it];
    NSMenu *m=[[NSMenu alloc]initWithTitle:title]; it.submenu=m; return m;
  };
  NSUInteger Cmd=NSEventModifierFlagCommand, Shift=NSEventModifierFlagShift,
             Opt=NSEventModifierFlagOption, Ctrl=NSEventModifierFlagControl;

  // ── Chrome (app menu) ──
  NSMenu *appM=submenu(@"BearBrowser");
  [appM addItemWithTitle:@"About BearBrowser" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [appM addItem:[NSMenuItem separatorItem]];
  mi(appM,@"Settings…",@selector(openSearchPreferences:),@",",Cmd);
  [appM addItem:[NSMenuItem separatorItem]];
  mi(appM,@"Clear Browsing Data…",@selector(clearHistory:),@"\b",Cmd|Shift); // ⌘⇧⌫
  [appM addItem:[NSMenuItem separatorItem]];
  NSMenuItem *svc=[appM addItemWithTitle:@"Services" action:nil keyEquivalent:@""];
  NSMenu *svcM=[[NSMenu alloc]initWithTitle:@"Services"]; svc.submenu=svcM; [NSApp setServicesMenu:svcM];
  [appM addItem:[NSMenuItem separatorItem]];
  mi(appM,@"Hide BearBrowser",@selector(hide:),@"h",Cmd);
  [appM addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"].keyEquivalentModifierMask=Cmd|Opt;
  [appM addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [appM addItem:[NSMenuItem separatorItem]];
  mi(appM,@"Quit BearBrowser",@selector(terminate:),@"q",Cmd);

  // ── File ──
  NSMenu *fileM=submenu(@"File");
  mi(fileM,@"New Tab",@selector(newTab:),@"t",Cmd);
  mi(fileM,@"New Window",@selector(newWindow:),@"n",Cmd);
  mi(fileM,@"New Incognito Window",@selector(newPrivateWindow:),@"n",Cmd|Shift);
  mi(fileM,@"Reopen Closed Tab",@selector(reopenClosedTab:),@"t",Cmd|Shift);
  [fileM addItem:[NSMenuItem separatorItem]];
  mi(fileM,@"Open File…",@selector(openFile:),@"o",Cmd);
  mi(fileM,@"Open Location…",@selector(focusAddressBar:),@"l",Cmd);
  // Cmd+K = Chrome alias for address-bar focus (Cmd+L is primary above)
  [fileM addItemWithTitle:@"" action:@selector(focusAddressBar:) keyEquivalent:@"k"].keyEquivalentModifierMask=Cmd;
  [fileM addItem:[NSMenuItem separatorItem]];
  mi(fileM,@"Close Window",@selector(performClose:),@"w",Cmd|Shift);
  mi(fileM,@"Close Tab",@selector(closeCurrentTab:),@"w",Cmd);
  mi(fileM,@"Save Page As…",@selector(savePage:),@"s",Cmd);
  [fileM addItem:[NSMenuItem separatorItem]];
  mi(fileM,@"Share…",@selector(sharePage:),@"",0);
  mi(fileM,@"Print…",@selector(printPage:),@"p",Cmd);
  [fileM addItemWithTitle:@"Print Selection…" action:@selector(printSelection:) keyEquivalent:@"p"].keyEquivalentModifierMask=Cmd|Shift;

  // ── Edit ──
  NSMenu *editM=submenu(@"Edit");
  mi(editM,@"Undo",@selector(undo:),@"z",Cmd);
  [editM addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"].keyEquivalentModifierMask=Cmd|Shift;
  [editM addItem:[NSMenuItem separatorItem]];
  mi(editM,@"Cut",@selector(cut:),@"x",Cmd);
  mi(editM,@"Copy",@selector(copy:),@"c",Cmd);
  mi(editM,@"Paste",@selector(paste:),@"v",Cmd);
  mi(editM,@"Paste and Go",@selector(pasteAndGo:),@"v",Cmd|Shift);
  mi(editM,@"Copy Current URL",@selector(contextCopyPageURL:),@"c",Cmd|Shift);
  mi(editM,@"Select All",@selector(selectAll:),@"a",Cmd);
  [editM addItem:[NSMenuItem separatorItem]];
  NSMenuItem *findI=[editM addItemWithTitle:@"Find" action:nil keyEquivalent:@""];
  NSMenu *findM=[[NSMenu alloc]initWithTitle:@"Find"]; findI.submenu=findM;
  mi(findM,@"Find…",@selector(toggleFind:),@"f",Cmd);
  mi(findM,@"Find Next",@selector(findNext:),@"g",Cmd);
  mi(findM,@"Find Previous",@selector(findPrev:),@"g",Cmd|Shift);

  // ── View ──
  NSMenu *viewM=submenu(@"View");
  mi(viewM,@"Always Show Bookmarks Bar",@selector(toggleBookmarksBar:),@"b",Cmd|Shift);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Reload This Page",@selector(reloadOrStop:),@"r",Cmd);
  mi(viewM,@"Force Reload This Page",@selector(hardReload:),@"r",Cmd|Shift);
  // Cmd+. = Stop loading (Chrome alias; works while a page is loading).
  [viewM addItemWithTitle:@"Stop Loading" action:@selector(stopLoading:) keyEquivalent:@"."].keyEquivalentModifierMask=Cmd;
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Actual Size",@selector(zoomReset:),@"0",Cmd);
  mi(viewM,@"Zoom In",@selector(zoomIn:),@"+",Cmd);
  // Cmd+= mirrors Cmd++ on US keyboard (no Shift required) — Chrome parity
  [viewM addItemWithTitle:@"" action:@selector(zoomIn:) keyEquivalent:@"="].keyEquivalentModifierMask=Cmd;
  mi(viewM,@"Zoom Out",@selector(zoomOut:),@"-",Cmd);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Enter Full Screen",@selector(toggleFullScreen:),@"f",Cmd|Ctrl);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Downloads",@selector(toggleDownloadPanel:),@"j",Cmd|Shift);
  mi(viewM,@"Show Reader",@selector(toggleReader:),@"r",Cmd|Ctrl);
  mi(viewM,@"Translate Page…",@selector(translatePage:),@"u",Cmd|Ctrl);
  mi(viewM,@"Read Aloud",@selector(readAloud:),@"r",Cmd|Opt);
  [viewM addItem:[NSMenuItem separatorItem]];
  NSMenuItem *devI=[viewM addItemWithTitle:@"Developer" action:nil keyEquivalent:@""];
  NSMenu *devM=[[NSMenu alloc]initWithTitle:@"Developer"]; devI.submenu=devM;
  mi(devM,@"View Source",@selector(viewSource:),@"u",Cmd|Opt);
  mi(devM,@"Developer Tools",@selector(openDevTools:),@"i",Cmd|Opt);
  mi(devM,@"Network Monitor",@selector(openNetworkMonitor:),@"m",Cmd|Shift);

  // ── History ──
  NSMenu *histM=submenu(@"History");
  mi(histM,@"Home",@selector(goHome:),@"h",Cmd|Shift);
  mi(histM,@"Back",@selector(goBack:),@"[",Cmd);
  mi(histM,@"Forward",@selector(goForward:),@"]",Cmd);
  [histM addItem:[NSMenuItem separatorItem]];
  mi(histM,@"Reopen Closed Tab",@selector(reopenClosedTab:),@"t",Cmd|Shift);
  NSMenuItem *rcI=[histM addItemWithTitle:@"Recently Closed" action:nil keyEquivalent:@""];
  NSMenu *rcM=[[NSMenu alloc]initWithTitle:@"Recently Closed"]; rcM.delegate=self; // populated on open
  rcI.submenu=rcM;
  [histM addItem:[NSMenuItem separatorItem]];
  mi(histM,@"Show Full History",@selector(showHistory:),@"y",Cmd);
  [histM addItem:[NSMenuItem separatorItem]];
  // No key equivalent here — ⌘⇧⌫ is already bound on the app menu's Clear Browsing Data.
  [histM addItemWithTitle:@"Clear Browsing Data…" action:@selector(clearHistory:) keyEquivalent:@""];

  // ── Bookmarks ──
  NSMenu *bmM=submenu(@"Bookmarks");
  mi(bmM,@"Bookmark Manager",@selector(openBookmarkManager:),@"b",Cmd|Opt);
  [bmM addItem:[NSMenuItem separatorItem]];
  mi(bmM,@"Bookmark This Tab…",@selector(addBookmark:),@"d",Cmd);
  mi(bmM,@"Bookmark All Tabs…",@selector(bookmarkAllTabs:),@"d",Cmd|Shift);
  [bmM addItem:[NSMenuItem separatorItem]];
  mi(bmM,@"Add to Reading List",@selector(addToReadingList:),@"d",Cmd|Opt);
  [bmM addItemWithTitle:@"Show Reading List…" action:@selector(showReadingList:) keyEquivalent:@""];
  [bmM addItem:[NSMenuItem separatorItem]];
  // No key equivalent here — ⌘⇧B is already bound on View ▸ Always Show Bookmarks Bar.
  [bmM addItemWithTitle:@"Show Bookmarks Bar" action:@selector(toggleBookmarksBar:) keyEquivalent:@""];

  // ── Research Sessions ──
  NSMenu *resM=submenu(@"Research");
  mi(resM,@"Research Sessions…",@selector(openResearchManager:),@"r",Cmd|Shift);
  [resM addItem:[NSMenuItem separatorItem]];
  mi(resM,@"Add Tab to Session…",@selector(addCurrentTabToSession:),@"s",Cmd|Shift);
  [resM addItemWithTitle:@"Collect All Tabs into Session…" action:@selector(collectAllTabsToSession:) keyEquivalent:@""];
  [resM addItem:[NSMenuItem separatorItem]];
  [resM addItemWithTitle:@"Suspend Inactive Tabs Now" action:@selector(suspendInactiveTabs:) keyEquivalent:@""];

  // ── Tab ──
  NSMenu *tabM=submenu(@"Tab");
  mi(tabM,@"New Tab",@selector(newTab:),@"t",Cmd);
  mi(tabM,@"Search Tabs…",@selector(openTabSearch:),@"a",Cmd|Shift);
  [tabM addItemWithTitle:@"Duplicate Tab" action:@selector(duplicateCurrentTab:) keyEquivalent:@""];
  [tabM addItemWithTitle:@"Mute Tab" action:@selector(muteTab:) keyEquivalent:@""];
  [tabM addItemWithTitle:@"Pin Tab" action:@selector(pinCurrentTab:) keyEquivalent:@""];
  [tabM addItemWithTitle:@"Mute All Tabs"   action:@selector(muteAllTabs:)   keyEquivalent:@""];
  [tabM addItemWithTitle:@"Unmute All Tabs" action:@selector(unmuteAllTabs:) keyEquivalent:@""];
  [tabM addItem:[NSMenuItem separatorItem]];
  mi(tabM,@"Select Next Tab",@selector(nextTab:),@"\t",Ctrl);
  [tabM addItemWithTitle:@"Select Previous Tab" action:@selector(prevTab:) keyEquivalent:@"\t"].keyEquivalentModifierMask=Ctrl|Shift;
  [tabM addItemWithTitle:@"Move Tab Left"  action:@selector(moveTabLeft:)  keyEquivalent:@"["].keyEquivalentModifierMask=Ctrl|Shift;
  [tabM addItemWithTitle:@"Move Tab Right" action:@selector(moveTabRight:) keyEquivalent:@"]"].keyEquivalentModifierMask=Ctrl|Shift;
  [tabM addItem:[NSMenuItem separatorItem]];
  for (NSInteger i=1;i<=9;i++) {
    NSMenuItem *ti=[tabM addItemWithTitle:[NSString stringWithFormat:@"Tab %ld",(long)i]
                                   action:@selector(switchToTabByMenuItem:)
                            keyEquivalent:[NSString stringWithFormat:@"%ld",(long)i]];
    ti.keyEquivalentModifierMask=Cmd; ti.tag=i-1;
  }
  [tabM addItem:[NSMenuItem separatorItem]];
  mi(tabM,@"Close Tab",@selector(closeCurrentTab:),@"w",Cmd);

  // ── Window ──
  NSMenu *winM=submenu(@"Window");
  [NSApp setWindowsMenu:winM];
  mi(winM,@"Minimize",@selector(performMiniaturize:),@"m",Cmd);
  [winM addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  [winM addItem:[NSMenuItem separatorItem]];
  [winM addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];

  // ── Help ──
  NSMenu *helpM=submenu(@"Help");
  [NSApp setHelpMenu:helpM];
  [helpM addItemWithTitle:@"BearBrowser Help" action:@selector(openBearHelp:) keyEquivalent:@""];
  [helpM addItem:[NSMenuItem separatorItem]];
  [helpM addItemWithTitle:@"Keyboard Shortcuts" action:@selector(showKeyboardShortcuts:) keyEquivalent:@"/"].keyEquivalentModifierMask=Cmd;
  [helpM addItemWithTitle:@"Report an Issue…" action:@selector(reportIssue:) keyEquivalent:@""];
}

// ── App launch ────────────────────────────────────────────────────────────────
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  BBLog(@"BearBrowser start");
  static dispatch_once_t controllersOnce;
  dispatch_once(&controllersOnce,^{
    gBBWindowControllers=[NSMutableArray array];
    // Search suggestions default ON (DuckDuckGo's privacy-respecting endpoint); the
    // user can disable in Settings, and they're always off in private tabs.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
    @"BBSearchSuggestions":@YES,
    @"BBInlineAutocomplete":@YES,
    @"BBSuspendAfterSec":@300,   // 5 minutes
  }];
  });
  [gBBWindowControllers addObject:self];  // keep this controller alive for its window's lifetime
  BBEmitEvent(@"app.launch",@"allow",@"Native shell launched.",@{@"bundleId":@"dev.sourceos.BearBrowser"});
  [[BBAgentServer shared] startWithDelegate:self];
  BBLog([NSString stringWithFormat:@"Agent socket: %@",[BBAgentServer shared].socketPath]);
  BBLog([NSString stringWithFormat:@"Agent token: %@",[BBAgentServer shared].tokenPath]);
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  [self buildMenu];
  self.recentlyClosed=[NSMutableArray array];
  self.zoomByHost=[([[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BBZoomByHost"]?:@{}) mutableCopy];
  // Compile content rules on a background queue; tabs added after compilation get rules applied.
  // Tabs opened immediately (below) get rules applied once compile finishes via the shared property.
  [BBContentBlocker loadRulesInto:[[WKWebViewConfiguration alloc]init] completion:^{
    // Store compiled rule list for future webviews. We re-compile to get the actual list object.
    WKContentRuleListStore *store=[WKContentRuleListStore defaultStore];
    [store lookUpContentRuleListForIdentifier:@"bb-baseline" completionHandler:^(WKContentRuleList *list, NSError *e){
      if (list) { dispatch_async(dispatch_get_main_queue(),^{ self.contentRuleList=list; }); }
    }];
  }];

  // Use visibleFrame (excludes menu bar + Dock) so default placement is never
  // behind system chrome. Clamp to 85% of available space on smaller screens.
  NSRect vf=[NSScreen mainScreen].visibleFrame;
  CGFloat defW=MIN(1280, floor(vf.size.width*0.9));
  CGFloat defH=MIN(800,  floor(vf.size.height*0.9));
  NSRect contentFrame=NSMakeRect(0,0,defW,defH); // used for initWithContentRect:
  BOOL useCenter=YES;
  NSString *saved=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBWindowFrame"];
  if (saved) {
    NSRect r=NSRectFromString(saved);
    // Validate saved frame: must have reasonable size AND fit on a visible screen
    if (!NSIsEmptyRect(r)&&r.size.width>400&&r.size.height>300) {
      // Ensure the top of the saved window is below the menu bar
      CGFloat screenTop=vf.origin.y+vf.size.height;
      if (r.origin.y+r.size.height <= screenTop+50) { // allow 50pt overshoot
        contentFrame=r; useCenter=NO;
      }
    }
  }

  self.window=[[NSWindow alloc]initWithContentRect:contentFrame
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|
               NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskFullSizeContentView)
    backing:NSBackingStoreBuffered defer:NO];
  // CRITICAL: NSWindow defaults releasedWhenClosed=YES. With a `strong` property
  // ARC already owns the window, so closing it would over-release → self.window
  // becomes a dangling pointer → EXC_BAD_ACCESS in objc_retain the next time any
  // retained event-monitor block touches it. Opt out of the legacy release.
  self.window.releasedWhenClosed=NO;
  // Disallow native NSWindow tabbing — we have our own tabs; macOS's "Merge All Windows"
  // and per-window tab bar would double up on top of ours.
  self.window.tabbingMode=NSWindowTabbingModeDisallowed;
  self.window.title=@"BearBrowser";
  self.window.titlebarAppearsTransparent=YES;
  self.window.titleVisibility=NSWindowTitleHidden;
  self.window.minSize=NSMakeSize(640,480);
  self.window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary|NSWindowCollectionBehaviorManaged;
  self.window.delegate=self;
  if (useCenter) [self.window center]; else [self.window setFrame:contentFrame display:NO];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowWillClose:)
    name:NSWindowWillCloseNotification object:self.window];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(researchURLNotification:)
    name:@"BBResearchOpenURL" object:nil];

  self.root=[[NSView alloc]initWithFrame:self.window.contentView.bounds];
  self.root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  self.window.contentView=self.root;

  CGFloat W=self.root.bounds.size.width, H=self.root.bounds.size.height;

  // Toolbar — NSVisualEffectView with Sidebar material (NOT Titlebar, so it does
  // not register as a titlebar zone and does not intercept mouse events).
  NSVisualEffectView *tbVE=[[NSVisualEffectView alloc]initWithFrame:NSMakeRect(0,H-kToolbarH,W,kToolbarH)];
  tbVE.material=NSVisualEffectMaterialSidebar;
  tbVE.blendingMode=NSVisualEffectBlendingModeWithinWindow;
  tbVE.state=NSVisualEffectStateActive;
  tbVE.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  self.toolbarBg=tbVE;
  NSBox *tbSep=[[NSBox alloc]initWithFrame:NSMakeRect(0,0,W,1)];
  tbSep.autoresizingMask=NSViewWidthSizable; tbSep.boxType=NSBoxSeparator;
  [self.toolbarBg addSubview:tbSep];
  [self.root addSubview:self.toolbarBg];

  CGFloat btnY=(kToolbarH-32)/2, x=80;
  self.backButton   =[self navBtn:@"chevron.left"    tip:@"Back"    sel:@selector(goBack:)       x:x y:btnY]; x+=34;
  self.forwardButton=[self navBtn:@"chevron.right"   tip:@"Forward" sel:@selector(goForward:)    x:x y:btnY]; x+=34;
  self.reloadButton =[self navBtn:@"arrow.clockwise" tip:@"Reload"  sel:@selector(reloadOrStop:) x:x y:btnY]; x+=40;
  self.backButton.enabled=NO; self.forwardButton.enabled=NO;
  for (NSButton *b in @[self.backButton,self.forwardButton,self.reloadButton])
    [self.toolbarBg addSubview:b];

  // Security indicator
  self.securityButton=[[NSButton alloc]initWithFrame:NSMakeRect(x,btnY+2,26,26)]; x+=28;
  self.securityButton.bezelStyle=NSBezelStyleToolbar; self.securityButton.bordered=NO;
  self.securityButton.target=self; self.securityButton.action=@selector(showSecurityInfo:);
  [self updateSecurityIndicator:nil]; [self.toolbarBg addSubview:self.securityButton];

  // Address bar — reserve room on the right for the bookmark star AND the three
  // toolbar action buttons (network / read-aloud / bear panel) so none overlap.
  CGFloat rightR=48;
  CGFloat rightGroupLeft=W-rightR-58;   // left edge of the action-button group (netBtn)
  CGFloat starX=rightGroupLeft-30;      // star sits just left of that group
  self.address=[[BBAddressField alloc]initWithFrame:NSMakeRect(x,btnY+1,starX-x-6,28)];
  self.address.autoresizingMask=NSViewWidthSizable;
  self.address.bezelStyle=NSTextFieldRoundedBezel;
  self.address.placeholderString=@"Search or enter address";
  self.address.font=[NSFont systemFontOfSize:13.5]; self.address.stringValue=@"";
  self.address.delegate=self; self.address.pasteDelegate=self;
  [self.address.cell setWraps:NO]; [self.address.cell setScrollable:YES];
  [self.toolbarBg addSubview:self.address];

  // Bookmark star at the right end of the omnibox (Chrome-style). Click toggles a
  // bookmark for the current page. Placed clear of the action-button group.
  self.starButton=[[NSButton alloc]initWithFrame:NSMakeRect(starX,btnY+3,24,24)];
  self.starButton.autoresizingMask=NSViewMinXMargin;
  self.starButton.bezelStyle=NSBezelStyleToolbar; self.starButton.bordered=NO;
  self.starButton.target=self; self.starButton.action=@selector(toggleBookmarkCurrent:);
  [self updateStarButton]; [self.toolbarBg addSubview:self.starButton];

  // Network monitor button
  NSButton *netBtn=[self navBtn:@"network" tip:@"Network Monitor (⇧⌘M)" sel:@selector(openNetworkMonitor:) x:W-rightR-58 y:btnY];
  netBtn.autoresizingMask=NSViewMinXMargin; [self.toolbarBg addSubview:netBtn];
  // Read aloud button
  NSButton *voiceBtn=[self navBtn:@"waveform" tip:@"Read Aloud (⌥⌘R)" sel:@selector(readAloud:) x:W-rightR-30 y:btnY];
  voiceBtn.autoresizingMask=NSViewMinXMargin; [self.toolbarBg addSubview:voiceBtn];
  // Bear panel button
  NSButton *bearBtn=[self navBtn:@"ellipsis.circle" tip:@"BearBrowser Panel" sel:@selector(showBearPanel:) x:W-rightR+4 y:btnY];
  bearBtn.autoresizingMask=NSViewMinXMargin; [self.toolbarBg addSubview:bearBtn];

  // Tab bar
  self.tabBarView=[[BBTabBarView alloc]initWithFrame:NSMakeRect(0,H-kToolbarH-kTabBarH,W,kTabBarH) delegate:self];
  self.tabBarView.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  self.tabBarView.addTabButton.target=self; self.tabBarView.addTabButton.action=@selector(newTab:);
  [self.root addSubview:self.tabBarView];

  // Progress bar — real percentage
  CGFloat chromH=kToolbarH+kTabBarH;
  self.progressBar=[[NSProgressIndicator alloc]initWithFrame:NSMakeRect(0,H-chromH-2,W,2)];
  self.progressBar.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  self.progressBar.style=NSProgressIndicatorStyleBar;
  self.progressBar.indeterminate=NO; self.progressBar.minValue=0; self.progressBar.maxValue=1;
  self.progressBar.controlSize=NSControlSizeSmall; self.progressBar.hidden=YES;
  [self.root addSubview:self.progressBar];

  // Hovered-link status bubble (bottom-left), exactly like Chrome. Hidden until a
  // link is hovered; the page posts the href via the `hoverlink` message handler.
  self.statusBar=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,420,20)];
  self.statusBar.bordered=NO; self.statusBar.editable=NO; self.statusBar.selectable=NO;
  self.statusBar.drawsBackground=YES;
  self.statusBar.backgroundColor=[NSColor windowBackgroundColor];
  self.statusBar.textColor=[NSColor secondaryLabelColor];
  self.statusBar.font=[NSFont systemFontOfSize:11];
  self.statusBar.lineBreakMode=NSLineBreakByTruncatingMiddle;
  self.statusBar.cell.usesSingleLineMode=YES;
  self.statusBar.hidden=YES; self.statusBar.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  [self.root addSubview:self.statusBar positioned:NSWindowAbove relativeTo:nil];

  // Find bar
  self.findBar=[[BBFindBar alloc]initWithFrame:NSMakeRect(0,0,W,kFindBarH)];
  self.findBar.autoresizingMask=NSViewWidthSizable; self.findBar.hidden=YES;
  self.findBar.closeButton.target=self; self.findBar.closeButton.action=@selector(closeFind:);
  self.findBar.prevButton.target=self;  self.findBar.prevButton.action=@selector(findPrev:);
  self.findBar.nextButton.target=self;  self.findBar.nextButton.action=@selector(findNext:);
  self.findBar.queryField.delegate=self;
  [self.root addSubview:self.findBar];

  // Bookmarks bar (hidden by default, Cmd+Shift+B toggles)
  self.bookmarksBar=[[NSView alloc]initWithFrame:NSMakeRect(0,H-kToolbarH-kTabBarH-kBMBarH,W,kBMBarH)];
  self.bookmarksBar.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  self.bookmarksBar.wantsLayer=YES; self.bookmarksBar.layer.backgroundColor=[NSColor windowBackgroundColor].CGColor;
  self.bookmarksBar.hidden=YES;
  [self.root addSubview:self.bookmarksBar];

  // Download panel (right edge, hidden by default)
  self.downloadPanel=[[BBDownloadPanel alloc]initWithFrame:NSMakeRect(W-kDLPanelW,0,kDLPanelW,H-kToolbarH-kTabBarH)];
  self.downloadPanel.autoresizingMask=NSViewMinXMargin|NSViewHeightSizable;
  self.downloadPanel.hidden=YES; [self.root addSubview:self.downloadPanel];

  // Address autocomplete dropdown
  self.addressDropdown=[[BBAddressDropdown alloc]init];
  self.addressDropdown.delegate=self;

  self.dnsBlockCache=[[NSCache alloc]init];
  // (decoyViews removed — popup timing gate was a per-browser fingerprint vector)
  self.dnsBlockCache.countLimit=2000;

  self.tabs=[NSMutableArray array]; self.activeTabIndex=0;
  // Session restore — reopen tabs from last session (supports old string array + new dict array)
  NSArray *savedTabs=[[NSUserDefaults standardUserDefaults] arrayForKey:@"BBSessionURLs"];
  BOOL restored=NO;
  for (id entry in savedTabs) {
    NSString *u=nil; BOOL pinned=NO, muted=NO;
    if ([entry isKindOfClass:[NSString class]]) {
      u=entry; // legacy format
    } else if ([entry isKindOfClass:[NSDictionary class]]) {
      u=entry[@"url"]; pinned=[entry[@"pinned"] boolValue]; muted=[entry[@"muted"] boolValue];
    }
    if (!u.length) continue;
    NSURL *nsurl=[NSURL URLWithString:u]; if(!nsurl) continue;
    [self addTabPrivate:NO];
    BBTab *tab=self.activeTab; tab.pinned=pinned; tab.muted=muted;
    if ([entry isKindOfClass:[NSDictionary class]]) {
      NSString *g=entry[@"group"]; if ([g isKindOfClass:[NSString class]] && g.length) {
        tab.groupName=g; tab.groupColorIdx=[entry[@"groupColor"] integerValue];
      }
    }
    // Eagerly restore title and favicon so pinned tabs look right before the page loads
    if ([entry isKindOfClass:[NSDictionary class]]) {
      NSString *savedTitle=entry[@"title"]; if (savedTitle.length) tab.title=savedTitle;
      NSString *b64=entry[@"favicon"];
      if (b64.length) { NSData *png=[[NSData alloc]initWithBase64EncodedString:b64 options:0]; if(png) tab.favicon=[[NSImage alloc]initWithData:png]; }
    }
    [self.webView loadRequest:[NSURLRequest requestWithURL:nsurl]];
    if (muted) [self.webView evaluateJavaScript:
      @"document.querySelectorAll('audio,video').forEach(function(m){m.muted=true;})"
      completionHandler:nil];
    restored=YES;
  }
  if (!restored) [self addTabPrivate:NO];
  // Restore the bookmarks-bar preference (after the first tab exists so layout is valid).
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BBShowBookmarksBar"]) {
    self.bookmarksBarVisible=YES; self.bookmarksBar.hidden=NO;
    [self reloadBookmarksBar]; [self resizeWebViewForCurrentTab];
  }
  [self startSuspendTimer];
  [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
  BBLog([NSString stringWithFormat:@"window frame=%@ root=%@ toolbar=%@",
    NSStringFromRect(self.window.frame), NSStringFromRect(self.root.bounds), NSStringFromRect(self.toolbarBg.frame)]);
  // Focus the address bar immediately on launch — user can type a URL right away.
  dispatch_async(dispatch_get_main_queue(),^{
    [self.window makeFirstResponder:self.address];
    [self.address selectText:nil];
  });
  // Dismiss the address dropdown when the user clicks outside it or the address field.
  // Keep the token so we can remove it on close — a leaked monitor keeps firing
  // (and retaining self) after teardown.
  __weak BBDelegate *weakSelf=self;
  self.addrDismissMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:
    NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskKeyDown
    handler:^NSEvent*(NSEvent *e){
    BBDelegate *self=weakSelf; if (!self) return e;
    if (e.type==NSEventTypeLeftMouseDown && e.window==self.window) {
      NSView *overlay=self.addressDropdown.overlay;
      NSPoint pt=[self.root convertPoint:e.locationInWindow fromView:nil];
      NSView *hit=[self.root hitTest:pt];
      BOOL inOverlay = overlay && !overlay.hidden && (hit==overlay || [hit isDescendantOf:overlay]);
      BOOL inAddress = (hit==self.address || [hit isDescendantOf:self.address] ||
                        hit==[self.address currentEditor] || [hit isDescendantOf:[self.address currentEditor]]);
      if (!inOverlay && !inAddress) [self.addressDropdown hide];
    }
    return e;
  }];
  [self installContextMenuMonitor];
  [self installCtrlScrollMonitor];
}
- (void)installCtrlScrollMonitor {
  __weak BBDelegate *weak=self;
  __block CGFloat accum=0;
  self.ctrlScrollMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent*(NSEvent *e){
    BBDelegate *s=weak; if (!s||e.window!=s.window) return e;
    if (!(e.modifierFlags & NSEventModifierFlagControl)) return e;
    NSPoint pt=[s.webView convertPoint:e.locationInWindow fromView:nil];
    if (!NSPointInRect(pt,s.webView.bounds)) return e;
    accum+=e.scrollingDeltaY;
    CGFloat step=e.hasPreciseScrollingDeltas?12.0:1.0;
    while (accum>=step)  { accum-=step; [s zoomIn:nil];  }
    while (accum<=-step) { accum+=step; [s zoomOut:nil]; }
    return nil; // swallow — don't scroll the page
  }];
}

// Returns YES for URLs that should show as blank in the address bar (start page, new-tab).
- (BOOL)isInternalURL:(NSString *)url {
  if (!url.length) return YES;
  if ([url hasPrefix:@"bearbrowser://"]) return YES;
  // Bundled start page
  NSString *startPath=[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"BearBrowser-start.html"];
  NSString *startURL=[[NSURL fileURLWithPath:startPath] absoluteString];
  return [url isEqualToString:startURL];
}

// ── Nav button factory ────────────────────────────────────────────────────────
- (NSButton *)navBtn:(NSString *)sym tip:(NSString *)tip sel:(SEL)sel x:(CGFloat)x y:(CGFloat)y {
  NSButton *b=[[NSButton alloc]initWithFrame:NSMakeRect(x,y,32,32)];
  NSImage *img=[NSImage imageWithSystemSymbolName:sym accessibilityDescription:tip];
  img=[img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]];
  [img setTemplate:YES]; b.image=img; b.imagePosition=NSImageOnly;
  b.bezelStyle=NSBezelStyleToolbar; b.bordered=NO; b.target=self; b.action=sel; b.toolTip=tip;
  return b;
}

// ── Security indicator ────────────────────────────────────────────────────────
- (void)updateSecurityIndicator:(NSURL *)url {
  NSString *sym=@"globe"; NSColor *tint=[NSColor tertiaryLabelColor];
  NSString *tip=@"";
  if (url) {
    if ([url.scheme isEqualToString:@"https"]) {
      sym=@"lock.fill"; tint=[NSColor systemGreenColor]; tip=@"Secure connection (HTTPS)";
    } else if ([url.scheme isEqualToString:@"http"]) {
      sym=@"exclamationmark.triangle.fill"; tint=[NSColor systemOrangeColor]; tip=@"Not secure — connection is not encrypted";
    } else if ([url.scheme isEqualToString:@"file"]) {
      sym=@"doc.fill"; tint=[NSColor secondaryLabelColor]; tip=@"Local file";
    }
  }
  NSImage *img=[NSImage imageWithSystemSymbolName:sym accessibilityDescription:tip];
  img=[img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
  // Apply tint via symbol color config
  NSImageSymbolConfiguration *colorCfg=[NSImageSymbolConfiguration configurationWithHierarchicalColor:tint];
  img=[img imageWithSymbolConfiguration:colorCfg];
  self.securityButton.image=img; self.securityButton.imagePosition=NSImageOnly;
  self.securityButton.toolTip=tip.length?tip:@"Security info";
}
// ── Bookmark star (address bar) ───────────────────────────────────────────────
- (void)updateStarButton {
  if (!self.starButton) return;
  NSString *url=self.webView.URL.absoluteString?:@"";
  BOOL marked=url.length && [[BBBookmarksStore shared] isBookmarked:url];
  NSImage *img=[NSImage imageWithSystemSymbolName:(marked?@"star.fill":@"star") accessibilityDescription:@"Bookmark"];
  img=[img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
  if (marked) img=[img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[NSColor systemYellowColor]]];
  else [img setTemplate:YES];
  self.starButton.image=img; self.starButton.imagePosition=NSImageOnly;
  self.starButton.toolTip=marked?@"Remove bookmark":@"Bookmark this page";
}
- (void)toggleBookmarkCurrent:(id)s {
  NSString *url=self.webView.URL.absoluteString;
  if (!url.length||[url hasPrefix:@"bearbrowser://"]||[self isInternalURL:url]) { NSBeep(); return; }
  if ([[BBBookmarksStore shared] isBookmarked:url]) [[BBBookmarksStore shared] removeURL:url];
  else [[BBBookmarksStore shared] addTitle:(self.activeTab.title.length?self.activeTab.title:url) url:url];
  [self updateStarButton]; [self reloadBookmarksBar];
}
// ── Hovered-link status bubble ────────────────────────────────────────────────
- (void)showStatus:(NSString *)url {
  if (!url.length) { self.statusBar.hidden=YES; return; }
  self.statusBar.stringValue=url;
  NSSize sz=[self.statusBar.cell cellSizeForBounds:NSMakeRect(0,0,self.root.bounds.size.width*0.7,20)];
  CGFloat w=MIN(self.root.bounds.size.width*0.7,MAX(80,sz.width+16));
  self.statusBar.frame=NSMakeRect(0,0,w,20);
  self.statusBar.hidden=NO;
  [self.root addSubview:self.statusBar positioned:NSWindowAbove relativeTo:nil];
}
- (void)showSecurityInfo:(id)s {
  NSURL *url=self.webView.URL;
  NSString *host=url.host?:@"";
  BOOL isHTTPS=[url.scheme isEqualToString:@"https"];
  NSMutableString *info=[NSMutableString string];

  if (!isHTTPS) {
    [info appendString:url?@"⚠️ Connection is NOT encrypted (HTTP)\nData sent to this site can be intercepted.\n":@"Internal page"];
  } else {
    [info appendString:@"🔒 Connection is encrypted (TLS)\n\n"];
    // Walk cert chain from stored trust
    SecTrustRef trust=self.currentTrust;
    if (trust) {
      CFArrayRef chain=SecTrustCopyCertificateChain(trust);
      CFIndex count=chain?CFArrayGetCount(chain):0;
      for (CFIndex i=0;i<count&&i<4;i++) {
        SecCertificateRef cert=(SecCertificateRef)CFArrayGetValueAtIndex(chain,i);
        // Subject summary
        CFStringRef subj=SecCertificateCopySubjectSummary(cert);
        // SHA-256 fingerprint
        CFDataRef der=SecCertificateCopyData(cert);
        NSData *derData=(__bridge_transfer NSData*)der;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(derData.bytes,derData.length,digest);
        NSMutableString *fp=[NSMutableString stringWithCapacity:64];
        for(int j=0;j<CC_SHA256_DIGEST_LENGTH;j++) [fp appendFormat:j?@":%02X":@"%02X",digest[j]];
        // Validity dates via long-form attributes
        NSDictionary *vals=(__bridge_transfer NSDictionary*)SecCertificateCopyValues(cert,
          (__bridge CFArrayRef)@[(__bridge id)kSecOIDX509V1ValidityNotBefore,
                                 (__bridge id)kSecOIDX509V1ValidityNotAfter,
                                 (__bridge id)kSecOIDX509V1SubjectName], NULL);
        NSNumber *nb=vals[(__bridge id)kSecOIDX509V1ValidityNotBefore][@"value"];
        NSNumber *na=vals[(__bridge id)kSecOIDX509V1ValidityNotAfter][@"value"];
        NSDateFormatter *df=[[NSDateFormatter alloc]init]; df.dateStyle=NSDateFormatterMediumStyle; df.timeStyle=NSDateFormatterNoStyle;
        NSString *from=nb?[df stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:nb.doubleValue]]:@"?";
        NSString *to  =na?[df stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:na.doubleValue]]:@"?";
        [info appendFormat:@"%@ %@\n  Valid: %@ – %@\n  SHA-256: %@\n\n",
          i==0?@"🏷":@"  ↳",
          (__bridge NSString*)subj?:@"(unknown)",
          from, to,
          [fp substringToIndex:MIN(47,(NSInteger)fp.length)]]; // first 16 bytes
        CFRelease(subj);
      }
      if(chain) CFRelease(chain);
    } else {
      [info appendString:@"(Certificate details not available — navigate to a page to inspect)"];
    }
  }
  // Show granted permissions for this host so the user can audit + reset them.
  if (host.length) {
    NSMutableArray *perms=[NSMutableArray array];
    NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];
    for (NSString *kind in @[@"camera",@"microphone",@"camera & microphone"]) {
      NSString *key=[NSString stringWithFormat:@"BBMediaPerm_%@_%@",kind,host];
      NSString *v=[ud stringForKey:key];
      if ([v isEqualToString:@"allow"]) [perms addObject:[NSString stringWithFormat:@"%@: allowed",kind]];
      else if ([v isEqualToString:@"deny"]) [perms addObject:[NSString stringWithFormat:@"%@: blocked",kind]];
    }
    if (perms.count) {
      [info appendString:@"\nPermissions:\n  • "];
      [info appendString:[perms componentsJoinedByString:@"\n  • "]];
    }
  }
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=host.length?host:@"BearBrowser";
  a.informativeText=info;
  a.alertStyle=isHTTPS?NSAlertStyleInformational:NSAlertStyleWarning;
  [a addButtonWithTitle:@"OK"];
  if (host.length) [a addButtonWithTitle:@"Reset Site Permissions"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if (rc==NSAlertSecondButtonReturn && host.length) {
      NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];
      NSString *suffix=[NSString stringWithFormat:@"_%@",host];
      for (NSString *key in [ud.dictionaryRepresentation.allKeys copy])
        if ([key hasPrefix:@"BBMediaPerm_"] && [key hasSuffix:suffix]) [ud removeObjectForKey:key];
    }
  }];
}

// ── WebView factory ───────────────────────────────────────────────────────────
- (WKWebViewConfiguration *)baseConfig:(BOOL)priv {
  WKWebViewConfiguration *config=[[WKWebViewConfiguration alloc]init];
  if (priv) config.websiteDataStore=[WKWebsiteDataStore nonPersistentDataStore];
  [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
  // Enable HTML5 Fullscreen API so YouTube/Netflix "f" works (no public API; WebKit pref).
  @try { [config.preferences setValue:@YES forKey:@"fullScreenEnabled"]; } @catch(...) {}
  // Allow inline video and picture-in-picture (required for YouTube/Netflix UX parity)
  config.allowsInlinePredictions=NO; // don't interfere with our own omnibox
  config.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
  config.allowsAirPlayForMediaPlayback=YES;
  // Third-party cookie isolation — block cross-site cookies via private KVC key
  @try { [config.websiteDataStore.httpCookieStore
    performSelector:NSSelectorFromString(@"_setStorageBlockingPolicy:") withObject:@1]; } @catch(...) {}
  // Normalize HTTP Accept-Language header at the network layer before any JS runs.
  // WKWebView inherits system locale for this header; override to en-US to prevent
  // locale fingerprinting via request headers (JS-layer Intl spoofing only covers
  // the JS context, not the actual HTTP header sent on every request).
  @try {
    [config setValue:@{@"Accept-Language": @"en-US,en;q=0.9"}
              forKey:@"_HTTPAdditionalHeaders"];
  } @catch(...) {}
  // PiP on macOS WKWebView is automatic via native video controls — no config flag needed
  // Font scheme handler — serves bbfont:// requests from bundled woff2 files
  [config setURLSchemeHandler:[[BBFontSchemeHandler alloc]init] forURLScheme:@"bbfont"];
  // Content rules (tracker/ad block + font CDN block)
  if (self.contentRuleList) [config.userContentController addContentRuleList:self.contentRuleList];
  // JS→native bridges
  [config.userContentController addScriptMessageHandler:self name:@"focusAddress"];
  [config.userContentController addScriptMessageHandler:self name:@"navigate"];
  [config.userContentController addScriptMessageHandler:self name:@"honeypot"];
  [config.userContentController addScriptMessageHandler:self name:@"netmon"];
  [config.userContentController addScriptMessageHandler:self name:@"secmon"];
  [config.userContentController addScriptMessageHandler:self name:@"historynav"];
  // Record SPA route changes (pushState/replaceState/popstate) into history — these
  // never trigger a full navigation, so didFinishNavigation alone would miss them.
  NSString *histHook=
    @"(function(){'use strict';"
    @"function bb(){try{window.webkit.messageHandlers.historynav.postMessage(location.href);}catch(e){}}"
    @"var p=history.pushState,r=history.replaceState;"
    @"history.pushState=function(){var v=p.apply(this,arguments);bb();return v;};"
    @"history.replaceState=function(){var v=r.apply(this,arguments);bb();return v;};"
    @"window.addEventListener('popstate',bb);"
    @"})();";
  [config.userContentController addUserScript:[[WKUserScript alloc]
    initWithSource:histHook injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
  // Hovered-link bubble (Chrome's bottom-left status), posted to `hoverlink`.
  [config.userContentController addScriptMessageHandler:self name:@"hoverlink"];
  NSString *hoverHook=
    @"(function(){'use strict';"
    @"function send(u){try{window.webkit.messageHandlers.hoverlink.postMessage(u||'');}catch(e){}}"
    @"document.addEventListener('mouseover',function(e){var n=e.target;"
    @"while(n&&n.tagName!=='A')n=n.parentElement;if(n&&n.href)send(n.href);},true);"
    @"document.addEventListener('mouseout',function(e){var n=e.target;"
    @"while(n&&n.tagName!=='A')n=n.parentElement;if(n)send('');},true);"
    @"})();";
  [config.userContentController addUserScript:[[WKUserScript alloc]
    initWithSource:hoverHook injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO]];
  // Audio-playing indicator — posts 1 when any audio/video starts, 0 when all stop.
  [config.userContentController addScriptMessageHandler:self name:@"audiostate"];
  NSString *audioHook=
    @"(function(){'use strict';"
    @"function post(v){try{window.webkit.messageHandlers.audiostate.postMessage(v);}catch(e){}}"
    @"function update(){"
    @"var active=[].slice.call(document.querySelectorAll('audio,video'))"
    @".some(function(m){return !m.paused&&!m.muted&&m.volume>0;});"
    @"post(active?1:0);}"
    @"document.addEventListener('play',update,true);"
    @"document.addEventListener('pause',update,true);"
    @"document.addEventListener('ended',update,true);"
    @"document.addEventListener('volumechange',update,true);"
    @"})();";
  [config.userContentController addUserScript:[[WKUserScript alloc]
    initWithSource:audioHook injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:NO]];
  // ── Login form autofill: save-on-submit + fill-on-load ────────────────────
  // Strategy: find each password field, walk up to its <form>, treat the most
  // plausible nearby text/email/tel input as the username. On submit, post the
  // values to native; native asks "Save?" then writes to Keychain. On DOMContent
  // we post the host so native can hand back stored credentials for offer-to-fill.
  [config.userContentController addScriptMessageHandler:self name:@"loginform"];
  NSString *autofillHook=
    @"(function(){'use strict';"
    @"function post(name,body){try{window.webkit.messageHandlers.loginform.postMessage({k:name,b:body});}catch(e){}}"
    @"function findUserFor(pw){var f=pw.form;if(!f)return null;var ins=f.querySelectorAll('input');var last=null;"
    @"for(var i=0;i<ins.length;i++){var n=ins[i];if(n===pw)break;var t=(n.type||'text').toLowerCase();"
    @"if(t==='text'||t==='email'||t==='tel'||t==='username')last=n;}return last;}"
    @"function isNewPw(pw){var a=(pw.getAttribute('autocomplete')||'').toLowerCase();"
    @"return a.indexOf('new-password')>=0;}"
    @"function bind(pw){if(pw.__bbBound)return;pw.__bbBound=true;var f=pw.form;if(!f)return;"
    @"f.addEventListener('submit',function(){try{var u=findUserFor(pw);if(!u||!u.value||!pw.value)return;"
    @"post('save',{host:location.host,user:String(u.value),pass:String(pw.value)});}catch(e){}},true);"
    @"pw.addEventListener('focus',function(){if(isNewPw(pw))post('genpassOffer',{host:location.host});},true);}"
    @"function scan(){document.querySelectorAll('input[type=password]').forEach(bind);}"
    @"function applyCred(cred){try{var pws=document.querySelectorAll('input[type=password]');"
    @"for(var i=0;i<pws.length;i++){var pw=pws[i],u=findUserFor(pw);if(!u)continue;"
    @"u.value=cred.user;pw.value=cred.pass;"
    @"u.dispatchEvent(new Event('input',{bubbles:true}));u.dispatchEvent(new Event('change',{bubbles:true}));"
    @"pw.dispatchEvent(new Event('input',{bubbles:true}));pw.dispatchEvent(new Event('change',{bubbles:true}));"
    @"return;}}catch(e){}}"
    @"function applyGenPass(p){try{var pws=document.querySelectorAll('input[type=password]');"
    @"for(var i=0;i<pws.length;i++){var pw=pws[i];if(!isNewPw(pw)&&pws.length>1)continue;"
    @"pw.value=p;pw.dispatchEvent(new Event('input',{bubbles:true}));pw.dispatchEvent(new Event('change',{bubbles:true}));"
    @"return;}}catch(e){}}"
    @"window.__bbAutofill=applyCred;"
    @"window.__bbApplyGenPass=applyGenPass;"
    @"function reportEdit(){var a=document.activeElement;"
    @"var e=!!(a&&(a.isContentEditable||a.tagName==='INPUT'||a.tagName==='TEXTAREA'));"
    @"post('editFocus',{e:e});}"
    @"document.addEventListener('focusin',reportEdit,true);"
    @"document.addEventListener('focusout',reportEdit,true);"
    @"function fieldKey(el){var a=(el.getAttribute('autocomplete')||'').toLowerCase();"
    @"if(a){if(a.indexOf('email')>=0)return'email';if(a.indexOf('tel')>=0)return'phone';"
    @"if(a==='name'||a==='cc-name')return'name';if(a==='given-name'||a==='additional-name'||a==='family-name')return'name';"
    @"if(a==='street-address'||a==='address-line1')return'street';"
    @"if(a==='address-level2')return'city';if(a==='address-level1')return'region';"
    @"if(a==='postal-code')return'postal';if(a==='country'||a==='country-name')return'country';"
    @"if(a==='organization')return'organization';}"
    @"var k=((el.name||'')+' '+(el.id||'')+' '+(el.getAttribute('placeholder')||'')).toLowerCase();"
    @"if(/(^|[^a-z])(email|e-mail)([^a-z]|$)/.test(k))return'email';"
    @"if(/(phone|tel|mobile)/.test(k))return'phone';"
    @"if(/(fname|firstname|first.name|fullname|full.name|^name$|your.name)/.test(k))return'name';"
    @"if(/(street|address.?1|addr1|address$)/.test(k))return'street';"
    @"if(/(city|town|locality)/.test(k))return'city';"
    @"if(/(state|province|region)/.test(k))return'region';"
    @"if(/(zip|postal|postcode)/.test(k))return'postal';"
    @"if(/(country)/.test(k))return'country';"
    @"if(/(company|organi[sz]ation)/.test(k))return'organization';"
    @"return'';}"
    @"function applyProfile(p){try{var ins=document.querySelectorAll('input,select,textarea');"
    @"for(var i=0;i<ins.length;i++){var n=ins[i];var t=(n.type||'').toLowerCase();"
    @"if(t==='password'||t==='hidden'||t==='checkbox'||t==='radio'||t==='submit'||t==='button')continue;"
    @"var k=fieldKey(n);if(!k||!p[k])continue;if(n.value)continue;"
    @"n.value=p[k];n.dispatchEvent(new Event('input',{bubbles:true}));n.dispatchEvent(new Event('change',{bubbles:true}));}"
    @"}catch(e){}}"
    @"window.__bbApplyProfile=applyProfile;"
    @"function hasProfileField(){var ins=document.querySelectorAll('input,select,textarea');"
    @"for(var i=0;i<ins.length;i++){if(fieldKey(ins[i]))return true;}return false;}"
    @"function maybeOfferProfile(){if(hasProfileField())post('profileLookup',{host:location.host});}"
    @"document.addEventListener('DOMContentLoaded',function(){scan();post('lookup',{host:location.host});maybeOfferProfile();},true);"
    @"new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true});"
    @"if(document.readyState!=='loading'){scan();post('lookup',{host:location.host});maybeOfferProfile();}"
    @"})();";
  [config.userContentController addUserScript:[[WKUserScript alloc]
    initWithSource:autofillHook injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
  // ── Fingerprinting shield (injected before any page script runs) ──────────
  // Cross-referenced against Mozilla Bugzilla RFP bugs and Firefox test suite:
  //   Bug 418986  (FIXED)  — screen / CSS media query resolution
  //   Bug 1358149 (FIXED)  — AudioContext fingerprinting
  //   Bug 1896836 (FIXED)  — timezone normalization
  //   Bug 2043367 (NEW)    — WebSpeech getVoices()
  //   Bug 2043403 (ASSIGNED) — WebGPU adapter info
  //   Firefox RFP: browser_dynamical_window_rounding.js,
  //     browser_reduceTimePrecision_iframes.js, browser_animationapi_iframes.js,
  //     browser_device_sensor_event.js, browser_timezone.js
  NSString *shield=
    @"(function(){'use strict';"
    // ── Native function spoofing — set up FIRST before any overrides ─────────
    // Fingerprinters call fn.toString() or Function.prototype.toString.call(fn)
    // to detect overrides. We intercept toString() and return "[native code]"
    // strings for any function we register. The override itself is named via
    // object method shorthand to give .name === 'toString' and .length === 0,
    // matching the real native exactly.
    @"const _nativeMap=new WeakMap();"
    @"const _fpts=Function.prototype.toString;"
    @"const _toStr={toString(){return _nativeMap.has(this)?_nativeMap.get(this):_fpts.call(this);}}['toString'];"
    @"Function.prototype.toString=_toStr;"
    @"_nativeMap.set(Function.prototype.toString,'function toString() { [native code] }');"
    // _nat(fn, name) — mark fn as native-looking and return it
    @"const _nat=function(fn,name){"
    @"  _nativeMap.set(fn,'function '+(name||fn.name||'')+'() { [native code] }');"
    @"  return fn;};"
    // ── Canvas: hook both toDataURL and getImageData to prevent bypass ──────
    // toDataURL-only hooking lets fingerprinters call getImageData directly.
    // Per-session random bit mask: different per browser launch so two sessions
    // of BearBrowser can't be correlated by the fingerprinter's hash.
    // Keep ≤1 LSB change per channel so visual output is imperceptible.
    // Per-session canvas noise: choose one of 4 low-bit XOR masks (1–4) so the
    // modification is at most 1.6% per channel (imperceptible) but session-unique.
    @"const _cnSeed=(Math.floor(Math.random()*4)+1);"
    @"const _noise=function(d){"
    @"  for(let i=0;i<d.data.length;i+=100)d.data[i]^=_cnSeed;"
    @"};"
    @"const _toDU=HTMLCanvasElement.prototype.toDataURL;"
    @"HTMLCanvasElement.prototype.toDataURL=_nat(function(t,q){"
    @"  try{const c=this.getContext('2d');if(c&&this.width&&this.height){"
    @"    const d=_gID.call(c,0,0,this.width,this.height);"
    @"    _noise(d);c.putImageData(d,0,0);"
    @"  }}catch(e){}"
    @"  return _toDU.call(this,t,q);},'toDataURL');"
    @"const _toBl=HTMLCanvasElement.prototype.toBlob;"
    @"if(_toBl)HTMLCanvasElement.prototype.toBlob=_nat(function(cb,t,q){"
    @"  try{const c=this.getContext('2d');if(c&&this.width&&this.height){"
    @"    const d=_gID.call(c,0,0,this.width,this.height);"
    @"    _noise(d);c.putImageData(d,0,0);"
    @"  }}catch(e){}"
    @"  return _toBl.call(this,cb,t,q);},'toBlob');"
    @"const _gID=CanvasRenderingContext2D.prototype.getImageData;"
    @"CanvasRenderingContext2D.prototype.getImageData=_nat(function(x,y,w,h){"
    @"  const d=_gID.call(this,x,y,w,h);"
    @"  _noise(d);return d;},'getImageData');"
    // ── WebGL: VENDOR/RENDERER + freeze extensions list ────────────────────
    @"const _glGP=function(orig){"
    @"  return function(p){"
    @"    if(p===37445)return 'Google Inc. (Apple)';"  // UNMASKED_VENDOR_WEBGL
    @"    if(p===37446)return 'ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)';"  // UNMASKED_RENDERER_WEBGL
    @"    if(p===35724)return 'WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)';"  // SHADING_LANGUAGE_VERSION
    @"    if(p===7936)return 'WebKit';"    // VENDOR
    @"    if(p===7937)return 'WebKit WebGL';"   // RENDERER
    @"    if(p===7938)return 'WebGL 1.0 (OpenGL ES 2.0 Chromium)';"  // VERSION
    @"    if(p===3379)return 16384;"    // MAX_TEXTURE_SIZE
    @"    if(p===34024)return 16384;"   // MAX_RENDERBUFFER_SIZE
    @"    if(p===34921)return 16;"      // MAX_VERTEX_ATTRIBS
    @"    if(p===36347)return 4096;"    // MAX_VERTEX_UNIFORM_VECTORS
    @"    if(p===36348)return 1024;"    // MAX_FRAGMENT_UNIFORM_VECTORS
    @"    if(p===34930)return 16;"      // MAX_TEXTURE_IMAGE_UNITS
    @"    if(p===35661)return 80;"      // MAX_COMBINED_TEXTURE_IMAGE_UNITS
    @"    if(p===3410||p===3411||p===3412||p===3413)return 8;"  // R/G/B/A_BITS
    @"    if(p===3414)return 24;"       // DEPTH_BITS
    @"    if(p===3415)return 8;"        // STENCIL_BITS
    @"    if(p===3386)try{return new Int32Array([16384,16384]);}catch(e){}"   // MAX_VIEWPORT_DIMS
    @"    if(p===33902)try{return new Float32Array([1,1]);}catch(e){}"        // ALIASED_LINE_WIDTH_RANGE
    @"    if(p===33901)try{return new Float32Array([1,511]);}catch(e){}"      // ALIASED_POINT_SIZE_RANGE
    @"    return orig.call(this,p);};};"
    @"WebGLRenderingContext.prototype.getParameter=_glGP(WebGLRenderingContext.prototype.getParameter);"
    @"if(window.WebGL2RenderingContext)"
    @"  WebGL2RenderingContext.prototype.getParameter=_glGP(WebGL2RenderingContext.prototype.getParameter);"
    // Normalize shader precision — GPU floating-point precision varies by hardware and
    // is used by BrowserLeaks and others to fingerprint GPU vendor. Return standard
    // desktop GPU precision (highp mediump lowp all identical = generic Metal device).
    @"WebGLRenderingContext.prototype.getShaderPrecisionFormat=function(){"
    @"  return{precision:23,rangeMin:127,rangeMax:127};};"
    @"if(window.WebGL2RenderingContext)"
    @"  WebGL2RenderingContext.prototype.getShaderPrecisionFormat="
    @"    WebGLRenderingContext.prototype.getShaderPrecisionFormat;"
    // Freeze extensions list to a fixed Safari-on-M1 subset (removes GPU-specific entries)
    @"const _glExt=['ANGLE_instanced_arrays','EXT_blend_minmax','EXT_color_buffer_half_float',"
    @"  'EXT_float_blend','EXT_frag_depth','EXT_shader_texture_lod','EXT_texture_compression_bptc',"
    @"  'EXT_texture_compression_rgtc','EXT_texture_filter_anisotropic','EXT_sRGB',"
    @"  'KHR_parallel_shader_compile','OES_element_index_uint','OES_fbo_render_mipmap',"
    @"  'OES_standard_derivatives','OES_texture_float','OES_texture_float_linear',"
    @"  'OES_texture_half_float','OES_texture_half_float_linear','OES_vertex_array_object',"
    @"  'WEBGL_color_buffer_float','WEBGL_compressed_texture_astc','WEBGL_compressed_texture_etc',"
    @"  'WEBGL_compressed_texture_etc1','WEBGL_compressed_texture_pvrtc','WEBGL_compressed_texture_s3tc',"
    @"  'WEBGL_compressed_texture_s3tc_srgb','WEBGL_debug_renderer_info','WEBGL_debug_shaders',"
    @"  'WEBGL_depth_texture','WEBGL_draw_buffers','WEBGL_lose_context','WEBGL_multi_draw'];"
    @"const _getSE=WebGLRenderingContext.prototype.getSupportedExtensions;"
    @"WebGLRenderingContext.prototype.getSupportedExtensions=function(){return _glExt.slice();};"
    @"if(window.WebGL2RenderingContext){"
    @"  const _getSE2=WebGL2RenderingContext.prototype.getSupportedExtensions;"
    @"  WebGL2RenderingContext.prototype.getSupportedExtensions=function(){return _glExt.slice();};"
    @"}"
    // ── Screen: round to 200×100 buckets (Firefox RFP approach, bug 418986) ─
    @"const _sw=1280,_sh=800;"  // fixed safe-zone — matches most Safari traffic
    @"try{Object.defineProperties(screen,{"
    @"  width:{get:()=>_sw,configurable:false},"
    @"  height:{get:()=>_sh,configurable:false},"
    @"  availWidth:{get:()=>_sw,configurable:false},"
    @"  availHeight:{get:()=>_sh,configurable:false},"
    // availLeft/Top expose dock/taskbar size and multi-monitor offsets
    @"  availLeft:{get:()=>0,configurable:false},"
    @"  availTop:{get:()=>0,configurable:false},"
    // isExtended reveals if a second display is attached (strong monitor fingerprint)
    @"  isExtended:{get:()=>false,configurable:false},"
    @"  colorDepth:{get:()=>24,configurable:false},"
    @"  pixelDepth:{get:()=>24,configurable:false}"
    @"});}catch(e){}"
    // devicePixelRatio — 2.0 is dominant Safari/Retina value, not 1.0 (which is rare)
    @"try{Object.defineProperty(window,'devicePixelRatio',{get:()=>2,configurable:false});}catch(e){}"
    // outerWidth/outerHeight = innerWidth/innerHeight (no chrome height leak)
    @"try{Object.defineProperty(window,'outerWidth',{get:()=>window.innerWidth,configurable:false});}catch(e){}"
    @"try{Object.defineProperty(window,'outerHeight',{get:()=>window.innerHeight,configurable:false});}catch(e){}"
    // screenX/screenY — window position on desktop; reveals monitor layout and multi-display
    @"try{Object.defineProperty(window,'screenX',{get:()=>0,configurable:false});}catch(e){}"
    @"try{Object.defineProperty(window,'screenY',{get:()=>0,configurable:false});}catch(e){}"
    @"try{Object.defineProperty(window,'screenLeft',{get:()=>0,configurable:false});}catch(e){}"
    @"try{Object.defineProperty(window,'screenTop',{get:()=>0,configurable:false});}catch(e){}"
    // ── Navigator hardening ────────────────────────────────────────────────
    @"try{Object.defineProperties(navigator,{"
    @"  hardwareConcurrency:{get:()=>4,configurable:false},"
    @"  deviceMemory:{get:()=>4,configurable:false},"
    @"  languages:{get:()=>Object.freeze(['en-US','en']),configurable:false},"
    @"  platform:{get:()=>'MacIntel',configurable:false},"
    @"  maxTouchPoints:{get:()=>0,configurable:false}"
    @"});}catch(e){}"
    // UA-CH (navigator.userAgentData) — delete entirely; Safari doesn't expose it
    @"try{Object.defineProperty(navigator,'userAgentData',{get:()=>undefined,configurable:false});}catch(e){}"
    // navigator.connection / NetworkInformation — remove network quality signal
    @"try{Object.defineProperty(navigator,'connection',{get:()=>undefined,configurable:false});}catch(e){}"
    // Battery API removed
    @"if(navigator.getBattery)try{delete navigator.__proto__.getBattery;}catch(e){navigator.getBattery=undefined;}"
    // ── Full navigator identity — must match claimed UA (Safari 17.6 / macOS) ─
    // WebKit already sets vendor and productSub correctly, but explicitly
    // asserting them makes the values immune to override by site scripts.
    @"try{Object.defineProperties(navigator,{"
    @"  vendor:{get:()=>'Apple Computer, Inc.',configurable:false},"
    @"  vendorSub:{get:()=>'',configurable:false},"
    @"  productSub:{get:()=>'20030107',configurable:false},"
    @"  appName:{get:()=>'Netscape',configurable:false},"
    @"  product:{get:()=>'Gecko',configurable:false},"
    // pdfViewerEnabled: Chrome 104+ reports true; WKWebView omits it entirely.
    // fingerprintjs and creepjs probe this as a Chrome-vs-other signal.
    @"  pdfViewerEnabled:{get:()=>true,configurable:false}"
    @"});}catch(e){}"
    // Firefox-only properties that leak Gecko even when UA claims Safari
    @"try{if('oscpu'in navigator)Object.defineProperty(navigator,'oscpu',{get:()=>undefined,configurable:false});}catch(e){}"
    @"try{if('buildID'in navigator)Object.defineProperty(navigator,'buildID',{get:()=>undefined,configurable:false});}catch(e){}"
    // plugins / mimeTypes — replicate the standard Chrome/Safari 5-entry PDF plugin set.
    // An empty PluginArray is the single clearest WKWebView signal to fingerprinters.
    // All modern browsers (Chrome 109+, Safari 17+) return exactly these 5 plugins.
    @"try{(function(){"
    @"  function _mkMT(type,plug){"
    @"    return{type:type,suffixes:'pdf',description:'Portable Document Format',"
    @"      enabledPlugin:plug};}"
    @"  function _mkP(name,file){"
    @"    const p=Object.create(null);"
    @"    p.name=name;p.description='Portable Document Format';p.filename=file;"
    @"    const mt0=_mkMT('application/pdf',p);const mt1=_mkMT('text/pdf',p);"
    @"    p[0]=mt0;p[1]=mt1;p.length=2;"
    @"    p.item=function(i){return p[i];};p.namedItem=function(n){"
    @"      return n==='application/pdf'?mt0:n==='text/pdf'?mt1:null;};"
    @"    p[Symbol.iterator]=function*(){yield p[0];yield p[1];};"
    @"    return p;}"
    @"  const _pl=['PDF Viewer','Chrome PDF Viewer','Chromium PDF Viewer',"
    @"             'Microsoft Edge PDF Viewer','WebKit built-in PDF'];"
    @"  const _pa=Object.create(null);"
    @"  const _plugins=_pl.map(function(n){return _mkP(n,'internal-pdf-viewer');});"
    @"  _plugins.forEach(function(p,i){_pa[i]=p;});_pa.length=_plugins.length;"
    @"  _pa.item=function(i){return _pa[i];};"
    @"  _pa.namedItem=function(n){for(let i=0;i<_pa.length;i++)if(_pa[i].name===n)return _pa[i];return null;};"
    @"  _pa.refresh=function(){};_pa[Symbol.iterator]=function*(){"
    @"    for(let i=0;i<_pa.length;i++)yield _pa[i];};"
    @"  Object.defineProperty(navigator,'plugins',{get:function(){return _pa;},configurable:false});"
    // MimeTypeArray — application/pdf and text/pdf pointing back to first plugin
    @"  const _ma=Object.create(null);const _mt0=_mkMT('application/pdf',_plugins[0]);"
    @"  const _mt1=_mkMT('text/pdf',_plugins[0]);"
    @"  _ma[0]=_mt0;_ma[1]=_mt1;_ma.length=2;"
    @"  _ma.item=function(i){return _ma[i];};"
    @"  _ma.namedItem=function(n){return n==='application/pdf'?_mt0:n==='text/pdf'?_mt1:null;};"
    @"  _ma[Symbol.iterator]=function*(){yield _ma[0];yield _ma[1];};"
    @"  Object.defineProperty(navigator,'mimeTypes',{get:function(){return _ma;},configurable:false});"
    @"})();}catch(e){}"
    // ── performance.now() — 1ms integer floor, no sub-ms jitter ─────────────
    // Pure floor to integer ms. Adding random jitter within the bucket is
    // counterproductive: it leaks the bucket boundary via averaging attacks.
    // Fixed-bucket rounding is what Firefox RFP and Tor Browser actually do.
    @"const _pNow=performance.now.bind(performance);"
    @"performance.now=_nat(function(){return Math.floor(_pNow());},'now');"
    // performance.timeOrigin — the epoch-relative page-start timestamp.
    // Unclamped it is a high-precision float (sub-ms) unique per page load.
    // Tor Browser clamps to 100ms buckets. Match that here.
    @"try{"
    @"  const _origTO=performance.timeOrigin;"
    @"  Object.defineProperty(performance,'timeOrigin',{"
    @"    get:_nat(function(){return Math.floor(_origTO/100)*100;},'timeOrigin'),"
    @"    configurable:false});"
    @"}catch(e){}"
    // Date.now: 100ms buckets — coarser than performance.now to prevent
    // timer reconstruction by subtracting a Date.now baseline.
    @"const _dNow=Date.now;"
    @"Date.now=_nat(function(){return Math.floor(_dNow()/100)*100;},'now');"
    // ── Timezone: normalize to UTC (Firefox RFP: browser_timezone.js) ─────
    @"try{"
    @"  const _rO=Intl.DateTimeFormat.prototype.resolvedOptions;"
    @"  Intl.DateTimeFormat.prototype.resolvedOptions=function(){"
    @"    const r=_rO.call(this);"
    @"    return {...r,timeZone:'UTC'};};"
    @"  const _DTF=Intl.DateTimeFormat;"
    @"  window.Intl=Object.assign(Object.create(Intl),{DateTimeFormat:function(loc,opts){"
    @"    return new _DTF(loc,{...opts,timeZone:'UTC'});}});"
    @"  window.Intl.DateTimeFormat.prototype=_DTF.prototype;"
    @"  window.Intl.DateTimeFormat.supportedLocalesOf=_DTF.supportedLocalesOf;"
    @"}catch(e){}"
    // Date.prototype.getTimezoneOffset → always 0 (UTC)
    @"try{Date.prototype.getTimezoneOffset=function(){return 0;};}catch(e){}"
    // ── AudioContext fingerprinting (Mozilla bug 1358149) ─────────────────
    // Normalize sampleRate to 44100 and add ±1 LSB noise to analyser output
    @"if(window.AudioContext||window.webkitAudioContext){"
    @"  const _AC=window.AudioContext||window.webkitAudioContext;"
    @"  const _ACp=_AC.prototype;"
    @"  const _cAC=function(opts){"
    @"    const ctx=new _AC(opts);"
    @"    Object.defineProperty(ctx,'sampleRate',{get:()=>44100,configurable:false});"
    @"    Object.defineProperty(ctx,'baseLatency',{get:()=>0.01,configurable:false});"
    @"    const _ca=ctx.createAnalyser.bind(ctx);"
    @"    ctx.createAnalyser=function(){"
    @"      const an=_ca();"
    @"      const _gFD=an.getFloatFrequencyData.bind(an);"
    @"      an.getFloatFrequencyData=function(arr){_gFD(arr);"
    @"        for(let i=0;i<arr.length;i+=10)arr[i]+=Math.random()*0.0001-0.00005;};"
    @"      return an;};"
    @"    return ctx;};"
    // _cAC is the wrapper function — set its prototype so instanceof checks pass,
    // then replace the global constructors. DO NOT use Object.create(AudioContext)
    // here: that creates a plain object inheriting from a native function, and
    // assigning its .prototype throws TypeError in strict mode (readonly inherited).
    @"  _cAC.prototype=_ACp;"
    @"  if(window.AudioContext)window.AudioContext=_cAC;"
    @"  if(window.webkitAudioContext)window.webkitAudioContext=_cAC;"
    @"}"
    // ── AudioBuffer noise — OfflineAudioContext fingerprint path ──────────
    // The dominant audio fingerprint (EFF coveryourtracks, fingerprintjs) uses
    // OfflineAudioContext + OscillatorNode + DynamicsCompressor then reads the
    // rendered buffer via AudioBuffer.getChannelData(). The result is a
    // CPU/FPU-specific float array that produces a unique ~32-bit hash.
    // Our AnalyserNode noise above is the wrong path. Fix: intercept
    // getChannelData/copyFromChannel on the returned AudioBuffer and add a
    // session-stable ±1e-7 offset to every Nth sample.
    @"try{if(window.AudioBuffer){"
    @"  const _aOff=(Math.random()-0.5)*2e-7;"  // imperceptible, stable per session
    @"  const _gCD=AudioBuffer.prototype.getChannelData;"
    @"  AudioBuffer.prototype.getChannelData=_nat(function(ch){"
    @"    const d=_gCD.call(this,ch);"
    @"    const c=new Float32Array(d);"  // copy — don't mutate the internal buffer
    @"    for(let i=0;i<c.length;i+=100)c[i]=Math.fround(c[i]+_aOff);"
    @"    return c;},'getChannelData');"
    @"  const _cFC=AudioBuffer.prototype.copyFromChannel;"
    @"  AudioBuffer.prototype.copyFromChannel=_nat(function(dest,ch,off){"
    @"    _cFC.call(this,dest,ch,off);"
    @"    for(let i=0;i<dest.length;i+=100)dest[i]=Math.fround(dest[i]+_aOff);"
    @"  },'copyFromChannel');"
    @"}}catch(e){}"
    // ── WebSpeech: freeze getVoices() to empty (bug 2043367 — unfixed upstream too) ─
    @"if(window.speechSynthesis){"
    // Override via Object.defineProperty on the prototype for maximum coverage:
    // direct assignment may fail silently if getVoices is an own property of
    // the speechSynthesis instance in some WebKit builds.
    @"  try{Object.defineProperty(SpeechSynthesis.prototype,'getVoices',{"
    @"    value:function(){return [];},writable:true,configurable:true"
    @"  });}catch(e){}"
    @"  try{Object.defineProperty(window.speechSynthesis,'getVoices',{"
    @"    value:function(){return [];},writable:true,configurable:true"
    @"  });}catch(e){}"
    @"  try{window.removeEventListener('voiceschanged',function(){},true);}catch(e){}"
    // window.SpeechSynthesisVoice is non-writable in strict mode — must use defineProperty
    @"  try{Object.defineProperty(window,'SpeechSynthesisVoice',{value:undefined,configurable:true});}catch(e){}"
    @"}"
    // ── WebRTC IP leak ────────────────────────────────────────────────────
    // Stripping iceServers alone does NOT prevent local IP exposure:
    // mDNS candidates (*.local) are generated regardless of iceServers config.
    // The correct fix is to suppress icecandidate events at the object level
    // so no candidate (host, srflx, relay, mDNS) ever fires to page JS.
    @"try{const _RPC=window.RTCPeerConnection||window.webkitRTCPeerConnection;"
    @"if(_RPC){const _rpcW=_nat(function(cfg,con){"
    @"  const pc=new _RPC(cfg,con);"
    @"  const _origAEL=pc.addEventListener.bind(pc);"
    @"  pc.addEventListener=function(t,fn,opts){"
    @"    if(t==='icecandidate')return;return _origAEL(t,fn,opts);};"
    @"  Object.defineProperty(pc,'onicecandidate',{"
    @"    set:function(){},get:function(){return null;},configurable:true});"
    @"  return pc;},'RTCPeerConnection');"
    @"  _rpcW.prototype=_RPC.prototype;window.RTCPeerConnection=_rpcW;"
    @"}}catch(e){}"
    // ── window.name — cross-origin tracking channel ──────────────────────
    // window.name persists across same-tab navigations to other origins and is a
    // classic tracking vector (site sets name = userId, navigates away, partner
    // reads it back). Clear it on cross-origin navigation AND block writes with
    // a no-op setter so the current page can't seed it in the first place.
    // Shadow window.name FIRST (separate try so MutationObserver failure can't block it)
    @"try{Object.defineProperty(window,'name',{get:function(){return '';},set:function(){},configurable:false});}catch(e){}"
    @"try{"
    @"  let _lastOrigin=location.origin;"
    @"  const _obs=new MutationObserver(function(){"
    @"    if(location.origin!==_lastOrigin){window.name='';_lastOrigin=location.origin;}"
    @"  });"
    @"  _obs.observe(document,{childList:true,subtree:false});"
    @"  window.addEventListener('beforeunload',function(){window.name='';},true);"
    @"}catch(e){}"
    // ── WebKit-prefixed API consistency ───────────────────────────────────
    // These webkit-prefixed APIs are legacy but present in WKWebView/Safari.
    // Ensure they exist so WKWebView presents a complete Safari-compatible profile.
    @"try{if(!navigator.webkitPersistentStorage)"
    @"  Object.defineProperty(navigator,'webkitPersistentStorage',{get:function(){"
    @"    return{requestQuota:function(){},queryUsageAndQuota:function(){}};},"
    @"  configurable:false});}catch(e){}"
    @"try{if(!navigator.webkitTemporaryStorage)"
    @"  Object.defineProperty(navigator,'webkitTemporaryStorage',{get:function(){"
    @"    return{requestQuota:function(){},queryUsageAndQuota:function(){}};},"
    @"  configurable:false});}catch(e){}"
    @"try{if(!window.webkitResolveLocalFileSystemURL)"
    @"  window.webkitResolveLocalFileSystemURL=function(){};}catch(e){}"
    @"try{if(!window.webkitMediaStream&&window.MediaStream)"
    @"  window.webkitMediaStream=window.MediaStream;}catch(e){}"
    @"try{if(!window.webkitSpeechGrammar)"
    @"  window.webkitSpeechGrammar=function webkitSpeechGrammar(){};}catch(e){}"
    // ── Deprecated WebKit APIs — consistently absent from modern Safari 17 ──
    // These old webkit-prefixed globals were removed from Safari 12+ and
    // serve no legitimate use in modern WKWebView. Removing them gives the
    // browser a cleaner, modern Safari profile and reduces API surface.
    @"try{if(window.WebKitCSSMatrix)window.WebKitCSSMatrix=undefined;}catch(e){}"
    @"try{if(window.webkitStorageInfo)window.webkitStorageInfo=undefined;}catch(e){}"
    // ── WebGPU — delete navigator.gpu entirely (Bug 2043403) ─────────────
    // GPU adapter.requestAdapterInfo() exposes vendor, architecture, device, description
    // at hardware-serial granularity. No partial fix is adequate; remove the API.
    @"try{Object.defineProperty(navigator,'gpu',{get:()=>undefined,configurable:false});}catch(e){}"
    @"try{window.GPU=undefined;window.GPUAdapter=undefined;window.GPUDevice=undefined;"
    @"  window.GPUBuffer=undefined;window.GPUTexture=undefined;}catch(e){}"
    // ── Font enumeration via measureText (Bug 1336208 — Firefox WONTFIX, we fix) ─
    // fingerprinters call measureText() with text in each candidate font and compare
    // widths against a baseline. Per-session noise makes each session's widths unique
    // but consistent within the session (same font+text → same delta).
    @"(function(){"
    @"  const _s=Math.random().toString(36).slice(2);" // per-session salt
    @"  function _fh(str){"                             // FNV-1a 32-bit hash
    @"    let h=0x811c9dc5;"
    @"    for(let i=0;i<str.length;i++){h^=str.charCodeAt(i);h=(h*0x01000193)>>>0;}"
    @"    return h;}"
    @"  const _mT=CanvasRenderingContext2D.prototype.measureText;"
    @"  CanvasRenderingContext2D.prototype.measureText=function(text){"
    @"    const r=_mT.call(this,text);"
    @"    const _key=(text||'')+(this.font||'')+_s;"
    @"    const noise=((_fh(_key)%5)-2)*0.1;" // ±0.2px, consistent per (font,text,session)
    @"    try{Object.defineProperty(r,'width',{value:Math.max(0,r.width+noise)});}catch(e){}"
    // Also noise TextMetrics bounding box props — these are precise enough to
    // fingerprint the font renderer independently of .width.
    @"    const _bbProps=['actualBoundingBoxLeft','actualBoundingBoxRight',"
    @"      'actualBoundingBoxAscent','actualBoundingBoxDescent',"
    @"      'fontBoundingBoxAscent','fontBoundingBoxDescent',"
    @"      'emHeightAscent','emHeightDescent'];"
    @"    for(const p of _bbProps){try{if(p in r){"
    @"      const n=((_fh(_key+p)%5)-2)*0.05;" // ±0.1px on box props
    @"      Object.defineProperty(r,p,{value:Math.max(0,r[p]+n)});}}catch(e){}}"
    @"    return r;};"
    // Also block document.fonts.check() — CSS local() font presence oracle
    // Override on FontFaceSet.prototype: instance-level assignment is blocked
    // when the descriptor is non-configurable/non-writable on the instance.
    @"  try{FontFaceSet.prototype.check=function(){return false;};}catch(e){}"
    @"  if(document.fonts&&document.fonts.check)"
    @"    try{document.fonts.check=function(){return false;};}catch(e){}"
    // document.fonts.load() — fingerprinters probe font presence by calling
    // load() and checking whether it resolves with an entry. Return [] always.
    @"  try{FontFaceSet.prototype.load=function(){return Promise.resolve([]);};}catch(e){}"
    @"})();"
    // ── requestAnimationFrame timing (Firefox browser_animationapi_iframes.js) ─
    // rAF timestamps are high-resolution and can be used to fingerprint frame timing
    // characteristics. Truncate to 1ms, matching our performance.now() precision.
    @"(function(){"
    @"  const _rAF=window.requestAnimationFrame.bind(window);"
    @"  window.requestAnimationFrame=function(cb){"
    @"    return _rAF(function(ts){cb(Math.floor(ts));});};"
    // Also clamp the AnimationFrameProvider in workers if present
    @"})();"
    // ── Device sensors (Firefox browser_device_sensor_event.js) ──────────
    // DeviceOrientationEvent and DeviceMotionEvent expose hardware accelerometer/gyro
    // readings which are device-unique. Block listener registration for these types.
    // Generic Sensor API (Accelerometer etc.) — delete entirely.
    @"(function(){"
    @"  const _sensorEvents=new Set(["
    @"    'deviceorientation','devicemotion','deviceorientationabsolute',"
    @"    'compassneedscalibration']);"
    @"  const _ael=EventTarget.prototype.addEventListener;"
    @"  EventTarget.prototype.addEventListener=function(type,fn,opts){"
    @"    if(typeof type==='string'&&_sensorEvents.has(type.toLowerCase()))return;"
    @"    return _ael.call(this,type,fn,opts);};"
    // Dispatch a fake zero-value orientation event to satisfy sites that wait for one
    @"  Object.defineProperty(window,'DeviceOrientationEvent',{"
    @"    get:function(){return undefined;},configurable:false});"
    @"  Object.defineProperty(window,'DeviceMotionEvent',{"
    @"    get:function(){return undefined;},configurable:false});"
    // Generic Sensor API (W3C spec, Chrome-origin) — all expose hardware characteristics
    @"  ['Accelerometer','Gyroscope','Magnetometer','AbsoluteOrientationSensor',"
    @"   'RelativeOrientationSensor','LinearAccelerationSensor','GravitySensor',"
    @"   'AmbientLightSensor'].forEach(function(n){"
    @"     try{Object.defineProperty(window,n,{get:()=>undefined,configurable:false});}catch(e){}});"
    // screen.orientation — exposes display rotation, hardware form-factor signal
    @"  try{Object.defineProperty(screen,'orientation',{get:()=>({"
    @"    type:'landscape-primary',angle:0,"
    @"    addEventListener:function(){},removeEventListener:function(){}"
    @"  }),configurable:false});}catch(e){}"
    @"})();"
    // ── Navigator / window identity normalization ────────────────────────
    // doNotTrack and webdriver: define on Navigator.prototype so the override
    // works even when the instance property is non-configurable (Playwright,
    // some WebKit builds). Prototype-level override takes precedence over a
    // missing or undefined instance property.
    @"try{Object.defineProperty(Navigator.prototype,'doNotTrack',{get:()=>'1',configurable:true});}catch(e){}"
    @"try{Object.defineProperty(Navigator.prototype,'webdriver',{get:()=>undefined,configurable:true});}catch(e){}"
    // window.chrome: Safari/WKWebView does not expose this object. Its absence
    // is consistent with our Safari UA. If WebKit ever adds a chrome property,
    // hide it to prevent leaking WebKit internals.
    @"try{if('chrome'in window)Object.defineProperty(window,'chrome',{get:()=>undefined,configurable:false});}catch(e){}"
    // ── Intl locale normalization ─────────────────────────────────────────
    // Intl APIs can expose OS locale even when navigator.languages is spoofed.
    // Collator, NumberFormat, ListFormat all expose locale via resolvedOptions().
    @"try{"
    @"  const _IC=Intl.Collator.prototype.resolvedOptions;"
    @"  Intl.Collator.prototype.resolvedOptions=_nat(function(){"
    @"    const r=_IC.call(this);return{...r,locale:'en-US'};},'resolvedOptions');"
    @"  if(Intl.NumberFormat){"
    @"    const _IN=Intl.NumberFormat.prototype.resolvedOptions;"
    @"    Intl.NumberFormat.prototype.resolvedOptions=_nat(function(){"
    @"      const r=_IN.call(this);return{...r,locale:'en-US'};},'resolvedOptions');}"
    @"  if(Intl.ListFormat){"
    @"    const _IL=Intl.ListFormat.prototype.resolvedOptions;"
    @"    Intl.ListFormat.prototype.resolvedOptions=_nat(function(){"
    @"      const r=_IL.call(this);return{...r,locale:'en-US'};},'resolvedOptions');}"
    @"  if(Intl.PluralRules){"
    @"    const _IP=Intl.PluralRules.prototype.resolvedOptions;"
    @"    Intl.PluralRules.prototype.resolvedOptions=_nat(function(){"
    @"      const r=_IP.call(this);return{...r,locale:'en-US'};},'resolvedOptions');}"
    // Segmenter, DisplayNames, RelativeTimeFormat — newer Intl APIs that also
    // expose the OS locale. Normalize each resolvedOptions() return to en-US.
    @"  if(Intl.Segmenter){"
    @"    const _ISg=Intl.Segmenter.prototype.resolvedOptions;"
    @"    Intl.Segmenter.prototype.resolvedOptions=_nat(function(){"
    @"      const r=_ISg.call(this);return{...r,locale:'en-US'};},'resolvedOptions');}"
    @"  if(Intl.DisplayNames){"
    @"    const _IDN=Intl.DisplayNames.prototype.resolvedOptions;"
    @"    Intl.DisplayNames.prototype.resolvedOptions=_nat(function(){"
    @"      const r=_IDN.call(this);return{...r,locale:'en-US'};},'resolvedOptions');}"
    @"  if(Intl.RelativeTimeFormat){"
    @"    const _IRF=Intl.RelativeTimeFormat.prototype.resolvedOptions;"
    @"    Intl.RelativeTimeFormat.prototype.resolvedOptions=_nat(function(){"
    @"      const r=_IRF.call(this);return{...r,locale:'en-US'};},'resolvedOptions');}"
    // Intl.Locale constructor — passing any tag always returns an en-US Locale so
    // navigator.language probing via new Intl.Locale(navigator.language).language
    // is neutralised.
    @"  if(Intl.Locale){"
    @"    const _ILo=Intl.Locale;"
    @"    const _ILoW=function(tag,opts){return new _ILo('en-US',opts);};"
    @"    _ILoW.prototype=_ILo.prototype;"
    @"    try{window.Intl=Object.assign(Object.create(Intl),{Locale:_ILoW});}catch(e){}}"
    // Intl.supportedValuesOf — returns the ICU-version-specific list of supported
    // timezone/calendar/currency names. JSC and V8 may differ by ICU era; return
    // fixed Chrome-matching lists for the short enumerations (calendar, collation,
    // numberingSystem, unit) and sort the native list for timeZone/currency so ICU
    // version reordering cannot be used as a fingerprint.
    @"  if(typeof Intl.supportedValuesOf==='function'){"
    @"    const _sVO=Intl.supportedValuesOf.bind(Intl);"
    @"    const _sVOCal=['buddhist','chinese','coptic','dangi','ethioaa','ethiopic',"
    @"      'gregory','hebrew','indian','islamic','islamic-civil','islamic-rgsa',"
    @"      'islamic-tbla','islamic-umalqura','iso8601','japanese','persian','roc'];"
    @"    const _sVOCol=['compat','dict','emoji','eor','phonebk','phonetic','pinyin',"
    @"      'reformed','searchjl','stroke','trad','unihan','zhuyin'];"
    @"    const _sVONS=['adlm','ahom','arab','arabext','bali','beng','bhks','brah',"
    @"      'cakm','cham','deva','diak','fullwide','gong','gonm','gujr','guru','hanidec',"
    @"      'hmng','hmnp','java','kali','khmr','knda','kthi','laoo','latn','lepc','limb',"
    @"      'mathbold','mathdbl','mathmonobold','mathrm','mathsans','mathsansbold','modi',"
    @"      'mong','mroo','mtei','mymr','mymrshan','mymrtlng','newa','nkoo','olck','orya',"
    @"      'osma','rohg','saur','segment','shrd','sind','sinh','sora','sund','takr','talu',"
    @"      'tamldec','telu','thai','tibt','tirh','vaii','wara','wcho'];"
    @"    Intl.supportedValuesOf=_nat(function(key){"
    @"      if(key==='calendar')return _sVOCal.slice();"
    @"      if(key==='collation')return _sVOCol.slice();"
    @"      if(key==='numberingSystem')return _sVONS.slice();"
    @"      try{return _sVO(key).slice().sort();}catch(e){return [];}"
    @"    },'supportedValuesOf');}"
    @"}catch(e){}"
    // ── Resource timing — clamp to prevent network topology fingerprinting ─
    // Resource timing entries expose precise transfer durations (sub-ms) that
    // reveal network path characteristics unique to the user's connection.
    // setResourceTimingBufferSize(0) prevents new entries from accumulating;
    // clear existing ones that loaded before this script ran.
    @"try{"
    @"  if(performance.setResourceTimingBufferSize)performance.setResourceTimingBufferSize(0);"
    @"  if(performance.clearResourceTimings)performance.clearResourceTimings();"
    @"  if(window.PerformanceObserver){"
    @"    const _PObs=window.PerformanceObserver;"
    @"    window.PerformanceObserver=_nat(function(cb){"
    @"      return new _PObs(function(list,obs){"
    @"        const _bl=new Set(['resource','navigation','paint']);"
    @"        const entries=list.getEntries().filter(function(e){"
    @"          return !_bl.has(e.entryType);});" // strip timing entries that fingerprint load path
    @"        if(entries.length)cb({getEntries:function(){return entries;},getEntriesByType:function(t){return entries.filter(function(e){return e.entryType===t;});},getEntriesByName:function(n){return entries.filter(function(e){return e.name===n;});}},obs);"
    @"      });},'PerformanceObserver');"
    @"    window.PerformanceObserver.prototype=_PObs.prototype;"
    @"    window.PerformanceObserver.supportedEntryTypes=_PObs.supportedEntryTypes;}"
    @"}catch(e){}"
    // ── Web Worker timing precision ───────────────────────────────────────
    // WKUserScript injects only into document (main-thread) JS contexts.
    // Workers have a separate global scope that our shield cannot reach.
    // We wrap Worker() to prepend a timing-precision patch via a blob URL
    // that importScripts() the original script after our patch runs.
    // Falls back to the original Worker() if the blob approach fails
    // (e.g. module workers, data: URLs, or restrictive CSP).
    @"(function(){"
    @"  const _W=window.Worker;"
    @"  if(!_W)return;"
    @"  const _WP='const _wp=performance.now.bind(performance);'"
    @"    +'performance.now=function(){return Math.floor(_wp());};'"
    @"    +'const _wd=Date.now;Date.now=function(){return Math.floor(_wd()/100)*100;};';"
    @"  window.Worker=function(url,opts){"
    @"    if(typeof url==='string'&&url.indexOf('blob:')<0){"
    @"      try{"
    @"        const blob=new Blob([_WP+'importScripts('+JSON.stringify(url)+');'],"
    @"          {type:'application/javascript'});"
    @"        const burl=URL.createObjectURL(blob);"
    @"        const w=new _W(burl,opts);"
    @"        setTimeout(function(){URL.revokeObjectURL(burl);},10000);"
    @"        return w;"
    @"      }catch(e){}"
    @"    }"
    @"    return new _W(url,opts);"
    @"  };"
    @"  window.Worker.prototype=_W.prototype;"
    @"})();"
    // ── eval honeypot ─────────────────────────────────────────────────────
    @"const _eval=window.eval;"
    @"window.eval=function(code){"
    @"  if(typeof code==='string'&&("
    @"    code.includes('document.cookie')||code.includes('localStorage')||"
    @"    code.includes('sessionStorage')||code.includes('XMLHttpRequest')||"
    @"    code.length>2000)){"
    @"    try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.honeypot)"
    @"      window.webkit.messageHandlers.honeypot.postMessage({trap:'eval',url:location.href,len:code.length,time:Date.now()});}"
    @"    catch(e){}"
    @"  }"
    @"  return _eval.call(this,code);};"
    // postMessage origin guard
    @"const _pM=window.postMessage.bind(window);"
    @"window.postMessage=function(data,origin,transfer){"
    @"  if(origin==='*'&&window.top!==window)"
    @"    try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.honeypot)"
    @"      window.webkit.messageHandlers.honeypot.postMessage({trap:'wildcard_postmessage',url:location.href,time:Date.now()});}"
    @"    catch(e){}"
    @"  return _pM(data,origin,transfer);};"
    // iFrame sandbox hardening
    @"document.addEventListener('DOMContentLoaded',function(){"
    @"  document.querySelectorAll('iframe').forEach(function(f){"
    @"    try{"
    @"      var fsrc=new URL(f.src||'',location.href);"
    @"      if(fsrc.origin!==location.origin&&!f.hasAttribute('sandbox')){"
    @"        f.setAttribute('sandbox','allow-scripts allow-same-origin allow-forms allow-popups');"
    @"      }"
    @"    }catch(e){}"
    @"  });"
    @"},false);"
    // ── Hardware / peripheral API deletion ───────────────────────────────────
    // Each API exposes unique hardware identifiers or device presence bitmaps.
    @"try{Object.defineProperty(navigator,'usb',{get:()=>undefined,configurable:true});}catch(e){}"
    @"try{Object.defineProperty(navigator,'bluetooth',{get:()=>undefined,configurable:true});}catch(e){}"
    @"try{Object.defineProperty(navigator,'hid',{get:()=>undefined,configurable:true});}catch(e){}"
    @"try{Object.defineProperty(navigator,'serial',{get:()=>undefined,configurable:true});}catch(e){}"
    @"try{Object.defineProperty(navigator,'xr',{get:()=>undefined,configurable:true});}catch(e){}"
    @"try{Object.defineProperty(navigator,'keyboard',{get:()=>undefined,configurable:true});}catch(e){}"
    @"try{Object.defineProperty(navigator,'credentials',{get:()=>undefined,configurable:true});}catch(e){}"
    // getGamepads: returns empty array (no controller serials exposed)
    @"try{navigator.getGamepads=_nat(function(){return [];},'getGamepads');}catch(e){}"
    // ── navigator.mediaDevices — block device enumeration ─────────────────
    // enumerateDevices() reveals camera/microphone presence + ephemeral device IDs.
    @"try{if(navigator.mediaDevices){"
    @"  Object.defineProperty(navigator.mediaDevices,'enumerateDevices',{"
    @"    value:_nat(function(){return Promise.resolve([]);},'enumerateDevices'),"
    @"    writable:true,configurable:true"
    @"  });"
    @"  if(typeof MediaDevices!=='undefined')"
    @"    try{MediaDevices.prototype.enumerateDevices=_nat(function(){return Promise.resolve([]);},'enumerateDevices');}catch(e){}"
    @"}}catch(e){}"
    // ── navigator.permissions — normalize permission state ────────────────
    // Per-user permission grants are unique. Force 'prompt' so sites can't
    // use prior-granted states as a stable identifier.
    @"try{if(navigator.permissions){"
    @"  const _pQ=navigator.permissions.query.bind(navigator.permissions);"
    @"  navigator.permissions.query=_nat(function(desc){"
    @"    if(desc&&typeof desc.name==='string'&&"
    @"       ['camera','microphone','geolocation','notifications',"
    @"        'midi','push','speaker-selection'].indexOf(desc.name)>=0){"
    @"      return Promise.resolve({state:'prompt',onchange:null,"
    @"        addEventListener:function(){},removeEventListener:function(){}});"
    @"    }"
    @"    return _pQ(desc);"
    @"  },'query');"
    @"}}catch(e){}"
    // Notification.permission — static property on the Notification constructor.
    // WKWebView defaults to 'default'; Brave/Tor return 'denied'. The permission
    // cluster (camera/mic/geo/notifications) is hashed by creepjs as a unit.
    @"try{if(window.Notification){"
    @"  Object.defineProperty(Notification,'permission',{"
    @"    get:_nat(function(){return 'denied';},'permission'),"
    @"    configurable:false});"
    @"}}catch(e){}"
    // ── StorageManager.estimate — fixed quota prevents storage fingerprinting ─
    // Real quota and usage vary by device, OS, and profile state.
    @"try{if(navigator.storage&&window.StorageManager){"
    @"  StorageManager.prototype.estimate=_nat(function(){"
    @"    return Promise.resolve({quota:120*1024*1024*1024,usage:4096*1024});"
    @"  },'estimate');"
    @"}}catch(e){}"
    // ── window.matchMedia — normalize privacy-sensitive CSS media features ─
    // Responses to prefers-color-scheme, prefers-reduced-motion, etc. are
    // system-level settings that create unique fingerprint signals.
    @"(function(){"
    @"  try{"
    @"    const _mM=window.matchMedia.bind(window);"
    // Map of pattern → forced matches value (our canonical "standard" profile).
    @"    const _mQNorms=["
    @"      [/prefers-color-scheme\s*:\s*dark/i,false],"    // we say light
    @"      [/prefers-color-scheme\s*:\s*light/i,true],"
    @"      [/prefers-reduced-motion\s*:\s*reduce/i,false],"
    @"      [/prefers-contrast\s*:\s*(more|less|forced)/i,false],"
    @"      [/forced-colors\s*:\s*active/i,false],"
    @"      [/inverted-colors\s*:\s*inverted/i,false],"
    @"      [/any-hover\s*:\s*none/i,false],"
    @"      [/any-pointer\s*:\s*coarse/i,false],"
    @"      [/pointer\s*:\s*coarse/i,false],"
    @"      [/hover\s*:\s*none/i,false],"
    @"      [/update\s*:\s*slow/i,false],"
    @"      [/prefers-reduced-transparency\s*:\s*reduce/i,false],"
    @"      [/dynamic-range\s*:\s*high/i,false],"     // HDR presence
    @"      [/video-dynamic-range\s*:\s*high/i,false],"
    @"      [/color-gamut\s*:\s*(p3|rec2020)/i,false]," // wide gamut reveals display
    @"    ];"
    @"    window.matchMedia=_nat(function(query){"
    @"      const q=String(query);"
    @"      for(const[re,matches]of _mQNorms){"
    @"        if(re.test(q)){"
    @"          const base=_mM(q);"
    @"          return Object.create(base,{matches:{get:()=>matches,enumerable:true}});"
    @"        }"
    @"      }"
    @"      return _mM(q);"
    @"    },'matchMedia');"
    @"  }catch(e){}"
    @"})();"
    // ── Element.getBoundingClientRect — sub-pixel layout fingerprinting ────
    // Fingerprinters measure text element bounds to infer font rendering at
    // sub-pixel precision. A per-session ±0.1px position offset prevents this
    // while being imperceptible to layout calculations.
    @"(function(){"
    @"  try{"
    @"    const _bbOff=(Math.random()-0.5)*0.2;" // ±0.1px, stable for session
    @"    const _gBCR=Element.prototype.getBoundingClientRect;"
    @"    Element.prototype.getBoundingClientRect=_nat(function(){"
    @"      const r=_gBCR.call(this);"
    @"      if(!r.width&&!r.height)return r;" // don't noise empty rects
    @"      try{return new DOMRect(r.x+_bbOff,r.y+_bbOff,r.width,r.height);}catch(e){return r;}"
    @"    },'getBoundingClientRect');"
    // Range text measurements are used for sub-pixel font fingerprinting. Apply
    // the same session-stable offset so fingerprinters read consistent but
    // non-identifying values regardless of whether they measure via Element or Range.
    @"    if(window.Range){"
    @"      const _rBCR=Range.prototype.getBoundingClientRect;"
    @"      Range.prototype.getBoundingClientRect=_nat(function(){"
    @"        const r=_rBCR.call(this);"
    @"        if(!r.width&&!r.height)return r;"
    @"        try{return new DOMRect(r.x+_bbOff,r.y+_bbOff,r.width,r.height);}catch(e){return r;}"
    @"      },'getBoundingClientRect');"
    @"      const _rGCR=Range.prototype.getClientRects;"
    @"      Range.prototype.getClientRects=_nat(function(){"
    @"        return Array.from(_rGCR.call(this)).map(function(r){"
    @"          try{return new DOMRect(r.x+_bbOff,r.y+_bbOff,r.width,r.height);}catch(e){return r;}"
    @"        });"
    @"      },'getClientRects');"
    @"    }"
    @"  }catch(e){}"
    @"})();"
    // ── performance direct-API filtering ─────────────────────────────────
    // PerformanceObserver is already patched above. The direct performance.*
    // methods bypass it and would still return navigation/paint/resource entries
    // that uniquely identify load timing per-user.
    @"try{"
    @"  const _gE=performance.getEntries.bind(performance);"
    @"  performance.getEntries=_nat(function(){"
    @"    const _bl=new Set(['resource','navigation','paint']);"
    @"    return _gE().filter(function(e){return !_bl.has(e.entryType);});"
    @"  },'getEntries');"
    @"  const _gEBT=performance.getEntriesByType.bind(performance);"
    @"  performance.getEntriesByType=_nat(function(type){"
    @"    if(type==='resource'||type==='navigation'||type==='paint')return [];"
    @"    return _gEBT(type);"
    @"  },'getEntriesByType');"
    @"  const _gEBN=performance.getEntriesByName.bind(performance);"
    @"  performance.getEntriesByName=_nat(function(name,type){"
    @"    const _bl=new Set(['resource','navigation','paint']);"
    @"    if(type&&_bl.has(type))return [];"
    @"    return _gEBN(name,type).filter(function(e){return !_bl.has(e.entryType);});"
    @"  },'getEntriesByName');"
    @"}catch(e){}"
    // ── navigator.mediaCapabilities — codec support fingerprinting ────────
    // decodingInfo/encodingInfo map to hardware GPU/codec ASICs and vary
    // significantly across device models. Return a stable generic response.
    @"try{if(navigator.mediaCapabilities&&window.MediaCapabilities){"
    @"  MediaCapabilities.prototype.decodingInfo=_nat(function(){"
    @"    return Promise.resolve({supported:true,smooth:true,powerEfficient:true});"
    @"  },'decodingInfo');"
    @"  MediaCapabilities.prototype.encodingInfo=_nat(function(){"
    @"    return Promise.resolve({supported:true,smooth:true,powerEfficient:true});"
    @"  },'encodingInfo');"
    @"}}catch(e){}"
    // ── RTCRtpSender/Receiver.getCapabilities — codec list fingerprinting ─
    // Static methods that return browser codec lists without needing a
    // peer connection — a common alternative to the SDP-parsing approach.
    // Filter to a stable, cross-platform baseline (VP8/VP9/H264 + Opus).
    @"try{if(window.RTCRtpSender&&RTCRtpSender.getCapabilities){"
    @"  const _rSC=RTCRtpSender.getCapabilities;"
    @"  const _rFilter=function(kind,caps){"
    @"    if(!caps)return null;"
    @"    const ok=kind==='video'?['vp8','vp9','h264']:['opus'];"
    @"    caps.codecs=caps.codecs.filter(function(x){"
    @"      return ok.some(function(a){return x.mimeType.toLowerCase().includes(a);});});"
    @"    return caps;};"
    @"  RTCRtpSender.getCapabilities=_nat(function(kind){"
    @"    return _rFilter(kind,_rSC.call(RTCRtpSender,kind));},'getCapabilities');"
    @"  if(window.RTCRtpReceiver&&RTCRtpReceiver.getCapabilities){"
    @"    const _rRC=RTCRtpReceiver.getCapabilities;"
    @"    RTCRtpReceiver.getCapabilities=_nat(function(kind){"
    @"      return _rFilter(kind,_rRC.call(RTCRtpReceiver,kind));},'getCapabilities');}}"
    @"}catch(e){}"
    // ── Math precision — JSC vs V8 divergence (creepjs ULP fingerprint) ─
    // JavaScriptCore and V8 produce different float64 results for ~14 Math
    // calls due to differences in their underlying libm implementations.
    // creepjs hashes all results to detect "fake Chrome on JSC" (WKWebView).
    // Override each diverging function with a lookup table that returns V8's
    // exact float64 bit pattern for the probed inputs.
    @"(function(){"
    @"  try{"
    @"    var _S2=Math.SQRT2,_LN2=Math.LN2,_L2E=Math.LOG2E,_L10=Math.LOG10E,_PI=Math.PI;"
    @"    function _mPatch(fn,tbl){"
    @"      var orig=Math[fn];"
    @"      Math[fn]=_nat(function(a,b){"
    @"        for(var i=0;i<tbl.length;i++){var t=tbl[i];"
    @"          if(t[0]===a){if(t.length===2)return t[1];"
    @"            if(t.length===3&&t[1]===b)return t[2];}}"
    @"        return orig.apply(Math,arguments);},fn);};"
    @"    _mPatch('acos', [[0.123,1.4474840516030247]]);"
    @"    _mPatch('acosh',[[_S2,0.881373587019543]]);"
    @"    _mPatch('atan', [[2,1.1071487177940904]]);"
    @"    _mPatch('atanh',[[0.5,0.5493061443340548]]);"
    @"    _mPatch('cbrt', [[_PI,1.4645918875615231]]);"
    @"    _mPatch('expm1',[[1,1.718281828459045]]);"
    @"    _mPatch('sinh', [[_PI,11.548739357257748],[_S2,1.935066822174357]]);"
    @"    _mPatch('tan',  [[-1e308,0.5086861259107568],[6*_LN2,1.6182817135715877],"
    @"                     [10*_L2E,-3.3537128705376014]]);"
    @"    _mPatch('tanh', [[0.123,0.12238344189440875]]);"
    @"    _mPatch('pow',  [[_PI,-100,1.9275814160560204e-50],[_L10,-100,1.6655929347585958e+36]]);"
    @"  }catch(e){}"
    @"})();"
    // ── SVG text geometry — platform text rendering fingerprinting ───────
    // getBBox() and getComputedTextLength() on SVG text elements produce
    // platform-specific float values that reveal the OS text stack (CoreText
    // on macOS, DirectWrite on Windows). creepjs and pixelscan probe these.
    // Apply the same session-stable ±0.1 offset used for Element BCR.
    @"(function(){"
    @"  try{"
    @"    const _svgOff=(Math.random()-0.5)*0.2;"
    @"    if(window.SVGGraphicsElement){"
    @"      const _gBB=SVGGraphicsElement.prototype.getBBox;"
    @"      SVGGraphicsElement.prototype.getBBox=_nat(function(opts){"
    @"        const r=_gBB.call(this,opts);"
    @"        return{x:r.x+_svgOff,y:r.y+_svgOff,width:r.width,height:r.height};"
    @"      },'getBBox');}"
    @"    if(window.SVGTextContentElement){"
    @"      const _gCTL=SVGTextContentElement.prototype.getComputedTextLength;"
    @"      SVGTextContentElement.prototype.getComputedTextLength=_nat(function(){"
    @"        const l=_gCTL.call(this);"
    @"        return Math.max(0,l+_svgOff);},'getComputedTextLength');"
    @"      const _gSSL=SVGTextContentElement.prototype.getSubStringLength;"
    @"      SVGTextContentElement.prototype.getSubStringLength=_nat(function(i,n){"
    @"        const l=_gSSL.call(this,i,n);"
    @"        return Math.max(0,l+_svgOff);},'getSubStringLength');}"
    @"  }catch(e){}"
    @"})();"
    // ── Error.stack JSC→V8 format normalisation ──────────────────────────
    // JavaScriptCore uses `fn@file:line:col` stack trace format.
    // V8 (Chrome) uses `at fn (file:line:col)`. creepjs detects the JSC format
    // to identify WebKit-based browsers. Reformat JSC-style frames to V8-style.
    // Note: \n in ObjC strings becomes actual newlines via the extractor;
    // use String.fromCharCode(10) for the newline delimiter in the JS split/join.
    @"try{"
    @"  const _errSD=Object.getOwnPropertyDescriptor(Error.prototype,'stack');"
    @"  if(_errSD&&_errSD.get){"
    @"    const _origStack=_errSD.get;"
    @"    const _NL=String.fromCharCode(10);"
    @"    Object.defineProperty(Error.prototype,'stack',{"
    @"      get:function(){"
    @"        const s=_origStack.call(this);"
    @"        if(typeof s!=='string')return s;"
    @"        return s.split(_NL).map(function(l){"
    @"          const m=l.match(/^(.*)@(.*:[0-9]+:[0-9]+)$/);"
    @"          if(!m)return l;"
    @"          const fn=m[1]||'<anonymous>';"
    @"          return'    at '+fn+' ('+m[2]+')';"
    @"        }).join(_NL);},"
    @"      configurable:true});"
    @"  }"
    @"}catch(e){}"
    // ── document.fonts enumeration — font presence oracle ────────────────
    // Iterating FontFaceSet reveals which system fonts were matched by CSS.
    // We already return false from check(); also block iteration so list-based
    // probing (forEach, for..of, entries, size) gets an empty view.
    @"try{if(window.FontFaceSet){"
    @"  FontFaceSet.prototype.forEach=function(){};"
    @"  FontFaceSet.prototype[Symbol.iterator]=function*(){};"
    @"  FontFaceSet.prototype.values=function*(){};"
    @"  FontFaceSet.prototype.entries=function*(){};"
    @"  FontFaceSet.prototype.keys=function*(){};"
    @"  try{Object.defineProperty(FontFaceSet.prototype,'size',{"
    @"    get:function(){return 0;},configurable:true});}catch(e){}"
    @"}}catch(e){}"
    // ── Retroactive native registration ───────────────────────────────────
    // Prototype methods assigned above are on the real prototype objects now;
    // register each with _nat so fn.toString() returns "[native code]".
    @"(function(){"
    // RTCPeerConnection is absent in headless/iframe contexts; evaluating
    // RTCPeerConnection.prototype in the array literal would throw and leave
    // _reg undefined, aborting the entire forEach. It is already guarded below.
    @"  var _reg=["
    @"    [HTMLCanvasElement.prototype,'toDataURL'],"
    @"    [HTMLCanvasElement.prototype,'toBlob'],"
    @"    [CanvasRenderingContext2D.prototype,'getImageData'],"
    @"    [CanvasRenderingContext2D.prototype,'measureText'],"
    @"    [WebGLRenderingContext.prototype,'getParameter'],"
    @"    [WebGLRenderingContext.prototype,'getSupportedExtensions'],"
    @"    [Intl.DateTimeFormat.prototype,'resolvedOptions'],"
    @"    [Intl.Collator.prototype,'resolvedOptions'],"
    @"    [Date.prototype,'getTimezoneOffset'],"
    @"    [EventTarget.prototype,'addEventListener'],"
    @"    [Element.prototype,'getBoundingClientRect'],"
    @"  ];"
    @"  _reg.forEach(function(pair){"
    @"    try{var fn=pair[0][pair[1]];if(fn&&typeof fn==='function')_nat(fn,pair[1]);}catch(e){}});"
    @"  try{_nat(window.matchMedia,'matchMedia');}catch(e){}"
    @"  try{if(navigator.mediaDevices&&navigator.mediaDevices.enumerateDevices)_nat(navigator.mediaDevices.enumerateDevices,'enumerateDevices');}catch(e){}"
    @"  try{if(navigator.permissions&&navigator.permissions.query)_nat(navigator.permissions.query,'query');}catch(e){}"
    @"  try{if(navigator.storage&&window.StorageManager)_nat(StorageManager.prototype.estimate,'estimate');}catch(e){}"
    @"  try{_nat(window.requestAnimationFrame,'requestAnimationFrame');}catch(e){}"
    @"  try{_nat(window.eval,'eval');}catch(e){}"
    @"  try{_nat(window.postMessage,'postMessage');}catch(e){}"
    @"  try{if(window.Worker)_nat(window.Worker,'Worker');}catch(e){}"
    @"  try{if(window.PerformanceObserver)_nat(window.PerformanceObserver,'PerformanceObserver');}catch(e){}"
    @"  try{if(window.RTCPeerConnection)_nat(window.RTCPeerConnection,'RTCPeerConnection');}catch(e){}"
    @"  try{_nat(performance.getEntries,'getEntries');}catch(e){}"
    @"  try{_nat(performance.getEntriesByType,'getEntriesByType');}catch(e){}"
    @"  try{_nat(performance.getEntriesByName,'getEntriesByName');}catch(e){}"
    @"  try{if(navigator.mediaCapabilities&&window.MediaCapabilities){"
    @"    _nat(MediaCapabilities.prototype.decodingInfo,'decodingInfo');"
    @"    _nat(MediaCapabilities.prototype.encodingInfo,'encodingInfo');}}catch(e){}"
    @"  try{if(window.RTCRtpSender&&RTCRtpSender.getCapabilities)_nat(RTCRtpSender.getCapabilities,'getCapabilities');}catch(e){}"
    @"  try{if(window.RTCRtpReceiver&&RTCRtpReceiver.getCapabilities)_nat(RTCRtpReceiver.getCapabilities,'getCapabilities');}catch(e){}"
    @"  try{if(window.Range){"
    @"    _nat(Range.prototype.getBoundingClientRect,'getBoundingClientRect');"
    @"    _nat(Range.prototype.getClientRects,'getClientRects');}}catch(e){}"
    @"  try{if(window.AudioBuffer){"
    @"    _nat(AudioBuffer.prototype.getChannelData,'getChannelData');"
    @"    _nat(AudioBuffer.prototype.copyFromChannel,'copyFromChannel');}}catch(e){}"
    @"  try{if(window.SVGGraphicsElement)"
    @"    _nat(SVGGraphicsElement.prototype.getBBox,'getBBox');}catch(e){}"
    @"  try{if(window.SVGTextContentElement){"
    @"    _nat(SVGTextContentElement.prototype.getComputedTextLength,'getComputedTextLength');"
    @"    _nat(SVGTextContentElement.prototype.getSubStringLength,'getSubStringLength');}}catch(e){}"
    @"  try{if(window.FontFaceSet){"
    @"    _nat(FontFaceSet.prototype.load,'load');"
    @"    _nat(FontFaceSet.prototype.check,'check');"
    @"    _nat(FontFaceSet.prototype.forEach,'forEach');}}catch(e){}"
    @"  try{if(window.Intl&&typeof Intl.supportedValuesOf==='function')"
    @"    _nat(Intl.supportedValuesOf,'supportedValuesOf');}catch(e){}"
    @"  if(window.WebGL2RenderingContext){"
    @"    try{_nat(WebGL2RenderingContext.prototype.getParameter,'getParameter');}catch(e){}"
    @"    try{_nat(WebGL2RenderingContext.prototype.getSupportedExtensions,'getSupportedExtensions');}catch(e){}}"
    @"  try{_nat(WebGLRenderingContext.prototype.getShaderPrecisionFormat,'getShaderPrecisionFormat');}catch(e){}"
    @"  try{if(window.WebGL2RenderingContext)"
    @"    _nat(WebGL2RenderingContext.prototype.getShaderPrecisionFormat,'getShaderPrecisionFormat');}catch(e){}"
    @"  try{if(window.AudioContext)_nat(window.AudioContext,'AudioContext');}catch(e){}"
    @"})();"
    @"})();";
  WKUserScript *shieldScript=[[WKUserScript alloc]
    initWithSource:shield
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:NO];
  [config.userContentController addUserScript:shieldScript];
  // ── Honeypot canary — alerts when scrapers/exploits probe well-known targets ─
  NSString *canary=
    @"(function(){'use strict';"
    @"function trap(name,fake){"
    @"  Object.defineProperty(window,name,{get:function(){"
    @"    try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.honeypot)"
    @"      window.webkit.messageHandlers.honeypot.postMessage({trap:name,url:location.href,time:Date.now()});}"
    @"    catch(e){}"
    @"    return fake;},"
    @"  configurable:false,enumerable:false});}"
    // Fake credential properties — only automated tools probe these
    @"trap('__bb_admin_token','eyJhbGciOiJIUzI1NiJ9.HONEYPOT.TRAP');"
    @"trap('__bb_session_key','sk-bear-0000000000000000-TRAP');"
    @"trap('__bb_api_base','https://api.bearbrowser.internal/v1');"
    @"trap('__bb_config',{debug:false,admin:false,env:'production'});"
    // Watch for document.cookie bulk harvest attempts
    @"const _cookieDesc=Object.getOwnPropertyDescriptor(Document.prototype,'cookie')||"
    @"                  Object.getOwnPropertyDescriptor(HTMLDocument.prototype,'cookie');"
    @"if(_cookieDesc&&_cookieDesc.get){"
    @"  let _hc=0;"
    @"  const _origGet=_cookieDesc.get;"
    @"  Object.defineProperty(document,'cookie',{get:function(){"
    @"    _hc++;if(_hc>20&&_hc%10===0)"
    @"      try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.honeypot)"
    @"        window.webkit.messageHandlers.honeypot.postMessage({trap:'cookie_harvest',url:location.href,count:_hc,time:Date.now()});}"
    @"      catch(e){}"
    @"    return _origGet.call(document);},"
    @"  set:_cookieDesc.set,configurable:true});"
    @"}"
    @"})();";
  WKUserScript *canaryScript=[[WKUserScript alloc]
    initWithSource:canary
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:YES];
  [config.userContentController addUserScript:canaryScript];
  // Network monitor — wraps fetch/XHR and uses PerformanceObserver to report all resource loads
  NSString *netmonJS=
    @"(function(){'use strict';"
    @"function _rep(url,type){"
    @"  try{"
    @"    var h=new URL(url,location.href).hostname||'';"
    @"    window.webkit.messageHandlers.netmon.postMessage({domain:h,page:location.href,type:type});"
    @"  }catch(e){}"
    @"}"
    @"var _f=window.fetch;"
    @"window.fetch=function(input,init){"
    @"  _rep(typeof input==='string'?input:(input&&input.url)||'','fetch');"
    @"  return _f.apply(this,arguments);"
    @"};"
    @"var _xo=XMLHttpRequest.prototype.open;"
    @"XMLHttpRequest.prototype.open=function(m,url){"
    @"  _rep(String(url),'xhr');"
    @"  return _xo.apply(this,arguments);"
    @"};"
    @"if(typeof PerformanceObserver!=='undefined'){"
    @"  try{"
    @"    var po=new PerformanceObserver(function(list){"
    @"      list.getEntries().forEach(function(e){"
    @"        if(e.name&&e.initiatorType)_rep(e.name,e.initiatorType);"
    @"      });"
    @"    });"
    @"    po.observe({entryTypes:['resource']});"
    @"  }catch(ex){}"
    @"}"
    @"})();";
  WKUserScript *netmonScript=[[WKUserScript alloc]
    initWithSource:netmonJS
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:NO];
  [config.userContentController addUserScript:netmonScript];

  // ── Security monitor — JS-side injection detection ────────────────────────
  NSString *secmonJS=
    @"(function(){'use strict';"
    @"function _sm(type,detail){"
    @"  try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.secmon)"
    @"    window.webkit.messageHandlers.secmon.postMessage({type:type,page:location.href,detail:String(detail).slice(0,1000)});}"
    @"  catch(e){}}"
    // eval monitoring — already hooked in shield for honeypot; extend for secmon
    @"const _ev=window.eval;"
    @"window.eval=function(code){"
    @"  _sm('eval',typeof code==='string'?code.slice(0,800):typeof code);"
    @"  return _ev.call(this,code);};"
    // Function constructor
    @"const _Fn=window.Function;"
    @"window.Function=function(){var a=Array.from(arguments);"
    @"  _sm('Function',a.join('|').slice(0,800));"
    @"  return _Fn.apply(this,a);};"
    @"window.Function.prototype=_Fn.prototype;"
    // MutationObserver — detect dynamic <script> injection
    @"new MutationObserver(function(muts){"
    @"  muts.forEach(function(m){m.addedNodes.forEach(function(n){"
    @"    if(n.tagName==='SCRIPT'){"
    @"      var src=n.src||''; var inline=src?'':(n.textContent||'').slice(0,600);"
    @"      _sm('script_inject',src||inline||'(empty)');}"
    @"  });});"
    @"}).observe(document.documentElement,{childList:true,subtree:true});"
    // sendBeacon
    @"var _sb=navigator.sendBeacon.bind(navigator);"
    @"navigator.sendBeacon=function(url,data){"
    @"  _sm('beacon',String(url));"
    @"  return _sb(url,data);};"
    // form submit — capture action + field types
    @"document.addEventListener('submit',function(e){"
    @"  var f=e.target,fields=[];"
    @"  Array.from(f.elements).forEach(function(el){"
    @"    if(el.name||el.type)fields.push((el.type||'?')+':'+(el.name||el.id||'?'));});"
    @"  _sm('form_submit',f.action+'|'+fields.join(','));},true);"
    // Credential API
    @"if(navigator.credentials){"
    @"  var _cg=navigator.credentials.get.bind(navigator.credentials);"
    @"  navigator.credentials.get=function(o){"
    @"    _sm('credentials_get',JSON.stringify(o||{}).slice(0,300));"
    @"    return _cg(o);};"
    @"  var _cc=navigator.credentials.create.bind(navigator.credentials);"
    @"  navigator.credentials.create=function(o){"
    @"    _sm('credentials_create',JSON.stringify(o||{}).slice(0,300));"
    @"    return _cc(o);};"
    @"}"
    // localStorage writes with auth-like keys
    @"var _lss=localStorage.setItem.bind(localStorage);"
    @"localStorage.setItem=function(k,v){"
    @"  if(/token|auth|session|credential|password|secret|api_key/i.test(k))"
    @"    _sm('localstorage_auth',k+'=<'+String(v).length+'chars>');"
    @"  return _lss(k,v);};"
    // addEventListener for keyboard sniffing
    @"var _ael=EventTarget.prototype.addEventListener;"
    @"EventTarget.prototype.addEventListener=function(type,fn,opts){"
    @"  if(type==='keydown'||type==='keypress'||type==='keyup')"
    @"    _sm('keylistener','type='+type+' on '+(this===document?'document':this===window?'window':((this.tagName||'?'))));"
    @"  return _ael.call(this,type,fn,opts);};"
    @"})();";
  WKUserScript *secmonScript=[[WKUserScript alloc]
    initWithSource:secmonJS
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:NO];
  [config.userContentController addUserScript:secmonScript];

  // Inject bundled font-face declarations so pages get fonts without hitting CDN
  NSString *fontCSS=[self bundledFontFaceCSS];
  if (fontCSS.length) {
    WKUserScript *fontScript=[[WKUserScript alloc]
      initWithSource:[NSString stringWithFormat:@"(function(){var s=document.createElement('style');s.textContent=%@;document.head.appendChild(s);})()",
        [self jsStringLiteral:fontCSS]]
      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:NO];
    [config.userContentController addUserScript:fontScript];
  }
  return config;
}

- (NSString *)bundledFontFaceCSS {
  NSString *cssPath=[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"fonts/bearbrowser-fonts.css"];
  return [NSString stringWithContentsOfFile:cssPath encoding:NSUTF8StringEncoding error:nil]?:@"";
}

- (NSString *)jsStringLiteral:(NSString *)s {
  NSString *escaped=[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  escaped=[escaped stringByReplacingOccurrencesOfString:@"`" withString:@"\\`"];
  return [NSString stringWithFormat:@"`%@`",escaped];
}

- (WKWebView *)makeWebViewPrivate:(BOOL)priv {
  WKWebViewConfiguration *config=[self baseConfig:priv];
  CGFloat W=self.root.bounds.size.width;
  CGFloat chromH=kToolbarH+kTabBarH+2;
  CGFloat findOff=self.findBarVisible?kFindBarH:0;
  WKWebView *wv=[[WKWebView alloc]initWithFrame:NSMakeRect(0,findOff,W,self.root.bounds.size.height-chromH-findOff)
                                  configuration:config];
  wv.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  // Present as Safari so sites like Google don't reject WKWebView's bare UA
  wv.customUserAgent=@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";
  // Force Aqua/light appearance so CSS system color keywords (Canvas, ButtonText,
  // etc.) always resolve to light-mode RGB values — consistent with the JS shield's
  // matchMedia('prefers-color-scheme: light') override. Without this, a dark-mode
  // OS would produce different computed RGB values, leaking the OS theme.
  wv.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
  wv.navigationDelegate=self; wv.UIDelegate=self;
  wv.allowsBackForwardNavigationGestures=YES; wv.allowsLinkPreview=YES;
  wv.allowsMagnification=YES; // trackpad pinch-to-zoom (Chrome parity)
  // Required for Web Inspector / "Inspect Element" to open on macOS 13.3+ (defaults NO).
  if (@available(macOS 13.3, *)) wv.inspectable=YES;
  // PiP enabled on macOS via configuration (allowsPictureInPictureMediaPlayback is iOS-only)
  [wv addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:(__bridge void *)wv];
  [wv addObserver:self forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:(__bridge void *)wv];
  return wv;
}

- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)ctx {
  WKWebView *wv=(__bridge WKWebView *)ctx;
  if (wv!=self.webView) return;
  if ([path isEqualToString:@"estimatedProgress"]) {
    double p=wv.estimatedProgress;
    self.progressBar.doubleValue=p;
    self.progressBar.hidden=(p>=0.99||p<=0.0);
  } else if ([path isEqualToString:@"title"]) {
    BBTab *tab=[self tabForWebView:wv];
    if (tab&&wv.title.length) {
      tab.title=wv.title; [self reloadTabBar];
      if (tab==self.activeTab) self.window.title=[self windowTitleForTab:tab];
      // Patch the history entry recorded at didFinishNavigation (its title was
      // usually empty/placeholder because the title hadn't loaded yet).
      if (!tab.isPrivate) [[BBHistoryStore shared] updateTitle:wv.title forURL:wv.URL.absoluteString];
    }
  }
}

// ── Tab management ────────────────────────────────────────────────────────────
- (void)addTabPrivate:(BOOL)priv {
  BBTab *tab=[[BBTab alloc]init]; tab.isPrivate=priv;
  tab.webView=[self makeWebViewPrivate:priv];
  [self.tabs addObject:tab];
  self.activeTabIndex=self.tabs.count-1;
  [self activateTab:self.activeTabIndex];
  [self loadStartPage:tab.webView];
  [self reloadTabBar];
}

// ── Tab suspension ────────────────────────────────────────────────────────────
// Suspend a background tab: save its URL, load a minimal placeholder so the
// WKWebView process yields its memory, and mark it suspended. The tab bar still
// shows its title + favicon — only the web process is freed.
static NSString *BBSuspendedHTML(NSString *title, NSString *url) {
  return [NSString stringWithFormat:
    @"<!doctype html><html><head><meta charset='utf-8'>"
    @"<style>body{margin:0;display:flex;align-items:center;justify-content:center;"
    @"min-height:100vh;font-family:-apple-system,sans-serif;background:#f0f2f4;"
    @"color:#6e6e73;font-size:13px;}"
    @".wrap{text-align:center;opacity:.7}"
    @".icon{font-size:28px;margin-bottom:8px}"
    @"p{margin:0}</style></head>"
    @"<body><div class='wrap'><div class='icon'>💤</div><p>%@ — suspended</p>"
    @"<p style='font-size:11px;margin-top:4px;opacity:.6'>%@</p></div></body></html>",
    title.length?title:@"Tab", url?:@""];
}
- (void)suspendTab:(BBTab *)tab {
  if (tab.suspended || tab==self.activeTab) return;
  NSString *url=tab.webView.URL.absoluteString;
  if (!url.length || [self isInternalURL:url]) return; // don't suspend NTP
  tab.suspendedURL=url;
  tab.suspended=YES;
  [tab.webView loadHTMLString:BBSuspendedHTML(tab.title,url) baseURL:nil];
  BBLog([NSString stringWithFormat:@"[tab-suspend] %@",url]);
}
- (void)wakeTab:(BBTab *)tab {
  if (!tab.suspended || !tab.suspendedURL.length) return;
  tab.suspended=NO;
  NSURL *u=[NSURL URLWithString:tab.suspendedURL];
  if (u) [tab.webView loadRequest:[NSURLRequest requestWithURL:u]];
  tab.suspendedURL=nil;
}
// Sweep: suspend background tabs idle > threshold (default 5 min, user-configurable)
- (void)suspendInactiveTabs:(id)sender {
  NSInteger threshSec=[[NSUserDefaults standardUserDefaults] integerForKey:@"BBSuspendAfterSec"];
  if (threshSec<=0) threshSec=300; // 5 minutes default
  NSDate *now=[NSDate date];
  for (NSInteger i=0;i<(NSInteger)self.tabs.count;i++) {
    if (i==self.activeTabIndex) continue;
    BBTab *t=self.tabs[i];
    if (t.suspended) continue;
    NSTimeInterval idle=t.lastActiveAt?[now timeIntervalSinceDate:t.lastActiveAt]:9999;
    if (idle>=threshSec) [self suspendTab:t];
  }
}
- (void)autosaveSession:(NSTimer *)t {
  NSMutableArray *tabDicts=[NSMutableArray array];
  for (BBTab *tab in self.tabs) {
    if (tab.isPrivate) continue;
    NSString *u=tab.suspended?tab.suspendedURL:tab.webView.URL.absoluteString;
    if (!u.length || [self isInternalURL:u]) continue;
    NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:
      @{@"url":u,@"pinned":@(tab.pinned),@"muted":@(tab.muted),@"title":tab.title?:@"",
        @"group":tab.groupName?:@"",@"groupColor":@(tab.groupColorIdx)}];
    if (tab.favicon) {
      NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:[tab.favicon TIFFRepresentation]];
      NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      if (png) d[@"favicon"]=[png base64EncodedStringWithOptions:0];
    }
    [tabDicts addObject:d];
  }
  [[NSUserDefaults standardUserDefaults] setObject:tabDicts forKey:@"BBSessionURLs"];
}
- (void)startSuspendTimer {
  [self.suspendTimer invalidate];
  // Sweep every 60 seconds; actual suspend threshold is per-tab idle time
  self.suspendTimer=[NSTimer scheduledTimerWithTimeInterval:60 target:self
    selector:@selector(suspendInactiveTabs:) userInfo:nil repeats:YES];
  self.suspendTimer.tolerance=30; // coalesce with other timers
  // Crash-safe session autosave every 30 seconds.
  [self.sessionAutosaveTimer invalidate];
  self.sessionAutosaveTimer=[NSTimer scheduledTimerWithTimeInterval:30 target:self
    selector:@selector(autosaveSession:) userInfo:nil repeats:YES];
  self.sessionAutosaveTimer.tolerance=15;

  // On memory pressure warnings, aggressively suspend idle tabs immediately
  dispatch_source_t mp=dispatch_source_create(
    DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
    DISPATCH_MEMORYPRESSURE_WARN|DISPATCH_MEMORYPRESSURE_CRITICAL,
    dispatch_get_main_queue());
  __weak typeof(self) wself=self;
  dispatch_source_set_event_handler(mp,^{ [wself suspendInactiveTabs:nil]; });
  dispatch_resume(mp);
}
// ─────────────────────────────────────────────────────────────────────────────
- (void)activateTab:(NSInteger)index {
  if (index<0||index>=(NSInteger)self.tabs.count) return;
  // Stamp the tab we're leaving so the suspension sweep knows when it went idle
  if (self.activeTabIndex>=0 && self.activeTabIndex<(NSInteger)self.tabs.count)
    self.tabs[self.activeTabIndex].lastActiveAt=[NSDate date];
  for (BBTab *t in self.tabs) { [t.webView removeFromSuperview]; t.webView.hidden=YES; }
  self.activeTabIndex=index;
  BBTab *tab=self.tabs[index];
  // Wake a suspended tab the moment the user clicks it
  if (tab.suspended) [self wakeTab:tab];
  tab.lastActiveAt=[NSDate date];
  tab.webView.hidden=NO;
  [self resizeWebViewForCurrentTab];
  [self.root addSubview:tab.webView positioned:NSWindowBelow relativeTo:self.tabBarView];
  NSString *url=tab.suspended?tab.suspendedURL:(tab.webView.URL.absoluteString?:@"");
  self.address.stringValue=[self isInternalURL:url]?@"":url?:@"";
  self.backButton.enabled=tab.webView.canGoBack;
  self.forwardButton.enabled=tab.webView.canGoForward;
  self.window.title=[self windowTitleForTab:tab];
  [self updateSecurityIndicator:tab.webView.URL];
  [self updateStarButton];
  [self applyZoomForCurrentTab];
  self.statusBar.hidden=YES;
}

- (void)reloadTabBar { [self.tabBarView reloadWithTabs:self.tabs activeIndex:self.activeTabIndex]; }

- (void)resizeWebViewForCurrentTab {
  CGFloat bmH=self.bookmarksBarVisible?kBMBarH:0;
  CGFloat chromH=kToolbarH+kTabBarH+2+bmH;
  CGFloat findOff=self.findBarVisible?kFindBarH:0;
  CGFloat W=self.root.bounds.size.width;
  CGFloat dlW=(!self.downloadPanel.hidden)?kDLPanelW:0;
  self.activeTab.webView.frame=NSMakeRect(0,findOff,W-dlW,self.root.bounds.size.height-chromH-findOff);
}

- (void)tabItemDidSelect:(NSInteger)i { if(i!=self.activeTabIndex){[self activateTab:i];[self reloadTabBar];} }

// Tears a tab out of the model without touching the active selection. Callers fix
// up activeTabIndex + reactivate afterward (lets us close several at once cheaply).
- (void)teardownTabAtIndex:(NSInteger)i {
  if (i<0||i>=(NSInteger)self.tabs.count) return;
  BBTab *t=self.tabs[i];
  NSString *u=t.suspended?t.suspendedURL:t.webView.URL.absoluteString;
  if (u.length && ![self isInternalURL:u] && !t.isPrivate) [self pushRecentlyClosed:u title:t.title];
  [t.webView removeObserver:self forKeyPath:@"estimatedProgress"];
  [t.webView removeObserver:self forKeyPath:@"title"];
  [t.webView removeFromSuperview];
  [self.tabs removeObjectAtIndex:i];
}
- (void)tabItemDidClose:(NSInteger)i  {
  if ([self validTabIndex:i] && self.tabs[i].pinned) return; // pinned tabs resist Cmd+W / close button
  [self teardownTabAtIndex:i];
  if (!self.tabs.count) { [self.window performClose:nil]; return; }
  NSInteger newActive=MIN(self.activeTabIndex,(NSInteger)self.tabs.count-1);
  self.activeTabIndex=newActive;
  [self activateTab:newActive]; [self reloadTabBar];
}
- (void)tabItemDidMiddleClick:(NSInteger)i { [self tabItemDidClose:i]; }
- (void)ctxTogglePinTab:(id)s {
  NSInteger i=[(NSMenuItem*)s tag]; if(![self validTabIndex:i]) return;
  self.tabs[i].pinned=!self.tabs[i].pinned; [self reloadTabBar];
}
- (void)ctxToggleMuteTab:(id)s {
  NSInteger i=[(NSMenuItem*)s tag]; if(![self validTabIndex:i]) return;
  BBTab *tab=self.tabs[i]; tab.muted=!tab.muted;
  [tab.webView evaluateJavaScript:[NSString stringWithFormat:
    @"document.querySelectorAll('audio,video').forEach(function(m){m.muted=%@;})",tab.muted?@"true":@"false"]
    completionHandler:nil];
  [self reloadTabBar];
}
- (void)ctxToggleSuspendTab:(id)s {
  NSInteger i=[(NSMenuItem*)s tag]; if(![self validTabIndex:i]) return;
  BBTab *tab=self.tabs[i];
  if (tab.suspended) [self wakeTab:tab]; else [self suspendTab:tab];
  [self reloadTabBar];
}
- (void)pinCurrentTab:(id)s {
  BBTab *tab=self.activeTab; if (!tab) return;
  tab.pinned=!tab.pinned; [self reloadTabBar];
}
// ── Tab groups ───────────────────────────────────────────────────────────────
- (NSInteger)nextGroupColorIdx {
  // Match an existing group's color when possible; otherwise pick the lowest unused slot.
  NSMutableSet<NSNumber *> *used=[NSMutableSet set];
  for (BBTab *t in self.tabs) if (t.groupName.length) [used addObject:@(t.groupColorIdx)];
  for (NSInteger k=0;k<8;k++) if (![used containsObject:@(k)]) return k;
  return 0;
}
- (void)ctxAddTabToGroup:(NSMenuItem *)mi {
  NSInteger i=mi.tag; if (![self validTabIndex:i]) return;
  NSString *g=mi.representedObject; if (!g.length) return;
  NSInteger colorIdx=0; BOOL found=NO;
  for (BBTab *t in self.tabs) if ([t.groupName isEqualToString:g]) { colorIdx=t.groupColorIdx; found=YES; break; }
  if (!found) colorIdx=[self nextGroupColorIdx];
  self.tabs[i].groupName=g; self.tabs[i].groupColorIdx=colorIdx;
  [self reloadTabBar];
}
- (void)ctxAddTabToNewGroup:(NSMenuItem *)mi {
  NSInteger i=mi.tag; if (![self validTabIndex:i]) return;
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"New Tab Group";
  NSTextField *tf=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,280,24)];
  tf.placeholderString=@"Group name"; a.accessoryView=tf;
  [a addButtonWithTitle:@"Create"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if (rc!=NSAlertFirstButtonReturn) return;
    NSString *g=[tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!g.length) return;
    self.tabs[i].groupName=g; self.tabs[i].groupColorIdx=[self nextGroupColorIdx];
    [self reloadTabBar];
  }];
}
- (void)ctxRemoveTabFromGroup:(NSMenuItem *)mi {
  NSInteger i=mi.tag; if (![self validTabIndex:i]) return;
  self.tabs[i].groupName=nil; self.tabs[i].groupColorIdx=0; [self reloadTabBar];
}
- (void)ctxCloseGroup:(NSMenuItem *)mi {
  NSInteger i=mi.tag; if (![self validTabIndex:i]) return;
  NSString *g=self.tabs[i].groupName; if (!g.length) return;
  // Walk backwards so removals don't shift the indices in front of us.
  for (NSInteger k=(NSInteger)self.tabs.count-1;k>=0;k--) {
    if ([self.tabs[k].groupName isEqualToString:g] && !self.tabs[k].pinned) [self teardownTabAtIndex:k];
  }
  if (!self.tabs.count) { [self.window performClose:nil]; return; }
  NSInteger newActive=MIN(self.activeTabIndex,(NSInteger)self.tabs.count-1);
  self.activeTabIndex=newActive; [self activateTab:newActive]; [self reloadTabBar];
}

// Drag-to-reorder: move the tab and keep the same tab active.
- (void)tabItemMovedFrom:(NSInteger)from to:(NSInteger)to {
  NSInteger n=self.tabs.count;
  if (from<0||from>=n||to<0||to>=n||from==to) { [self reloadTabBar]; return; }
  BBTab *t=self.tabs[from];
  [self.tabs removeObjectAtIndex:from];
  [self.tabs insertObject:t atIndex:to];
  NSInteger act=self.activeTabIndex;
  if (act==from) act=to;
  else if (from<act && to>=act) act--;
  else if (from>act && to<=act) act++;
  self.activeTabIndex=act;
  [self reloadTabBar];
}
// ── Tab hover thumbnails ──────────────────────────────────────────────────────
- (void)tabItemDidHoverEnter:(NSInteger)i fromView:(NSView *)v {
  [self.tabHoverTimer invalidate];
  if (i<0||i>=(NSInteger)self.tabs.count||!v) return;
  if (i==self.activeTabIndex) return; // active tab already on screen
  NSValue *vp=[NSValue valueWithPointer:(__bridge void *)v];
  self.tabHoverTimer=[NSTimer scheduledTimerWithTimeInterval:0.45
    target:self selector:@selector(showHoverThumbnail:) userInfo:@{@"idx":@(i),@"view":vp} repeats:NO];
}
- (void)tabItemDidHoverExit:(NSInteger)i {
  [self.tabHoverTimer invalidate]; self.tabHoverTimer=nil;
  [self.tabHoverPanel orderOut:nil];
}
- (void)showHoverThumbnail:(NSTimer *)t {
  NSDictionary *info=t.userInfo;
  NSInteger i=[info[@"idx"] integerValue];
  NSView *v=(__bridge NSView *)[info[@"view"] pointerValue];
  if (i<0||i>=(NSInteger)self.tabs.count||!v||!v.window) return;
  BBTab *tab=self.tabs[i];
  WKSnapshotConfiguration *cfg=[[WKSnapshotConfiguration alloc]init];
  cfg.rect=CGRectMake(0,0,MIN(tab.webView.bounds.size.width,1200),MIN(tab.webView.bounds.size.height,800));
  cfg.snapshotWidth=@(280);
  [tab.webView takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *img,NSError *e){
    if (!img||!v.window) return;
    dispatch_async(dispatch_get_main_queue(),^{ [self displayHoverImage:img belowView:v title:tab.title]; });
  }];
}
- (void)displayHoverImage:(NSImage *)img belowView:(NSView *)v title:(NSString *)title {
  NSRect winRect=[v convertRect:v.bounds toView:nil];
  NSRect scrRect=[v.window convertRectToScreen:winRect];
  CGFloat thumbW=280, thumbH=MIN(180,thumbW*img.size.height/MAX(img.size.width,1));
  CGFloat panelW=thumbW+16, panelH=thumbH+32;
  NSRect panelFrame=NSMakeRect(scrRect.origin.x+(scrRect.size.width-panelW)/2,
                               scrRect.origin.y-panelH-6, panelW, panelH);
  if (!self.tabHoverPanel) {
    self.tabHoverPanel=[[NSPanel alloc]initWithContentRect:panelFrame
      styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.tabHoverPanel.opaque=NO; self.tabHoverPanel.backgroundColor=[NSColor clearColor];
    self.tabHoverPanel.hasShadow=YES; self.tabHoverPanel.level=NSPopUpMenuWindowLevel;
    self.tabHoverPanel.ignoresMouseEvents=YES;
  }
  [self.tabHoverPanel setFrame:panelFrame display:NO];
  NSVisualEffectView *bg=[[NSVisualEffectView alloc]initWithFrame:NSMakeRect(0,0,panelW,panelH)];
  bg.material=NSVisualEffectMaterialHUDWindow; bg.blendingMode=NSVisualEffectBlendingModeBehindWindow;
  bg.wantsLayer=YES; bg.layer.cornerRadius=10;
  NSImageView *iv=[[NSImageView alloc]initWithFrame:NSMakeRect(8,24,thumbW,thumbH)];
  iv.image=img; iv.imageScaling=NSImageScaleProportionallyUpOrDown;
  iv.wantsLayer=YES; iv.layer.cornerRadius=6; iv.layer.masksToBounds=YES;
  [bg addSubview:iv];
  NSTextField *t=[NSTextField labelWithString:title.length?title:@"Untitled"];
  t.frame=NSMakeRect(10,4,panelW-20,18); t.font=[NSFont systemFontOfSize:11];
  t.lineBreakMode=NSLineBreakByTruncatingTail; [bg addSubview:t];
  self.tabHoverPanel.contentView=bg;
  [self.tabHoverPanel orderFront:nil];
}
- (void)tabBarDidDropURL:(NSString *)dropped {
  // Resolve raw URL or fall back to search-engine query (matches address bar Enter behaviour).
  if (!dropped.length) return;
  NSURL *u=[NSURL URLWithString:dropped];
  if (!u.scheme.length) {
    NSURL *https=[NSURL URLWithString:[@"https://" stringByAppendingString:dropped]];
    if (https.host.length) u=https;
  }
  if (!u) return;
  [self addTabPrivate:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}

// Right-click tab menu (Chrome's set + BearBrowser extensions).
- (NSMenu *)tabItemContextMenu:(NSInteger)i {
  if (![self validTabIndex:i]) return nil;
  BBTab *tab=self.tabs[i];
  NSMenu *m=[[NSMenu alloc]initWithTitle:@""];
  void(^add)(NSString*,SEL,BOOL)=^(NSString*title,SEL sel,BOOL enabled){
    NSMenuItem *it=[m addItemWithTitle:title action:sel keyEquivalent:@""];
    it.target=self; it.tag=i; it.enabled=enabled;
  };
  add(tab.pinned?@"Unpin Tab":@"Pin Tab", @selector(ctxTogglePinTab:), YES);
  add(tab.muted?@"Unmute Tab":@"Mute Tab", @selector(ctxToggleMuteTab:), YES);
  add(tab.suspended?@"Reload (Wake) Tab":@"Suspend Tab", @selector(ctxToggleSuspendTab:), YES);
  [m addItem:[NSMenuItem separatorItem]];
  // Tab group submenu — list existing groups + "Add to New Group…" + (if grouped) Remove
  NSMenuItem *grpRoot=[m addItemWithTitle:tab.groupName.length?[NSString stringWithFormat:@"Group: %@",tab.groupName]:@"Group"
                                   action:nil keyEquivalent:@""];
  NSMenu *grpM=[[NSMenu alloc]initWithTitle:@""];
  NSMutableOrderedSet *existing=[NSMutableOrderedSet orderedSet];
  for (BBTab *t in self.tabs) if (t.groupName.length) [existing addObject:t.groupName];
  for (NSString *g in existing) {
    NSMenuItem *gi=[grpM addItemWithTitle:g action:@selector(ctxAddTabToGroup:) keyEquivalent:@""];
    gi.target=self; gi.tag=i; gi.representedObject=g;
    if ([tab.groupName isEqualToString:g]) gi.state=NSControlStateValueOn;
  }
  if (existing.count) [grpM addItem:[NSMenuItem separatorItem]];
  NSMenuItem *newG=[grpM addItemWithTitle:@"New Group…" action:@selector(ctxAddTabToNewGroup:) keyEquivalent:@""];
  newG.target=self; newG.tag=i;
  if (tab.groupName.length) {
    NSMenuItem *rm=[grpM addItemWithTitle:@"Remove from Group" action:@selector(ctxRemoveTabFromGroup:) keyEquivalent:@""];
    rm.target=self; rm.tag=i;
    NSMenuItem *closeG=[grpM addItemWithTitle:[NSString stringWithFormat:@"Close “%@” Group",tab.groupName]
                                       action:@selector(ctxCloseGroup:) keyEquivalent:@""];
    closeG.target=self; closeG.tag=i;
  }
  grpRoot.submenu=grpM;
  [m addItem:[NSMenuItem separatorItem]];
  add(@"Move Tab Left", @selector(ctxMoveTabLeft:), i>0);
  add(@"Move Tab Right",@selector(ctxMoveTabRight:),i<(NSInteger)self.tabs.count-1);
  [m addItem:[NSMenuItem separatorItem]];
  add(@"New Tab to the Right",@selector(ctxNewTabRight:),YES);
  add(@"Move Tab to New Window",@selector(ctxMoveTabToNewWindow:),self.tabs.count>1);
  add(@"Duplicate Tab",@selector(ctxDuplicateTab:),YES);
  add(@"Add to Research Session…",@selector(addCurrentTabToSession:),YES);
  [m addItem:[NSMenuItem separatorItem]];
  add(@"Reload Tab",@selector(ctxReloadTab:),YES);
  [m addItem:[NSMenuItem separatorItem]];
  add(@"Close Tab",@selector(ctxCloseTab:),!tab.pinned);
  add(@"Close Other Tabs",@selector(ctxCloseOthers:),self.tabs.count>1);
  add(@"Close Tabs to the Right",@selector(ctxCloseRight:),i<(NSInteger)self.tabs.count-1);
  [m addItem:[NSMenuItem separatorItem]];
  add(@"Reopen Closed Tab",@selector(reopenClosedTab:),self.recentlyClosed.count>0);
  return m;
}
- (BOOL)validTabIndex:(NSInteger)i { return i>=0 && i<(NSInteger)self.tabs.count; }
- (void)ctxMoveTabToNewWindow:(id)s {
  NSInteger i=[(NSMenuItem*)s tag]; if(![self validTabIndex:i]||self.tabs.count<2) return;
  BBTab *tab=self.tabs[i];
  // Remove from this window
  if (self.activeTabIndex==i) {
    NSInteger next=i>0?i-1:1;
    [self tabItemDidSelect:next];
  } else if (self.activeTabIndex>i) self.activeTabIndex--;
  [self.tabs removeObjectAtIndex:i];
  [self reloadTabBar];
  // Open a new window carrying the tab's URL
  BBDelegate *w=[[BBDelegate alloc]init];
  NSNotification *dummy=[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp];
  [w applicationDidFinishLaunching:dummy];
  NSURL *u=tab.suspended?[NSURL URLWithString:tab.suspendedURL]:tab.webView.URL;
  if (u) [w.webView loadRequest:[NSURLRequest requestWithURL:u]];
}
- (void)ctxMoveTabLeft:(id)s  { NSInteger i=[(NSMenuItem*)s tag]; if(i<=0||![self validTabIndex:i])return; [self.tabs exchangeObjectAtIndex:i withObjectAtIndex:i-1]; if(self.activeTabIndex==i)self.activeTabIndex=i-1; [self reloadTabBar]; }
- (void)ctxMoveTabRight:(id)s { NSInteger i=[(NSMenuItem*)s tag]; if(i>=(NSInteger)self.tabs.count-1||![self validTabIndex:i])return; [self.tabs exchangeObjectAtIndex:i withObjectAtIndex:i+1]; if(self.activeTabIndex==i)self.activeTabIndex=i+1; [self reloadTabBar]; }
- (void)ctxNewTabRight:(id)s   { NSInteger i=[(NSMenuItem*)s tag]; if(![self validTabIndex:i])return; [self insertTabAt:i+1 private:self.tabs[i].isPrivate url:nil]; }
- (void)ctxDuplicateTab:(id)s  {
  NSInteger i=[(NSMenuItem*)s tag]; if(![self validTabIndex:i])return;
  [self insertTabAt:i+1 private:self.tabs[i].isPrivate url:self.tabs[i].webView.URL.absoluteString];
}
- (void)ctxReloadTab:(id)s     { NSInteger i=[(NSMenuItem*)s tag]; if([self validTabIndex:i])[self.tabs[i].webView reload]; }
- (void)ctxCloseTab:(id)s      { NSInteger i=[(NSMenuItem*)s tag]; if([self validTabIndex:i])[self tabItemDidClose:i]; }
- (void)ctxCloseOthers:(id)s {
  NSInteger i=[(NSMenuItem*)s tag]; if(![self validTabIndex:i])return;
  BBTab *keep=self.tabs[i];
  for (NSInteger j=(NSInteger)self.tabs.count-1;j>=0;j--) if (self.tabs[j]!=keep) [self teardownTabAtIndex:j];
  self.activeTabIndex=0; [self activateTab:0]; [self reloadTabBar];
}
- (void)ctxCloseRight:(id)s {
  NSInteger from=[(NSMenuItem*)s tag];
  for (NSInteger j=(NSInteger)self.tabs.count-1;j>from;j--) [self teardownTabAtIndex:j];
  if (self.activeTabIndex>from) self.activeTabIndex=from;
  [self activateTab:self.activeTabIndex]; [self reloadTabBar];
}
- (void)duplicateCurrentTab:(id)s {
  [self insertTabAt:self.activeTabIndex+1 private:self.activeTab.isPrivate url:self.webView.URL.absoluteString];
}

// Insert a new tab at a specific position (used by New Tab to Right / Duplicate).
- (void)insertTabAt:(NSInteger)idx private:(BOOL)priv url:(NSString *)url {
  if (idx<0) idx=0; if (idx>(NSInteger)self.tabs.count) idx=self.tabs.count;
  BBTab *tab=[[BBTab alloc]init]; tab.isPrivate=priv;
  tab.webView=[self makeWebViewPrivate:priv];
  [self.tabs insertObject:tab atIndex:idx];
  self.activeTabIndex=idx;
  [self activateTab:idx];
  NSURL *u=url.length?[NSURL URLWithString:url]:nil;
  if (u) [tab.webView loadRequest:[NSURLRequest requestWithURL:u]]; else [self loadStartPage:tab.webView];
  [self reloadTabBar];
}
- (void)pushRecentlyClosed:(NSString *)url title:(NSString *)title {
  if (!url.length) return;
  [self.recentlyClosed addObject:@{@"url":url,@"title":title?:url}];
  if (self.recentlyClosed.count>25) [self.recentlyClosed removeObjectAtIndex:0];
}

- (void)loadStartPage:(WKWebView *)wv {
  NSURL *landing=[[NSBundle mainBundle] URLForResource:@"BearBrowser-start" withExtension:@"html"];
  if (landing) [wv loadFileURL:landing allowingReadAccessToURL:[landing URLByDeletingLastPathComponent]];
  else [wv loadHTMLString:@"<h1>BearBrowser</h1>" baseURL:nil];
}
- (BOOL)isStartPage:(NSURL *)url {
  if (!url) return NO;
  NSURL *landing=[[NSBundle mainBundle] URLForResource:@"BearBrowser-start" withExtension:@"html"];
  return landing && [url.absoluteString isEqualToString:landing.absoluteString];
}
- (NSString *)htmlEscape:(NSString *)s {
  s=[s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
  s=[s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
  s=[s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
  s=[s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
  return s;
}
// Top sites by visit frequency for the New Tab Page (non-private history only).
- (NSArray<NSDictionary*> *)topSitesLimit:(NSInteger)n {
  NSMutableDictionary<NSString*,NSMutableDictionary*> *byHost=[NSMutableDictionary dictionary];
  for (BBHistoryEntry *e in [BBHistoryStore shared].entries) {
    NSURL *u=[NSURL URLWithString:e.urlString]; NSString *host=u.host; if(!host.length) continue;
    if([host hasPrefix:@"www."]) host=[host substringFromIndex:4];
    NSMutableDictionary *d=byHost[host];
    if(!d){ d=[@{@"count":@0} mutableCopy]; byHost[host]=d; }
    d[@"count"]=@([d[@"count"] integerValue]+1);
    d[@"url"]=e.urlString; d[@"host"]=host; if(e.title.length) d[@"title"]=e.title;
  }
  NSArray *sorted=[byHost.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary*a,NSDictionary*b){
    return [b[@"count"] compare:a[@"count"]];
  }];
  return sorted.count>n?[sorted subarrayWithRange:NSMakeRange(0,n)]:sorted;
}
// Replace the start page's curated grid with the user's most-visited sites.
- (void)injectTopSitesInto:(WKWebView *)wv {
  NSArray *sites=[self topSitesLimit:8];
  if (sites.count<4) return; // not enough history yet — keep the curated defaults
  NSMutableString *html=[NSMutableString string];
  for (NSDictionary *d in sites) {
    NSString *host=d[@"host"]?:@""; NSString *url=d[@"url"]?:@"";
    NSString *letter=host.length?[[host substringToIndex:1] uppercaseString]:@"•";
    // Use real favicon.ico; fall back to the letter initial on error (privacy-safe: only fetches
    // from sites the user has already visited, same as Chrome's top-sites favicons behaviour).
    NSString *faviconSrc=[NSString stringWithFormat:@"https://%@/favicon.ico",[self htmlEscape:host]];
    [html appendFormat:
      @"<a class=\"shortcut\" href=\"%@\">"
      @"<div class=\"shortcut-icon\" style=\"position:relative;overflow:hidden\">"
      @"<img src=\"%@\" width=\"32\" height=\"32\" style=\"object-fit:contain\" "
      @"onerror=\"this.style.display='none';this.nextElementSibling.style.display='flex'\">"
      @"<span style=\"display:none;width:100%%;height:100%%;align-items:center;justify-content:center;font-size:24px\">%@</span>"
      @"</div><span class=\"shortcut-label\">%@</span></a>",
      [self htmlEscape:url], faviconSrc, [self htmlEscape:letter], [self htmlEscape:host]];
  }
  NSString *js=[NSString stringWithFormat:
    @"(function(){var g=document.querySelector('.grid'); if(g) g.innerHTML=%@;})();",
    [self jsStringLiteral:html]];
  [wv evaluateJavaScript:js completionHandler:nil];
}

- (NSString *)windowTitleForTab:(BBTab *)tab {
  NSString *base=tab.title.length?tab.title:@"BearBrowser";
  return tab.isPrivate?[@"\U0001F575 Private — " stringByAppendingString:base]:base;
}
- (BBTab *)tabForWebView:(WKWebView *)wv {
  for (BBTab *t in self.tabs) if(t.webView==wv) return t;
  return nil;
}

// ── Actions ───────────────────────────────────────────────────────────────────
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }
- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
  NSMenu *m=[[NSMenu alloc]initWithTitle:@""];
  [m addItemWithTitle:@"New Tab"             action:@selector(newTab:)            keyEquivalent:@""].target=self;
  [m addItemWithTitle:@"New Window"          action:@selector(newWindow:)         keyEquivalent:@""].target=self;
  [m addItemWithTitle:@"New Incognito Window" action:@selector(newPrivateWindow:)  keyEquivalent:@""].target=self;
  if (self.recentlyClosed.count) {
    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *rcRoot=[m addItemWithTitle:@"Recently Closed" action:nil keyEquivalent:@""];
    NSMenu *sub=[[NSMenu alloc]initWithTitle:@""];
    for (NSInteger k=(NSInteger)self.recentlyClosed.count-1;k>=0&&k>=(NSInteger)self.recentlyClosed.count-10;k--) {
      NSDictionary *e=self.recentlyClosed[k];
      NSString *t=e[@"title"]?:e[@"url"];
      NSMenuItem *it=[sub addItemWithTitle:t.length>60?[[t substringToIndex:60] stringByAppendingString:@"…"]:t
                                    action:@selector(reopenSpecificClosed:) keyEquivalent:@""];
      it.target=self; it.tag=k;
    }
    rcRoot.submenu=sub;
  }
  return m;
}
- (void)applicationWillTerminate:(NSNotification *)n {
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"BBClearOnQuit"]) [[BBHistoryStore shared] clearAll];
}
// ── beforeunload dialog (sites that need to confirm navigation away) ──────────
- (void)webView:(WKWebView *)wv runBeforeUnloadConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void(^)(BOOL))done {
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Leave site?";
  a.informativeText=message.length?message:@"Changes you made may not be saved.";
  [a addButtonWithTitle:@"Leave"]; [a addButtonWithTitle:@"Stay"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    done(rc==NSAlertFirstButtonReturn);
  }];
}
// ── Warn when closing a window with multiple tabs ─────────────────────────────
- (BOOL)windowShouldClose:(NSWindow *)w {
  NSInteger count=[self.tabs count];
  NSInteger nonPinned=0;
  for (BBTab *t in self.tabs) if (!t.pinned) nonPinned++;
  if (nonPinned < 2) return YES; // 0 or 1 closeable tabs: close without dialog
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[NSString stringWithFormat:@"Close %ld tabs?", (long)count];
  a.informativeText=@"Your tabs will be saved and restored next time you launch BearBrowser.";
  [a addButtonWithTitle:@"Close All"]; [a addButtonWithTitle:@"Cancel"];
  a.alertStyle=NSAlertStyleWarning;
  return [a runModal]==NSAlertFirstButtonReturn;
}
- (void)windowWillClose:(NSNotification *)n {
  [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(self.window.frame) forKey:@"BBWindowFrame"];
  // Persist non-private tab metadata (url + pinned + muted + favicon) for session restore
  NSMutableArray *tabDicts=[NSMutableArray array];
  for (BBTab *t in self.tabs) {
    if (t.isPrivate) continue;
    NSString *u=t.suspended?t.suspendedURL:t.webView.URL.absoluteString;
    if (!u.length || [self isInternalURL:u]) continue;
    NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:
      @{@"url":u,@"pinned":@(t.pinned),@"muted":@(t.muted),@"title":t.title?:@"",
        @"group":t.groupName?:@"",@"groupColor":@(t.groupColorIdx)}];
    if (t.favicon) {
      NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:[t.favicon TIFFRepresentation]];
      NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      if (png) d[@"favicon"]=[png base64EncodedStringWithOptions:0];
    }
    [tabDicts addObject:d];
  }
  [[NSUserDefaults standardUserDefaults] setObject:tabDicts forKey:@"BBSessionURLs"];
  // Tear down local event monitors so they stop firing against torn-down state.
  if (self.addrDismissMonitor) { [NSEvent removeMonitor:self.addrDismissMonitor]; self.addrDismissMonitor=nil; }
  if (self.contextMenuMonitor) { [NSEvent removeMonitor:self.contextMenuMonitor]; self.contextMenuMonitor=nil; }
  if (self.middleClickMonitor) { [NSEvent removeMonitor:self.middleClickMonitor]; self.middleClickMonitor=nil; }
  if (self.ctrlScrollMonitor)  { [NSEvent removeMonitor:self.ctrlScrollMonitor];  self.ctrlScrollMonitor=nil; }
  [self.suspendTimer invalidate]; self.suspendTimer=nil;
  [self.sessionAutosaveTimer invalidate]; self.sessionAutosaveTimer=nil;
  [self.tabHoverTimer invalidate]; self.tabHoverTimer=nil;
  [self.tabHoverPanel close]; self.tabHoverPanel=nil;
  // Release this window's controller. Deferred so we never dealloc self midway
  // through this very method (the removal can drop the last strong reference).
  dispatch_async(dispatch_get_main_queue(),^{ [gBBWindowControllers removeObject:self]; });
}
- (void)readAloud:(id)s           { [[BBVoice shared] readPage:self.webView]; }
// ── Login autofill UI ─────────────────────────────────────────────────────────
- (void)offerSaveLoginForHost:(NSString *)host username:(NSString *)user password:(NSString *)pass {
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[NSString stringWithFormat:@"Save password for %@?",host];
  a.informativeText=[NSString stringWithFormat:@"BearBrowser will store the password for “%@” in your macOS Keychain.",user];
  [a addButtonWithTitle:@"Save"];
  [a addButtonWithTitle:@"Never for this site"];
  [a addButtonWithTitle:@"Not now"];
  // Per-host opt-out persists in user defaults; lookup short-circuits if set.
  NSString *neverKey=[NSString stringWithFormat:@"BBLoginNever_%@",host.lowercaseString];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:neverKey]) return;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if (rc==NSAlertFirstButtonReturn) {
      [[BBPasswordStore shared] saveHost:host username:user password:pass];
    } else if (rc==NSAlertSecondButtonReturn) {
      [[NSUserDefaults standardUserDefaults] setBool:YES forKey:neverKey];
    }
  }];
}
- (void)offerFillForTab:(BBTab *)tab webView:(WKWebView *)wv entries:(NSArray<BBPasswordEntry *> *)entries {
  if (!entries.count||!wv) return;
  // Single match: silent auto-fill (Chrome's behaviour). Multiple: prompt the user.
  if (entries.count==1) {
    [self fillCredential:entries[0] intoWebView:wv]; return;
  }
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Sign in with a saved account?";
  a.informativeText=@"BearBrowser has more than one saved login for this site.";
  for (NSInteger k=0;k<MIN((NSInteger)entries.count,3);k++) [a addButtonWithTitle:entries[k].username];
  [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    NSInteger idx=rc-NSAlertFirstButtonReturn;
    if (idx>=0&&idx<(NSInteger)entries.count) [self fillCredential:entries[idx] intoWebView:wv];
  }];
}
- (NSString *)generateStrongPassword:(NSInteger)len {
  // Cryptographic random via SecRandomCopyBytes; charset is letters+digits+symbols
  // chosen for max-compatibility with site password policies (no quotes/backslashes).
  static const char *cs="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*-_=+?";
  size_t csLen=strlen(cs);
  if (len<8) len=20;
  uint8_t *buf=(uint8_t *)malloc((size_t)len);
  if (!buf) return @"";
  if (SecRandomCopyBytes(kSecRandomDefault,(size_t)len,buf)!=errSecSuccess) { free(buf); return @""; }
  NSMutableString *out=[NSMutableString stringWithCapacity:(NSUInteger)len];
  for (NSInteger i=0;i<len;i++) [out appendFormat:@"%c",cs[buf[i]%csLen]];
  free(buf);
  return out;
}
- (void)offerGenPassForHost:(NSString *)host webView:(WKWebView *)wv {
  if (!wv) return;
  NSString *pw=[self generateStrongPassword:20];
  if (!pw.length) return;
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Use a strong password?";
  a.informativeText=[NSString stringWithFormat:@"%@\n\nBearBrowser will fill this 20-char password and offer to save it on submit.",pw];
  [a addButtonWithTitle:@"Use Strong Password"];
  [a addButtonWithTitle:@"Not now"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if (rc!=NSAlertFirstButtonReturn) return;
    NSString *js=[NSString stringWithFormat:
      @"if(typeof window.__bbApplyGenPass==='function')window.__bbApplyGenPass(%@);",
      [self jsStringLiteral:pw]];
    [wv evaluateJavaScript:js completionHandler:nil];
  }];
}
- (void)fillCredential:(BBPasswordEntry *)e intoWebView:(WKWebView *)wv {
  if (!e||!wv) return;
  NSString *js=[NSString stringWithFormat:
    @"if(typeof window.__bbAutofill==='function')window.__bbAutofill({user:%@,pass:%@});",
    [self jsStringLiteral:e.username], [self jsStringLiteral:e.password]];
  [wv evaluateJavaScript:js completionHandler:nil];
}
- (void)muteTab:(id)s {
  BBTab *tab=self.activeTab; if (!tab) return;
  tab.muted=!tab.muted;
  BOOL muted=tab.muted;
  [tab.webView evaluateJavaScript:
    [NSString stringWithFormat:@"document.querySelectorAll('audio,video').forEach(function(m){m.muted=%@;})",muted?@"true":@"false"]
    completionHandler:nil];
  [self reloadTabBar];
}
- (void)setAllTabsMuted:(BOOL)muted {
  NSString *js=[NSString stringWithFormat:
    @"document.querySelectorAll('audio,video').forEach(function(m){m.muted=%@;})",muted?@"true":@"false"];
  for (BBTab *tab in self.tabs) {
    tab.muted=muted;
    [tab.webView evaluateJavaScript:js completionHandler:nil];
  }
  [self reloadTabBar];
}
- (void)muteAllTabs:(id)s   { [self setAllTabsMuted:YES]; }
- (void)unmuteAllTabs:(id)s { [self setAllTabsMuted:NO];  }
- (void)contextSaveLink:(id)sender {
  NSMenuItem *mi=(NSMenuItem *)sender; NSString *urlStr=mi.representedObject;
  if (!urlStr.length) return;
  NSURL *src=[NSURL URLWithString:urlStr]; if (!src) return;
  NSURLRequest *req=[NSURLRequest requestWithURL:src];
  // Route through WKWebView so it inherits cookies/UA + uses our download delegate.
  [self.webView startDownloadUsingRequest:req completionHandler:^(WKDownload *dl){
    dl.delegate=self;
  }];
}
- (void)contextSearchImageOnLens:(NSMenuItem *)item {
  NSString *u=item.representedObject; if (![u isKindOfClass:[NSString class]]||!u.length) return;
  NSString *enc=[u stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]?:@"";
  NSURL *lens=[NSURL URLWithString:[NSString stringWithFormat:@"https://lens.google.com/uploadbyurl?url=%@",enc]];
  if (!lens) return;
  NSInteger prev=self.activeTabIndex;
  [self addTabPrivate:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:lens]];
  (void)prev;
}
- (void)contextSearchImageOnTinEye:(NSMenuItem *)item {
  NSString *u=item.representedObject; if (![u isKindOfClass:[NSString class]]||!u.length) return;
  NSString *enc=[u stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]?:@"";
  NSURL *tin=[NSURL URLWithString:[NSString stringWithFormat:@"https://tineye.com/search?url=%@",enc]];
  if (!tin) return;
  [self addTabPrivate:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:tin]];
}
- (void)contextSaveImage:(id)sender {
  NSMenuItem *mi=(NSMenuItem *)sender; NSString *urlStr=mi.representedObject;
  if (!urlStr.length) return;
  NSURL *src=[NSURL URLWithString:urlStr]; if (!src) return;
  NSSavePanel *sp=[NSSavePanel savePanel];
  sp.nameFieldStringValue=src.lastPathComponent.length?src.lastPathComponent:@"image";
  [sp beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if (rc!=NSModalResponseOK) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
      NSData *data=[NSData dataWithContentsOfURL:src];
      if (data) [data writeToURL:sp.URL atomically:YES];
    });
  }];
}
// ── Reading List ────────────────────────────────────────────────────────────
- (void)addToReadingList:(id)s {
  NSString *url=self.webView.URL.absoluteString; NSString *title=self.activeTab.title?:url;
  if (!url.length||[self isInternalURL:url]) { NSBeep(); return; }
  [[BBReadingList shared] addTitle:title url:url];
  [self showStatus:@"Added to Reading List"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    if ([self.statusBar.stringValue isEqualToString:@"Added to Reading List"]) self.statusBar.hidden=YES;
  });
}
- (void)showReadingList:(id)s {
  CGFloat W=640,Hh=460;
  NSWindow *rw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,W,Hh)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:YES];
  rw.releasedWhenClosed=NO; rw.title=@"Reading List"; [rw center];
  NSView *cv=rw.contentView;
  NSScrollView *sv=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,48,W,Hh-48)];
  sv.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; sv.hasVerticalScroller=YES;
  NSTableView *tv=[[NSTableView alloc]init]; tv.rowHeight=30;
  NSTableColumn *cr=[[NSTableColumn alloc]initWithIdentifier:@"read"];  cr.title=@"";      cr.width=22;
  NSTableColumn *ct=[[NSTableColumn alloc]initWithIdentifier:@"title"]; ct.title=@"Title"; ct.width=300;
  NSTableColumn *cu=[[NSTableColumn alloc]initWithIdentifier:@"url"];   cu.title=@"URL";   cu.width=300;
  [tv addTableColumn:cr]; [tv addTableColumn:ct]; [tv addTableColumn:cu];
  sv.documentView=tv; [cv addSubview:sv];
  BBReadingListDS *ds=[[BBReadingListDS alloc]initWithWebView:self.webView window:rw tableView:tv];
  tv.dataSource=ds; tv.delegate=ds; tv.target=ds; tv.doubleAction=@selector(openSelected);
  objc_setAssociatedObject(rw,@"rlds",ds,OBJC_ASSOCIATION_RETAIN);
  [tv reloadData];
  NSButton *open=[[NSButton alloc]initWithFrame:NSMakeRect(12,10,90,30)];
  open.title=@"Open"; open.bezelStyle=NSBezelStyleRounded; open.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  open.target=ds; open.action=@selector(openSelected); [cv addSubview:open];
  NSButton *toggle=[[NSButton alloc]initWithFrame:NSMakeRect(108,10,140,30)];
  toggle.title=@"Mark Read/Unread"; toggle.bezelStyle=NSBezelStyleRounded; toggle.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  toggle.target=ds; toggle.action=@selector(toggleReadSelected); [cv addSubview:toggle];
  NSButton *rm=[[NSButton alloc]initWithFrame:NSMakeRect(254,10,90,30)];
  rm.title=@"Remove"; rm.bezelStyle=NSBezelStyleRounded; rm.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  rm.target=ds; rm.action=@selector(removeSelected); [cv addSubview:rm];
  NSButton *done=[[NSButton alloc]initWithFrame:NSMakeRect(W-102,10,90,30)];
  done.title=@"Done"; done.bezelStyle=NSBezelStyleRounded; done.keyEquivalent=@"\r"; done.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;
  done.target=rw; done.action=@selector(performClose:); [cv addSubview:done];
  [self.window beginSheet:rw completionHandler:nil];
}
- (void)bookmarkAllTabs:(id)s {
  NSInteger added=0;
  for (BBTab *t in self.tabs) {
    NSString *url=t.suspended?t.suspendedURL:t.webView.URL.absoluteString;
    if (!url.length||[self isInternalURL:url]) continue;
    if (![[BBBookmarksStore shared] isBookmarked:url]) {
      [[BBBookmarksStore shared] addTitle:t.title.length?t.title:url url:url];
      added++;
    }
  }
  [[BBBookmarksStore shared] save];
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[NSString stringWithFormat:@"%ld tab%@ bookmarked",(long)added,added==1?@"":@"s"];
  [a addButtonWithTitle:@"OK"]; [a runModal];
}

// ── Bookmarks ─────────────────────────────────────────────────────────────────
- (void)addBookmark:(id)s {
  NSString *url=self.webView.URL.absoluteString; NSString *title=self.activeTab.title?:url;
  if (!url.length||[url hasPrefix:@"bearbrowser://"]) return;
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Add Bookmark";
  NSView *acc=[[NSView alloc]initWithFrame:NSMakeRect(0,0,320,82)];
  NSTextField *titleLbl=[NSTextField labelWithString:@"Name:"];
  titleLbl.frame=NSMakeRect(0,52,60,20); titleLbl.alignment=NSTextAlignmentRight; [acc addSubview:titleLbl];
  NSTextField *tf=[[NSTextField alloc]initWithFrame:NSMakeRect(64,50,256,24)];
  tf.stringValue=title; tf.font=[NSFont systemFontOfSize:13]; [acc addSubview:tf];
  NSTextField *folderLbl=[NSTextField labelWithString:@"Folder:"];
  folderLbl.frame=NSMakeRect(0,18,60,20); folderLbl.alignment=NSTextAlignmentRight; [acc addSubview:folderLbl];
  NSComboBox *cb=[[NSComboBox alloc]initWithFrame:NSMakeRect(64,16,256,24)];
  cb.usesDataSource=NO; cb.completes=YES; cb.placeholderString=@"(bookmarks bar root)";
  [cb addItemWithObjectValue:@""];
  for (NSString *f in [[BBBookmarksStore shared] folders]) [cb addItemWithObjectValue:f];
  [acc addSubview:cb];
  a.accessoryView=acc;
  [a addButtonWithTitle:@"Add"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if(rc!=NSAlertFirstButtonReturn) return;
    NSString *folder=[cb.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [[BBBookmarksStore shared] addTitle:tf.stringValue?:title url:url folder:folder];
    [self reloadBookmarksBar];
  }];
}
- (void)toggleBookmarksBar:(id)s {
  self.bookmarksBarVisible=!self.bookmarksBarVisible;
  self.bookmarksBar.hidden=!self.bookmarksBarVisible;
  [[NSUserDefaults standardUserDefaults] setBool:self.bookmarksBarVisible forKey:@"BBShowBookmarksBar"];
  if (self.bookmarksBarVisible) [self reloadBookmarksBar];
  [self resizeWebViewForCurrentTab];
}
- (void)reloadBookmarksBar {
  for (NSView *v in self.bookmarksBar.subviews.copy) [v removeFromSuperview];
  CGFloat x=8;
  CGFloat barW=self.bookmarksBar.bounds.size.width;
  CGFloat overflowReserve=32;
  NSArray<BBBookmark *> *all=[BBBookmarksStore shared].items;
  // Folder buttons first (alphabetical isn't ideal; use first-seen order from store).
  NSArray<NSString *> *folders=[[BBBookmarksStore shared] folders];
  NSMutableArray<NSString *> *overflowFolders=[NSMutableArray array];
  for (NSString *f in folders) {
    NSButton *btn=[[NSButton alloc]initWithFrame:NSMakeRect(x,3,0,24)];
    NSImage *folderImg=[NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:@"Folder"];
    [folderImg setTemplate:YES];
    btn.image=folderImg; btn.imagePosition=NSImageLeft;
    btn.title=f; btn.font=[NSFont systemFontOfSize:11]; btn.bezelStyle=NSBezelStyleRoundRect;
    btn.target=self; btn.action=@selector(bookmarkFolderClicked:);
    objc_setAssociatedObject(btn,"BBFolderName",f,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [btn sizeToFit]; btn.frame=NSMakeRect(x,3,btn.frame.size.width+10,24);
    if (x+btn.frame.size.width > barW-overflowReserve) { [overflowFolders addObject:f]; continue; }
    [self.bookmarksBar addSubview:btn];
    x+=btn.frame.size.width+4;
  }
  // Root (no-folder) bookmarks next.
  NSMutableArray<BBBookmark *> *root=[NSMutableArray array];
  for (BBBookmark *b in all) if (!b.folder.length) [root addObject:b];
  NSInteger shownRoot=0;
  for (BBBookmark *b in root) {
    NSButton *btn=[[NSButton alloc]initWithFrame:NSMakeRect(x,3,0,24)];
    btn.title=b.title.length?b.title:b.urlString;
    btn.font=[NSFont systemFontOfSize:11]; btn.bezelStyle=NSBezelStyleRoundRect;
    btn.target=self; btn.action=@selector(bookmarkButtonClicked:);
    [btn sizeToFit]; btn.frame=NSMakeRect(x,3,btn.frame.size.width+8,24);
    btn.toolTip=b.urlString;
    if (x+btn.frame.size.width > barW-overflowReserve) break;
    [self.bookmarksBar addSubview:btn];
    x+=btn.frame.size.width+4; shownRoot++;
  }
  BOOL anyOverflow=(overflowFolders.count>0)||(shownRoot<(NSInteger)root.count);
  if (anyOverflow) {
    NSButton *more=[[NSButton alloc]initWithFrame:NSMakeRect(barW-28,3,22,24)];
    more.autoresizingMask=NSViewMinXMargin;
    NSImage *ch=[NSImage imageWithSystemSymbolName:@"chevron.right.2" accessibilityDescription:@"More bookmarks"];
    [ch setTemplate:YES]; more.image=ch; more.imagePosition=NSImageOnly;
    more.bezelStyle=NSBezelStyleToolbar; more.bordered=NO;
    more.toolTip=@"More bookmarks";
    more.target=self; more.action=@selector(showBookmarksOverflow:);
    objc_setAssociatedObject(more,"BBOverflowFolders",overflowFolders,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    more.tag=shownRoot;
    [self.bookmarksBar addSubview:more];
  }
}
- (void)bookmarkFolderClicked:(NSButton *)btn {
  NSString *folder=objc_getAssociatedObject(btn,"BBFolderName");
  if (!folder.length) return;
  NSMenu *m=[[NSMenu alloc]initWithTitle:folder];
  for (BBBookmark *b in [BBBookmarksStore shared].items) {
    if (![b.folder isEqualToString:folder]) continue;
    NSMenuItem *mi=[m addItemWithTitle:b.title.length?b.title:b.urlString
                                action:@selector(bookmarkOverflowSelected:) keyEquivalent:@""];
    mi.target=self; mi.representedObject=b.urlString; mi.toolTip=b.urlString;
  }
  if (!m.itemArray.count)
    [m addItemWithTitle:@"(empty)" action:nil keyEquivalent:@""].enabled=NO;
  [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(btn.bounds)) inView:btn];
}
- (void)showBookmarksOverflow:(NSButton *)btn {
  NSArray<BBBookmark *> *all=[BBBookmarksStore shared].items;
  NSArray<NSString *> *overflowFolders=objc_getAssociatedObject(btn,"BBOverflowFolders")?:@[];
  NSMutableArray<BBBookmark *> *root=[NSMutableArray array];
  for (BBBookmark *b in all) if (!b.folder.length) [root addObject:b];
  NSInteger startIdx=btn.tag;
  NSMenu *m=[[NSMenu alloc]initWithTitle:@""];
  // Hidden folders first as submenus, then overflowing root bookmarks.
  for (NSString *f in overflowFolders) {
    NSMenuItem *fi=[m addItemWithTitle:f action:nil keyEquivalent:@""];
    NSMenu *sub=[[NSMenu alloc]initWithTitle:f];
    for (BBBookmark *b in all) {
      if (![b.folder isEqualToString:f]) continue;
      NSMenuItem *mi=[sub addItemWithTitle:b.title.length?b.title:b.urlString
                                    action:@selector(bookmarkOverflowSelected:) keyEquivalent:@""];
      mi.target=self; mi.representedObject=b.urlString; mi.toolTip=b.urlString;
    }
    fi.submenu=sub;
  }
  if (overflowFolders.count && startIdx<(NSInteger)root.count) [m addItem:[NSMenuItem separatorItem]];
  for (NSInteger k=startIdx;k<(NSInteger)root.count;k++) {
    BBBookmark *b=root[k];
    NSMenuItem *mi=[m addItemWithTitle:b.title.length?b.title:b.urlString
                                action:@selector(bookmarkOverflowSelected:) keyEquivalent:@""];
    mi.target=self; mi.representedObject=b.urlString; mi.toolTip=b.urlString;
  }
  [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(btn.bounds)) inView:btn];
}
- (void)bookmarkOverflowSelected:(NSMenuItem *)mi {
  NSString *u=mi.representedObject; if (!u.length) return;
  NSURL *url=[NSURL URLWithString:u]; if (!url) return;
  [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}
- (void)bookmarkButtonClicked:(NSButton *)btn {
  NSString *url=btn.toolTip; if(!url) return;
  NSURL *u=[NSURL URLWithString:url]; if(!u) return;
  [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}

// ── History panel ─────────────────────────────────────────────────────────────
- (void)showHistory:(id)s {
  NSWindow *hw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,680,500)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:YES];
  hw.releasedWhenClosed=NO;
  hw.title=@"History"; [hw center];
  NSView *cv=hw.contentView;
  NSSearchField *sf=[[NSSearchField alloc]initWithFrame:NSMakeRect(12,hw.contentView.bounds.size.height-44,656,28)];
  sf.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  sf.placeholderString=@"Search history"; [cv addSubview:sf];
  NSScrollView *sv=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,680,hw.contentView.bounds.size.height-56)];
  sv.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; sv.hasVerticalScroller=YES;
  NSTableView *tv=[[NSTableView alloc]init]; tv.rowHeight=36;
  NSTableColumn *c1=[[NSTableColumn alloc]initWithIdentifier:@"title"]; c1.title=@"Title"; c1.width=280;
  NSTableColumn *c2=[[NSTableColumn alloc]initWithIdentifier:@"url"];   c2.title=@"URL";   c2.width=280;
  NSTableColumn *c3=[[NSTableColumn alloc]initWithIdentifier:@"when"];  c3.title=@"When";  c3.width=100;
  [tv addTableColumn:c1]; [tv addTableColumn:c2]; [tv addTableColumn:c3];
  sv.documentView=tv; [cv addSubview:sv];
  // Newest-first, deduplicated by URL (keep the most recent visit per site) so the
  // list reads like Chrome's history rather than a raw per-visit log full of repeats.
  NSMutableArray<BBHistoryEntry *> *shown=[NSMutableArray array];
  NSMutableSet<NSString *> *seen=[NSMutableSet set];
  for (BBHistoryEntry *e in [BBHistoryStore shared].entries.reverseObjectEnumerator) {
    if (!e.urlString.length || [seen containsObject:e.urlString]) continue;
    [seen addObject:e.urlString]; [shown addObject:e];
  }
  __block NSMutableArray<BBHistoryEntry *> *filtered=[shown mutableCopy];
  // Simple datasource object
  BBHistoryPanelDS *ds=[[BBHistoryPanelDS alloc]initWithEntries:filtered tableView:tv searchField:sf window:hw webView:self.webView];
  tv.dataSource=ds; tv.delegate=ds; sf.delegate=ds;
  objc_setAssociatedObject(hw,@"ds",ds,OBJC_ASSOCIATION_RETAIN);
  [tv reloadData];
  [self.window beginSheet:hw completionHandler:nil];
}

- (void)clearHistory:(id)s {
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Clear Browsing Data?";
  a.informativeText=@"Removes history, cookies, cached images, and site data. This cannot be undone.";
  [a addButtonWithTitle:@"Clear Data"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if (rc!=NSAlertFirstButtonReturn) return;
    [[BBHistoryStore shared] clearAll];
    // Also wipe WebKit's persistent store: cookies, disk cache, local storage, etc.
    NSSet *all=[WKWebsiteDataStore allWebsiteDataTypes];
    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:all modifiedSince:[NSDate distantPast] completionHandler:^{}];
  }];
}
- (void)goHome:(id)s {
  NSString *hp=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBHomepage"];
  if (hp.length) {
    if (!([hp hasPrefix:@"http://"]||[hp hasPrefix:@"https://"]||[hp hasPrefix:@"file://"]))
      hp=[@"https://" stringByAppendingString:hp];
    NSURL *u=[NSURL URLWithString:hp];
    if (u) { [self.webView loadRequest:[NSURLRequest requestWithURL:u]]; return; }
  }
  [self loadStartPage:self.webView];
}
- (void)openBearHelp:(id)s { [self addTabPrivate:NO]; [self loadStartPage:self.webView]; }
- (void)reportIssue:(id)s {
  NSURL *u=[NSURL URLWithString:@"https://github.com/SourceOS-Linux/BearBrowser/issues/new"];
  if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}
- (void)showKeyboardShortcuts:(id)s {
  // One-shot, scrollable cheat sheet. Lives in NSAlert so it's modal-light.
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"BearBrowser Keyboard Shortcuts";
  a.informativeText=
    @"Navigation\n"
    @"  ⌘L / ⌘K        Focus address bar\n"
    @"  ⌘[ / ⌘]        Back / Forward\n"
    @"  ⌘R              Reload    ⇧⌘R  Hard reload    ⌘.  Stop\n"
    @"  ⇧⌘H            Home\n\n"
    @"Tabs\n"
    @"  ⌘T              New tab    ⇧⌘T  Reopen closed tab\n"
    @"  ⌘W              Close tab    ⇧⌘W  Close window\n"
    @"  ⌃⇥ / ⇧⌃⇥      Next / Previous tab\n"
    @"  ⌘1…⌘8 / ⌘9   Jump to tab / last tab\n"
    @"  ⇧⌘A            Tab search\n"
    @"  ⇧⌃[ / ⇧⌃]    Move tab left / right\n\n"
    @"View\n"
    @"  ⌘+ / ⌘− / ⌘0  Zoom in / out / reset    ⌃scroll Zoom\n"
    @"  ⇧⌘B            Toggle bookmarks bar\n"
    @"  ⌃⌘F             Full screen\n\n"
    @"Find / Edit\n"
    @"  ⌘F              Find on page    ⌘G / ⇧⌘G  Next / Previous\n"
    @"  ⇧⌘C            Copy current URL\n"
    @"  ⇧⌘V            Paste and go\n\n"
    @"Windows / Files\n"
    @"  ⌘N              New window    ⇧⌘N  Incognito window\n"
    @"  ⌘O              Open file    ⌘S  Save page    ⌘P  Print\n\n"
    @"History / Downloads\n"
    @"  ⌘Y              Show history    ⇧⌘J  Downloads\n"
    @"  ⇧⌘⌫           Clear browsing data";
  [a addButtonWithTitle:@"Close"];
  [a beginSheetModalForWindow:self.window completionHandler:nil];
}
// Reader mode: extract the main article (best-effort, by paragraph density) and
// render it in our OWN clean template, so the layout is fully under our control.
// ── Translation ──────────────────────────────────────────────────────────────
// We open Google Translate's web translator in a new tab with the page URL
// as the source. No API key, no third-party SDK; user's browsing language
// list governs whether we offer the prompt. Override the translator service
// via the BBTranslateURL default (%@ = source URL).
- (NSArray<NSString *> *)preferredLanguages {
  NSArray *saved=[[NSUserDefaults standardUserDefaults] stringArrayForKey:@"BBTranslateNativeLangs"];
  if (saved.count) return saved;
  NSMutableArray *out=[NSMutableArray array];
  for (NSString *l in [NSLocale preferredLanguages]) {
    NSString *prefix=[l componentsSeparatedByString:@"-"].firstObject.lowercaseString;
    if (prefix.length && ![out containsObject:prefix]) [out addObject:prefix];
  }
  if (!out.count) [out addObject:@"en"];
  return out;
}
- (BOOL)isNativeLanguage:(NSString *)htmlLang {
  if (!htmlLang.length) return YES;
  NSString *prefix=[htmlLang componentsSeparatedByString:@"-"].firstObject.lowercaseString;
  for (NSString *l in [self preferredLanguages]) if ([prefix isEqualToString:l]) return YES;
  return NO;
}
- (void)maybeOfferTranslateForLang:(NSString *)lang tab:(BBTab *)tab {
  if (!tab||tab.translateOffered) return;
  if ([self isNativeLanguage:lang]) return;
  // Per-host opt-out persists across sessions.
  NSString *host=tab.webView.URL.host?:@"";
  NSString *neverKey=[NSString stringWithFormat:@"BBTranslateNever_%@",host.lowercaseString];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:neverKey]) return;
  tab.translateOffered=YES;
  dispatch_async(dispatch_get_main_queue(),^{
    NSAlert *a=[[NSAlert alloc]init];
    a.messageText=[NSString stringWithFormat:@"Translate this %@ page?",lang.uppercaseString];
    a.informativeText=@"BearBrowser will open the page in your configured translation service. The page URL is sent to that service.";
    [a addButtonWithTitle:@"Translate"];
    [a addButtonWithTitle:@"Never for this site"];
    [a addButtonWithTitle:@"Not now"];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
      if (rc==NSAlertFirstButtonReturn) [self translatePage:nil];
      else if (rc==NSAlertSecondButtonReturn) [[NSUserDefaults standardUserDefaults] setBool:YES forKey:neverKey];
    }];
  });
}
- (void)translatePage:(id)s {
  NSURL *u=self.webView.URL; if (!u) return;
  NSString *fmt=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBTranslateURL"];
  if (!fmt.length) fmt=@"https://translate.google.com/translate?sl=auto&tl=%1$@&u=%2$@";
  NSString *target=[self preferredLanguages].firstObject?:@"en";
  NSString *escaped=[u.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  // Two-argument format: %1$@ = target lang, %2$@ = URL-escaped source URL.
  NSString *finalURL=[NSString stringWithFormat:fmt,target,escaped];
  NSURL *translateURL=[NSURL URLWithString:finalURL];
  if (!translateURL) return;
  NSInteger prev=self.activeTabIndex;
  [self addTabPrivate:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:translateURL]];
  // Foreground the translated page — translation is the user's main intent here.
  (void)prev;
}
- (void)toggleReader:(id)s {
  if (self.readerMode) {
    self.readerMode=NO;
    if (self.readerOriginalURL) [self.webView loadRequest:[NSURLRequest requestWithURL:self.readerOriginalURL]];
    else [self.webView reload];
    return;
  }
  NSString *js=
    @"(function(){function sc(el){var t=0;el.querySelectorAll('p').forEach(function(x){t+=(x.innerText||'').length;});return t;}"
    @"var best=document.body,bs=0;"
    @"document.querySelectorAll('article,main,[role=main],section,div').forEach(function(el){var s=sc(el);if(s>bs){bs=s;best=el;}});"
    @"var title=((document.querySelector('h1')||{}).innerText)||document.title||'';"
    @"var blocks=[];best.querySelectorAll('h1,h2,h3,h4,p,li,blockquote,pre,img').forEach(function(el){"
    @"if(el.tagName==='IMG'){if(el.src)blocks.push({t:'img',src:el.src});}"
    @"else{var x=(el.innerText||'').trim();if(x.length>1)blocks.push({t:el.tagName.toLowerCase(),x:x});}});"
    @"return JSON.stringify({title:title,blocks:blocks});})();";
  [self.webView evaluateJavaScript:js completionHandler:^(id r,NSError *e){
    NSString *json=[r isKindOfClass:[NSString class]]?r:nil;
    NSDictionary *obj=json?[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]:nil;
    NSArray *blocks=obj[@"blocks"];
    if (![blocks isKindOfClass:[NSArray class]] || blocks.count<2) { NSBeep(); return; }
    NSMutableString *body=[NSMutableString string];
    for (NSDictionary *b in blocks) {
      NSString *t=b[@"t"];
      if ([t isEqualToString:@"img"]) { NSString *src=b[@"src"]; if(src.length)[body appendFormat:@"<img src=\"%@\">",[self htmlEscape:src]]; }
      else if ([t isEqualToString:@"li"]) [body appendFormat:@"<li>%@</li>",[self htmlEscape:b[@"x"]]];
      else [body appendFormat:@"<%@>%@</%@>",t,[self htmlEscape:b[@"x"]],t];
    }
    NSString *title=[self htmlEscape:obj[@"title"]?:@""];
    NSString *html=[NSString stringWithFormat:
      @"<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\">"
      @"<style>:root{color-scheme:light dark}"
      @"body{max-width:42rem;margin:0 auto;padding:48px 24px 96px;"
      @"font:18px/1.7 -apple-system,Georgia,serif;color:#1d1d1f;background:#fff}"
      @"@media(prefers-color-scheme:dark){body{color:#e8e8ea;background:#1c1c1e}}"
      @"h1{font-size:2em;line-height:1.2;margin:0 0 .6em}h2,h3,h4{line-height:1.3;margin:1.4em 0 .4em}"
      @"p,li,blockquote,pre{margin:0 0 1em}blockquote{padding-left:1em;border-left:3px solid #ccc;color:#666}"
      @"pre{white-space:pre-wrap;font:14px/1.5 ui-monospace,monospace;background:rgba(127,127,127,.12);padding:12px;border-radius:8px}"
      @"img{max-width:100%%;height:auto;border-radius:8px;margin:1em 0}</style>"
      @"<h1>%@</h1>%@", title, body];
    self.readerOriginalURL=self.webView.URL;
    self.readerMode=YES;
    [self.webView loadHTMLString:html baseURL:self.webView.URL];
  }];
}
- (void)openBookmarkManager:(id)s {
  CGFloat W=640,Hh=460;
  NSWindow *bw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,W,Hh)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:YES];
  bw.releasedWhenClosed=NO; bw.title=@"Bookmarks"; [bw center];
  NSView *cv=bw.contentView;
  NSScrollView *sv=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,48,W,Hh-48)];
  sv.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; sv.hasVerticalScroller=YES;
  NSTableView *tv=[[NSTableView alloc]init]; tv.rowHeight=30;
  NSTableColumn *c1=[[NSTableColumn alloc]initWithIdentifier:@"title"];  c1.title=@"Title";  c1.width=210;
  NSTableColumn *cf=[[NSTableColumn alloc]initWithIdentifier:@"folder"]; cf.title=@"Folder"; cf.width=110;
  NSTableColumn *c2=[[NSTableColumn alloc]initWithIdentifier:@"url"];    c2.title=@"URL";    c2.width=290;
  [tv addTableColumn:c1]; [tv addTableColumn:cf]; [tv addTableColumn:c2];
  sv.documentView=tv; [cv addSubview:sv];
  BBBookmarksPanelDS *ds=[[BBBookmarksPanelDS alloc]init];
  ds.tv=tv; ds.win=bw; ds.webView=self.webView;
  tv.dataSource=ds; tv.delegate=ds; tv.target=ds; tv.doubleAction=@selector(openSelected);
  objc_setAssociatedObject(bw,@"bmds",ds,OBJC_ASSOCIATION_RETAIN);
  [tv reloadData];
  NSButton *open=[[NSButton alloc]initWithFrame:NSMakeRect(12,10,90,30)];
  open.title=@"Open"; open.bezelStyle=NSBezelStyleRounded; open.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  open.target=ds; open.action=@selector(openSelected); [cv addSubview:open];
  NSButton *rm=[[NSButton alloc]initWithFrame:NSMakeRect(108,10,90,30)];
  rm.title=@"Remove"; rm.bezelStyle=NSBezelStyleRounded; rm.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  rm.target=ds; rm.action=@selector(removeSelected); [cv addSubview:rm];
  NSButton *mv=[[NSButton alloc]initWithFrame:NSMakeRect(204,10,130,30)];
  mv.title=@"Move to Folder…"; mv.bezelStyle=NSBezelStyleRounded; mv.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  mv.target=ds; mv.action=@selector(moveSelectedToFolder); [cv addSubview:mv];
  NSButton *done=[[NSButton alloc]initWithFrame:NSMakeRect(W-102,10,90,30)];
  done.title=@"Done"; done.bezelStyle=NSBezelStyleRounded; done.keyEquivalent=@"\r"; done.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;
  done.target=bw; done.action=@selector(performClose:); [cv addSubview:done];
  [self.window beginSheet:bw completionHandler:nil];
}

// ── Downloads ─────────────────────────────────────────────────────────────────
- (void)toggleDownloadPanel:(id)s {
  self.downloadPanel.hidden=!self.downloadPanel.hidden;
}

// ── Address dropdown delegate ─────────────────────────────────────────────────
- (void)dropdownSelectedURL:(NSString *)urlString {
  // Called by table click (mouse selection) — navigate immediately
  [self.addressDropdown hide];
  // Switch-to-tab row: jump to the matched open tab in place of navigating.
  if ([urlString hasPrefix:@"bb-switch-tab:"]) {
    NSInteger idx=[[urlString substringFromIndex:14] integerValue];
    if (idx>=0 && idx<(NSInteger)self.tabs.count) [self tabItemDidSelect:idx];
    [self.window makeFirstResponder:self.webView];
    return;
  }
  // Calculator row: NSExpression result has no scheme — copy to clipboard and bail.
  if (urlString.length && [urlString rangeOfString:@"://"].location==NSNotFound &&
      [urlString rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location==NSNotFound) {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:urlString forType:NSPasteboardTypeString];
    [self showStatus:[NSString stringWithFormat:@"Copied %@",urlString]];
    [self.window makeFirstResponder:self.webView];
    return;
  }
  NSURL *u=[NSURL URLWithString:urlString]; if(!u) return;
  self.address.stringValue=urlString;
  [self.window makeFirstResponder:self.webView];
  [self emitNav:@"navigation.requested" url:urlString reason:@"Dropdown navigation." private:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}
- (void)addressFieldPasteAndGo:(NSString *)raw {
  raw=[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!raw.length) return;
  NSString *rawLower=raw.lowercaseString;
  if ([rawLower hasPrefix:@"javascript:"]||[rawLower hasPrefix:@"view-source:"]||
      [rawLower hasPrefix:@"webkit-"]||[rawLower hasPrefix:@"x-webkit"]) return;
  BOOL hasScheme=[raw hasPrefix:@"http://"]||[raw hasPrefix:@"https://"]||[raw hasPrefix:@"file://"];
  BOOL looksLikeURL=[raw rangeOfString:@" "].location==NSNotFound&&[raw rangeOfString:@"."].location!=NSNotFound;
  NSURL *url=nil;
  if (hasScheme) url=[NSURL URLWithString:raw];
  else if (looksLikeURL) url=[NSURL URLWithString:[@"https://" stringByAppendingString:raw]];
  else url=[NSURL URLWithString:[BBDelegate searchURLForQuery:raw]];
  if (!url) return;
  self.address.stringValue=url.absoluteString;
  [self.window makeFirstResponder:self.webView];
  [self emitNav:@"navigation.requested" url:url.absoluteString reason:@"Paste and go." private:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

// ── Research Sessions ─────────────────────────────────────────────────────────
- (NSString *)promptForSessionName:(NSString *)title existing:(BOOL)allowExisting {
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=title;
  a.informativeText=allowExisting?@"Enter a name (existing session will be appended to).":@"Enter a new session name.";
  NSTextField *tf=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,260,24)];
  tf.placeholderString=@"My Research";
  // Pre-fill with the first session name if any exist
  if (allowExisting && [BBResearchStore shared].sessions.count)
    tf.stringValue=[BBResearchStore shared].sessions.lastObject.name;
  a.accessoryView=tf;
  [a addButtonWithTitle:@"Add"]; [a addButtonWithTitle:@"Cancel"];
  [a layout]; [[a window] makeFirstResponder:tf]; [tf selectAll:nil];
  NSModalResponse rc=[a runModal];
  if (rc!=NSAlertFirstButtonReturn) return nil;
  return [tf.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
- (void)addCurrentTabToSession:(id)s {
  NSString *url=self.webView.URL.absoluteString;
  if (!url.length||[self isInternalURL:url]) { NSBeep(); return; }
  NSString *name=[self promptForSessionName:@"Add to Research Session" existing:YES];
  if (!name.length) return;
  BBResearchSession *sess=[[BBResearchStore shared] sessionNamed:name create:YES];
  BBResearchItem *it=[BBResearchItem new];
  it.urlString=url; it.title=self.activeTab.title.length?self.activeTab.title:url;
  it.note=@""; it.status=BBResearchStatusUnread; it.addedAt=[NSDate date];
  [sess.items addObject:it]; [[BBResearchStore shared] save];
  BBLog([NSString stringWithFormat:@"[research] added %@ to %@",url,name]);
}
- (void)collectAllTabsToSession:(id)s {
  NSString *name=[self promptForSessionName:@"Collect All Tabs to Session" existing:YES];
  if (!name.length) return;
  BBResearchSession *sess=[[BBResearchStore shared] sessionNamed:name create:YES];
  NSInteger added=0;
  for (BBTab *t in self.tabs) {
    NSString *url=t.suspended?t.suspendedURL:t.webView.URL.absoluteString;
    if (!url.length||[self isInternalURL:url]) continue;
    // Deduplicate within session
    BOOL dup=NO; for (BBResearchItem *x in sess.items) if ([x.urlString isEqualToString:url]) { dup=YES; break; }
    if (dup) continue;
    BBResearchItem *it=[BBResearchItem new];
    it.urlString=url; it.title=t.title.length?t.title:url;
    it.note=@""; it.status=BBResearchStatusUnread; it.addedAt=[NSDate date];
    [sess.items addObject:it]; added++;
  }
  [[BBResearchStore shared] save];
  NSAlert *ok=[[NSAlert alloc]init];
  ok.messageText=[NSString stringWithFormat:@"%ld tab%@ added to \"%@\"", (long)added, added==1?@"":@"s", name];
  ok.informativeText=@"Open Research Sessions to review, annotate, or hand off to an agent.";
  [ok addButtonWithTitle:@"Open Sessions"]; [ok addButtonWithTitle:@"Suspend Tabs"]; [ok addButtonWithTitle:@"Done"];
  NSModalResponse rc=[ok runModal];
  if (rc==NSAlertFirstButtonReturn) [self openResearchManager:nil];
  else if (rc==NSAlertSecondButtonReturn) [self suspendInactiveTabs:nil]; // suspend all idle tabs now
}
- (void)openResearchManager:(id)s {
  CGFloat W=900, H=540;
  NSWindow *rw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,W,H)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable)
    backing:NSBackingStoreBuffered defer:YES];
  rw.releasedWhenClosed=NO; rw.title=@"Research Sessions"; [rw center];
  NSView *cv=rw.contentView;

  // Left: session list
  NSScrollView *sessScroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,48,200,H-48)];
  sessScroll.autoresizingMask=NSViewHeightSizable; sessScroll.hasVerticalScroller=YES;
  NSTableView *sessTV=[[NSTableView alloc]init]; sessTV.rowHeight=28; sessTV.headerView=nil;
  NSTableColumn *sc=[[NSTableColumn alloc]initWithIdentifier:@"s"]; sc.width=198;
  [sessTV addTableColumn:sc]; sessScroll.documentView=sessTV;
  [cv addSubview:sessScroll];

  // Right: item list (status col is clickable to cycle ☐→…→✓→✗)
  NSScrollView *itemScroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(200,48,W-200,H-48)];
  itemScroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; itemScroll.hasVerticalScroller=YES;
  NSTableView *itemTV=[[NSTableView alloc]init]; itemTV.rowHeight=32; itemTV.usesAlternatingRowBackgroundColors=YES;
  for (NSArray *col in @[@[@"status",@"S",@42],@[@"title",@"Title",@420],@[@"url",@"URL",@220]]) {
    NSTableColumn *c=[[NSTableColumn alloc]initWithIdentifier:col[0]];
    c.width=[col[2] doubleValue]; c.title=col[1];
    c.resizingMask=NSTableColumnUserResizingMask|NSTableColumnAutoresizingMask;
    [itemTV addTableColumn:c];
  }
  itemScroll.documentView=itemTV; [cv addSubview:itemScroll];

  // Toolbar buttons at bottom — left: session ops; right: item ops
  void(^btn)(NSString*,NSRect,SEL)=^(NSString*t,NSRect r,SEL a){
    NSButton *b=[[NSButton alloc]initWithFrame:r]; b.title=t; b.bezelStyle=NSBezelStyleRounded;
    b.target=self; b.action=a; [cv addSubview:b];
  };
  btn(@"New Session",     NSMakeRect(8,   10,110,28), @selector(researchNewSession:));
  btn(@"Delete Session",  NSMakeRect(126, 10,110,28), @selector(researchDeleteSession:));
  btn(@"Export Markdown", NSMakeRect(244, 10,130,28), @selector(researchExportMarkdown:));
  btn(@"Hand to Agent",   NSMakeRect(382, 10,120,28), @selector(researchHandToAgent:));
  btn(@"Dismiss",         NSMakeRect(510, 10,100,28), @selector(researchDismissItem:));
  btn(@"Mark Done",       NSMakeRect(618, 10,100,28), @selector(researchMarkDone:));
  btn(@"Open Selected",   NSMakeRect(726, 10,130,28), @selector(researchOpenSelected:));

  // Wiring via associated objects: store the two table views on the window so action handlers can reach them
  objc_setAssociatedObject(rw, "sessTV", sessTV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(rw, "itemTV", itemTV, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(rw, "rw", rw, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // keep rw alive

  BBResearchManagerDS *ds=[[BBResearchManagerDS alloc] initWithWindow:rw delegate:self];
  sessTV.dataSource=ds; sessTV.delegate=ds;
  itemTV.dataSource=ds; itemTV.delegate=ds;
  // Double-click any item row → open in new tab; single-click on status col → cycle status
  itemTV.target=ds;
  itemTV.doubleAction=@selector(openItemDoubleClick:);
  itemTV.action=@selector(itemTableClicked:);
  objc_setAssociatedObject(rw, "ds", ds, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  [rw makeKeyAndOrderFront:nil];
}
// Stubs called by research manager buttons — delegate to the DS which has the state
- (void)researchNewSession:(id)s {
  NSString *name=[self promptForSessionName:@"New Research Session" existing:NO];
  if (!name.length) return;
  [[BBResearchStore shared] sessionNamed:name create:YES];
  // Reload whichever research window is key
  NSWindow *rw=[[NSApp keyWindow] isKindOfClass:[NSWindow class]]?[NSApp keyWindow]:nil;
  NSTableView *sessTV=objc_getAssociatedObject(rw,"sessTV");
  [sessTV reloadData];
}
- (void)researchDeleteSession:(id)s {
  NSWindow *rw=[NSApp keyWindow];
  NSTableView *sessTV=objc_getAssociatedObject(rw,"sessTV");
  NSInteger row=sessTV.selectedRow;
  if (row<0||row>=(NSInteger)[BBResearchStore shared].sessions.count) return;
  [[BBResearchStore shared].sessions removeObjectAtIndex:row];
  [[BBResearchStore shared] save]; [sessTV reloadData];
}
- (void)researchExportMarkdown:(id)s {
  NSWindow *rw=[NSApp keyWindow];
  NSTableView *sessTV=objc_getAssociatedObject(rw,"sessTV");
  NSInteger row=sessTV.selectedRow;
  NSArray *sessions=[BBResearchStore shared].sessions;
  if (row<0||row>=(NSInteger)sessions.count) return;
  BBResearchSession *sess=sessions[row];
  NSSavePanel *sp=[NSSavePanel savePanel];
  sp.nameFieldStringValue=[NSString stringWithFormat:@"%@.md",sess.name];
  sp.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"md"]];
  [sp beginSheetModalForWindow:rw completionHandler:^(NSModalResponse rc){
    if (rc!=NSModalResponseOK) return;
    [[sess exportMarkdown] writeToURL:sp.URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }];
}
- (void)researchHandToAgent:(id)s {
  NSWindow *rw=[NSApp keyWindow];
  NSTableView *sessTV=objc_getAssociatedObject(rw,"sessTV");
  NSInteger row=sessTV.selectedRow;
  NSArray *sessions=[BBResearchStore shared].sessions;
  if (row<0||row>=(NSInteger)sessions.count) return;
  BBResearchSession *sess=sessions[row];
  NSMutableArray *urls=[NSMutableArray array];
  for (BBResearchItem *it in sess.items)
    if (it.status==BBResearchStatusUnread) [urls addObject:it.urlString];
  BBProposeAction(@"research_session_hand_off",@"research",
    [NSString stringWithFormat:@"Research %ld URLs in \"%@\"",(long)urls.count,sess.name],
    [urls firstObject]?:@"",@"low",@"hold",YES,
    [NSString stringWithFormat:@"Agent: summarize and triage %ld URLs from research session \"%@\".",(long)urls.count,sess.name]);
  NSAlert *ok=[[NSAlert alloc]init];
  ok.messageText=@"Research Session Queued";
  ok.informativeText=[NSString stringWithFormat:@"%ld unread URLs from \"%@\" proposed to the agent.",(long)urls.count,sess.name];
  [ok addButtonWithTitle:@"OK"]; [ok runModal];
}
- (void)researchOpenSelected:(id)s {
  NSWindow *rw=[NSApp keyWindow];
  NSTableView *sessTV=objc_getAssociatedObject(rw,"sessTV");
  NSTableView *itemTV=objc_getAssociatedObject(rw,"itemTV");
  NSInteger srow=sessTV.selectedRow, irow=itemTV.selectedRow;
  NSArray *sessions=[BBResearchStore shared].sessions;
  if (srow<0||srow>=(NSInteger)sessions.count) return;
  BBResearchSession *sess=sessions[srow];
  if (irow<0||irow>=(NSInteger)sess.items.count) return;
  BBResearchItem *it=sess.items[irow];
  NSURL *u=[NSURL URLWithString:it.urlString]; if(!u) return;
  it.status=BBResearchStatusReading; [[BBResearchStore shared] save]; [itemTV reloadData];
  [self addTabPrivate:NO]; [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}
- (void)researchURLNotification:(NSNotification *)n {
  NSString *urlStr=n.userInfo[@"url"]; if (!urlStr.length) return;
  NSURL *u=[NSURL URLWithString:urlStr]; if (!u) return;
  [self addTabPrivate:NO];
  [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}
- (void)researchMarkDone:(id)s {
  NSWindow *rw=[NSApp keyWindow];
  NSTableView *sessTV=objc_getAssociatedObject(rw,"sessTV");
  NSTableView *itemTV=objc_getAssociatedObject(rw,"itemTV");
  NSInteger srow=sessTV.selectedRow, irow=itemTV.selectedRow;
  NSArray *sessions=[BBResearchStore shared].sessions;
  if (srow<0||srow>=(NSInteger)sessions.count||irow<0) return;
  BBResearchSession *sess=sessions[srow];
  if (irow>=(NSInteger)sess.items.count) return;
  sess.items[irow].status=BBResearchStatusDone;
  [[BBResearchStore shared] save]; [itemTV reloadData];
}
- (void)researchDismissItem:(id)s {
  NSWindow *rw=[NSApp keyWindow];
  NSTableView *sessTV=objc_getAssociatedObject(rw,"sessTV");
  NSTableView *itemTV=objc_getAssociatedObject(rw,"itemTV");
  NSInteger srow=sessTV.selectedRow, irow=itemTV.selectedRow;
  NSArray *sessions=[BBResearchStore shared].sessions;
  if (srow<0||srow>=(NSInteger)sessions.count||irow<0) return;
  BBResearchSession *sess=sessions[srow];
  if (irow>=(NSInteger)sess.items.count) return;
  sess.items[irow].status=BBResearchStatusDismissed;
  [[BBResearchStore shared] save]; [itemTV reloadData];
}

- (void)newTab:(id)s              { [self addTabPrivate:NO]; }
- (void)newPrivateTab:(id)s       { [self addTabPrivate:YES]; }
- (void)newWindow:(id)s {
  BBDelegate *w=[[BBDelegate alloc]init];
  NSNotification *dummy=[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp];
  [w applicationDidFinishLaunching:dummy];
}
- (void)newPrivateWindow:(id)s {
  BBDelegate *w=[[BBDelegate alloc]init];
  NSNotification *dummy=[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp];
  [w applicationDidFinishLaunching:dummy];
  [w addTabPrivate:YES];
}
- (void)moveTabLeft:(id)s {
  NSInteger i=self.activeTabIndex; if (i<=0||self.tabs.count<2) return;
  [self.tabs exchangeObjectAtIndex:i withObjectAtIndex:i-1];
  self.activeTabIndex=i-1; [self reloadTabBar];
}
- (void)moveTabRight:(id)s {
  NSInteger i=self.activeTabIndex; if (i>=(NSInteger)self.tabs.count-1||self.tabs.count<2) return;
  [self.tabs exchangeObjectAtIndex:i withObjectAtIndex:i+1];
  self.activeTabIndex=i+1; [self reloadTabBar];
}

// ── Tab Search (Cmd+Shift+A) ──────────────────────────────────────────────────
- (void)openTabSearch:(id)s {
  NSPanel *p=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,480,320)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskFullSizeContentView)
    backing:NSBackingStoreBuffered defer:YES];
  p.title=@"Search Tabs"; p.titlebarAppearsTransparent=YES; p.movableByWindowBackground=YES;
  [p center]; p.releasedWhenClosed=NO;
  NSView *cv=p.contentView;

  NSSearchField *sf=[[NSSearchField alloc]initWithFrame:NSMakeRect(12,274,456,28)];
  sf.placeholderString=@"Search open tabs…"; sf.autoresizingMask=NSViewWidthSizable;
  [cv addSubview:sf];

  NSScrollView *sc=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,480,268)];
  sc.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; sc.hasVerticalScroller=YES; sc.drawsBackground=NO;
  NSTableView *tv=[[NSTableView alloc]init]; tv.headerView=nil; tv.rowHeight=38; tv.selectionHighlightStyle=NSTableViewSelectionHighlightStyleSourceList;
  NSTableColumn *tc=[[NSTableColumn alloc]initWithIdentifier:@"t"]; tc.width=458; [tv addTableColumn:tc];
  sc.documentView=tv; [cv addSubview:sc];

  NSMutableArray *filtered=[NSMutableArray arrayWithArray:self.tabs];
  objc_setAssociatedObject(self,"tabSearchFiltered",filtered,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self,"tabSearchPanel",p,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(p,"tv",tv,OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  tv.dataSource=(id<NSTableViewDataSource>)self;
  tv.delegate=(id<NSTableViewDelegate>)self;
  sf.delegate=(id<NSSearchFieldDelegate>)self;
  tv.tag=0xCAFE; // sentinel to identify tab-search table
  sf.tag=0xCAFE;
  tv.doubleAction=@selector(tabSearchConfirm:); tv.target=self;
  [p makeKeyAndOrderFront:nil];
  [p makeFirstResponder:sf];
}
// Called when user presses Return or double-clicks a row in the tab search table
- (void)tabSearchConfirm:(id)s {
  NSPanel *p=(NSPanel *)objc_getAssociatedObject(self,"tabSearchPanel");
  NSTableView *tv=objc_getAssociatedObject(p,"tv");
  NSArray *filtered=objc_getAssociatedObject(self,"tabSearchFiltered");
  NSInteger row=tv.selectedRow; if (row<0||(NSUInteger)row>=filtered.count) return;
  BBTab *tab=filtered[row];
  NSInteger idx=[self.tabs indexOfObject:tab];
  if (idx!=NSNotFound) { [self activateTab:idx]; [self reloadTabBar]; }
  [p orderOut:nil];
  objc_setAssociatedObject(self,"tabSearchPanel",nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self,"tabSearchFiltered",nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// NSTableViewDataSource for tab search (detected via tag)
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
  if (tv.tag==0xCAFE) {
    NSArray *f=objc_getAssociatedObject(self,"tabSearchFiltered");
    return (NSInteger)(f?f.count:0);
  }
  return 0;
}
// NSTableViewDelegate for tab search
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  if (tv.tag!=0xCAFE) return nil;
  NSArray *filtered=objc_getAssociatedObject(self,"tabSearchFiltered");
  if (row<0||(NSUInteger)row>=filtered.count) return nil;
  BBTab *tab=filtered[row];
  NSTableCellView *cell=[tv makeViewWithIdentifier:@"TSC" owner:nil];
  if (!cell) {
    cell=[[NSTableCellView alloc]initWithFrame:NSMakeRect(0,0,456,36)];
    cell.identifier=@"TSC";
    NSImageView *iv=[[NSImageView alloc]initWithFrame:NSMakeRect(8,10,16,16)];
    iv.imageScaling=NSImageScaleProportionallyUpOrDown; iv.tag=1; [cell addSubview:iv];
    NSTextField *title=[[NSTextField alloc]initWithFrame:NSMakeRect(32,17,410,16)];
    title.bordered=NO; title.editable=NO; title.selectable=NO; title.backgroundColor=[NSColor clearColor];
    title.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]; title.lineBreakMode=NSLineBreakByTruncatingTail; title.tag=2; [cell addSubview:title];
    NSTextField *url=[[NSTextField alloc]initWithFrame:NSMakeRect(32,3,410,13)];
    url.bordered=NO; url.editable=NO; url.selectable=NO; url.backgroundColor=[NSColor clearColor];
    url.textColor=[NSColor secondaryLabelColor]; url.font=[NSFont systemFontOfSize:11]; url.lineBreakMode=NSLineBreakByTruncatingMiddle; url.tag=3; [cell addSubview:url];
  }
  ((NSImageView *)[cell viewWithTag:1]).image=tab.favicon;
  ((NSTextField *)[cell viewWithTag:2]).stringValue=tab.title?:@"";
  NSString *u=tab.suspended?tab.suspendedURL:tab.webView.URL.absoluteString;
  ((NSTextField *)[cell viewWithTag:3]).stringValue=u?:@"";
  return cell;
}
// ── Camera / Mic permission prompt (with per-host persistence) ───────────────
- (void)webView:(WKWebView *)wv
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    type:(WKMediaCaptureType)type
    decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {
  NSString *kind = (type==WKMediaCaptureTypeMicrophone)?@"microphone":
                   (type==WKMediaCaptureTypeCamera)?@"camera":@"camera & microphone";
  // Check persisted decision for this host+kind
  NSString *prefKey=[NSString stringWithFormat:@"BBMediaPerm_%@_%@",kind,origin.host];
  NSString *saved=[[NSUserDefaults standardUserDefaults] stringForKey:prefKey];
  if ([saved isEqualToString:@"allow"]) { decisionHandler(WKPermissionDecisionGrant); return; }
  if ([saved isEqualToString:@"deny"])  { decisionHandler(WKPermissionDecisionDeny);  return; }
  // First-time prompt
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[NSString stringWithFormat:@"\"%@\" wants to use your %@", origin.host, kind];
  a.informativeText=@"";
  [a addButtonWithTitle:@"Allow"]; [a addButtonWithTitle:@"Deny"];
  // "Remember this decision" checkbox
  NSButton *remember=[[NSButton alloc]initWithFrame:NSMakeRect(0,0,260,18)];
  remember.buttonType=NSButtonTypeSwitch; remember.title=@"Remember for this site";
  remember.state=NSControlStateValueOn; a.accessoryView=remember;
  a.alertStyle=NSAlertStyleWarning;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){
    BOOL granted=(r==NSAlertFirstButtonReturn);
    if (remember.state==NSControlStateValueOn)
      [[NSUserDefaults standardUserDefaults] setObject:granted?@"allow":@"deny" forKey:prefKey];
    decisionHandler(granted ? WKPermissionDecisionGrant : WKPermissionDecisionDeny);
  }];
}

// ── Search engine preference ──────────────────────────────────────────────────
// Thin wrappers over BBSearch (the single source of truth, declared earlier so the
// address dropdown can reach it too).
+ (NSArray<NSDictionary*> *)searchEngines { return [BBSearch engines]; }
+ (NSString *)searchEngineName { return [BBSearch engineName]; }
+ (NSString *)searchURLForQuery:(NSString *)q { return [BBSearch urlForQuery:q]; }
- (void)openNetworkMonitor:(id)s { [[BBNetworkMapPanel shared] showOrFocus]; }

- (void)settingsAccept:(id)s { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)settingsCancel:(id)s { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (void)pickDownloadDir:(id)s {
  NSOpenPanel *p=[NSOpenPanel openPanel];
  p.canChooseDirectories=YES; p.canChooseFiles=NO; p.allowsMultipleSelection=NO;
  p.title=@"Choose Downloads Folder";
  if ([p runModal]!=NSModalResponseOK || !p.URL) return;
  NSString *path=p.URL.path;
  [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"BBDownloadDir"];
  NSTextField *lbl=(NSTextField *)objc_getAssociatedObject(self,"BBDLPathLabel");
  if (lbl) { NSString *shown=[path stringByAbbreviatingWithTildeInPath]; lbl.stringValue=shown; lbl.toolTip=shown; }
}
- (void)showSiteDataManager:(id)s {
  CGFloat W=620,Hh=460;
  NSWindow *sw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,W,Hh)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:YES];
  sw.releasedWhenClosed=NO; sw.title=@"Site Data & Cookies"; [sw center];
  NSView *cv=sw.contentView;
  NSSearchField *sf=[[NSSearchField alloc]initWithFrame:NSMakeRect(12,Hh-44,W-24,28)];
  sf.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  sf.placeholderString=@"Filter by domain"; [cv addSubview:sf];
  NSScrollView *sv=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,48,W,Hh-100)];
  sv.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; sv.hasVerticalScroller=YES;
  NSTableView *tv=[[NSTableView alloc]init]; tv.rowHeight=24;
  NSTableColumn *cd=[[NSTableColumn alloc]initWithIdentifier:@"domain"]; cd.title=@"Domain"; cd.width=380;
  NSTableColumn *ct=[[NSTableColumn alloc]initWithIdentifier:@"types"];  ct.title=@"Stored data"; ct.width=216;
  [tv addTableColumn:cd]; [tv addTableColumn:ct];
  sv.documentView=tv; [cv addSubview:sv];
  BBSiteDataDS *ds=[[BBSiteDataDS alloc]initWithTableView:tv searchField:sf];
  tv.dataSource=ds; tv.delegate=ds; sf.delegate=ds;
  objc_setAssociatedObject(sw,@"sds",ds,OBJC_ASSOCIATION_RETAIN);
  [ds reload];
  NSButton *rm=[[NSButton alloc]initWithFrame:NSMakeRect(12,10,160,30)];
  rm.title=@"Remove Selected"; rm.bezelStyle=NSBezelStyleRounded; rm.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  rm.target=ds; rm.action=@selector(removeSelected); [cv addSubview:rm];
  NSButton *rmAll=[[NSButton alloc]initWithFrame:NSMakeRect(180,10,140,30)];
  rmAll.title=@"Remove All…"; rmAll.bezelStyle=NSBezelStyleRounded; rmAll.autoresizingMask=NSViewMaxXMargin|NSViewMaxYMargin;
  rmAll.target=ds; rmAll.action=@selector(removeAll); [cv addSubview:rmAll];
  NSButton *done=[[NSButton alloc]initWithFrame:NSMakeRect(W-102,10,90,30)];
  done.title=@"Done"; done.bezelStyle=NSBezelStyleRounded; done.keyEquivalent=@"\r"; done.autoresizingMask=NSViewMinXMargin|NSViewMaxYMargin;
  done.target=sw; done.action=@selector(performClose:); [cv addSubview:done];
  [self.window beginSheet:sw completionHandler:nil];
}
- (void)showProfileEditor:(id)s {
  BBProfile *p=[[BBProfileStore shared] profile];
  CGFloat W=460,Hh=440;
  NSWindow *pw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,W,Hh)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:YES];
  pw.releasedWhenClosed=NO; pw.title=@"Address Profile"; [pw center];
  NSView *cv=pw.contentView;
  NSMutableDictionary<NSString *,NSTextField *> *fields=[NSMutableDictionary dictionary];
  void(^row)(NSString *,NSString *,CGFloat)=^(NSString *lbl,NSString *key,CGFloat yy){
    NSTextField *l=[NSTextField labelWithString:lbl]; l.frame=NSMakeRect(16,yy,108,20);
    l.alignment=NSTextAlignmentRight; [cv addSubview:l];
    NSTextField *t=[[NSTextField alloc]initWithFrame:NSMakeRect(132,yy-2,310,24)];
    NSString *v=[p valueForKey:key]; if (v.length) t.stringValue=v;
    [cv addSubview:t]; fields[key]=t;
  };
  CGFloat y=Hh-50;
  row(@"Name:",@"name",y);          y-=32;
  row(@"Organization:",@"organization",y); y-=32;
  row(@"Email:",@"email",y);        y-=32;
  row(@"Phone:",@"phone",y);        y-=32;
  row(@"Street:",@"street",y);      y-=32;
  row(@"City:",@"city",y);          y-=32;
  row(@"State/Region:",@"region",y); y-=32;
  row(@"Postal code:",@"postal",y); y-=32;
  row(@"Country:",@"country",y);    y-=32;
  NSButton *save=[[NSButton alloc]initWithFrame:NSMakeRect(W-104,16,88,32)];
  save.title=@"Save"; save.bezelStyle=NSBezelStyleRounded; save.keyEquivalent=@"\r";
  objc_setAssociatedObject(save,"BBProfileFields",fields,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  save.target=self; save.action=@selector(saveProfileFromSender:); [cv addSubview:save];
  NSButton *cancel=[[NSButton alloc]initWithFrame:NSMakeRect(W-196,16,88,32)];
  cancel.title=@"Cancel"; cancel.bezelStyle=NSBezelStyleRounded; cancel.keyEquivalent=@"\033";
  cancel.target=pw; cancel.action=@selector(performClose:); [cv addSubview:cancel];
  [self.window beginSheet:pw completionHandler:nil];
}
- (void)saveProfileFromSender:(NSButton *)sender {
  NSDictionary<NSString *,NSTextField *> *fields=objc_getAssociatedObject(sender,"BBProfileFields");
  BBProfile *p=[BBProfile new];
  for (NSString *k in fields) [p setValue:fields[k].stringValue forKey:k];
  [[BBProfileStore shared] setProfile:p];
  NSWindow *sheet=sender.window;
  [self.window endSheet:sheet];
}
- (void)showSavedPasswords:(id)s {
  NSArray<BBPasswordEntry *> *entries=[[BBPasswordStore shared] allEntries];
  NSWindow *pw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,520,420)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable)
    backing:NSBackingStoreBuffered defer:YES];
  pw.releasedWhenClosed=NO; pw.title=@"Saved Passwords"; [pw center];
  NSView *cv=pw.contentView;
  NSTextField *hint=[NSTextField labelWithString:
    @"Saved logins live in the macOS Keychain. Open “Keychain Access” to view the password values."];
  hint.frame=NSMakeRect(12,pw.contentView.bounds.size.height-40,496,28);
  hint.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  hint.textColor=[NSColor secondaryLabelColor]; hint.font=[NSFont systemFontOfSize:11];
  hint.maximumNumberOfLines=2; [cv addSubview:hint];
  NSScrollView *sv=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,40,520,pw.contentView.bounds.size.height-80)];
  sv.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; sv.hasVerticalScroller=YES;
  NSTableView *tv=[[NSTableView alloc]init]; tv.rowHeight=26;
  NSTableColumn *c1=[[NSTableColumn alloc]initWithIdentifier:@"site"]; c1.title=@"Site"; c1.width=240;
  NSTableColumn *c2=[[NSTableColumn alloc]initWithIdentifier:@"user"]; c2.title=@"Username"; c2.width=240;
  [tv addTableColumn:c1]; [tv addTableColumn:c2];
  sv.documentView=tv; [cv addSubview:sv];
  // Tiny inline datasource using objc_setAssociatedObject — entries cached on the window.
  BBSavedPasswordsDS *ds=[[BBSavedPasswordsDS alloc]initWithEntries:[entries mutableCopy] tableView:tv];
  tv.dataSource=ds; tv.delegate=ds;
  objc_setAssociatedObject(pw,@"ds",ds,OBJC_ASSOCIATION_RETAIN);
  NSButton *rm=[[NSButton alloc]initWithFrame:NSMakeRect(12,8,100,28)];
  rm.title=@"Remove"; rm.bezelStyle=NSBezelStyleRounded;
  rm.target=ds; rm.action=@selector(removeSelected:); [cv addSubview:rm];
  NSButton *done=[[NSButton alloc]initWithFrame:NSMakeRect(420,8,90,28)];
  done.title=@"Done"; done.bezelStyle=NSBezelStyleRounded; done.keyEquivalent=@"\r";
  done.target=pw; done.action=@selector(performClose:); [cv addSubview:done];
  [self.window beginSheet:pw completionHandler:nil];
}
- (void)clearMediaPermissions:(id)s {
  NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];
  for (NSString *key in [ud.dictionaryRepresentation.allKeys copy])
    if ([key hasPrefix:@"BBMediaPerm_"]) [ud removeObjectForKey:key];
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Site permissions cleared";
  a.informativeText=@"All saved camera and microphone permissions have been reset. Sites will ask again.";
  [a addButtonWithTitle:@"OK"]; [a runModal];
}
- (void)openSearchPreferences:(id)s {
  NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];
  CGFloat W=470,Hh=540;
  NSWindow *sw=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,W,Hh)
    styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:YES];
  sw.releasedWhenClosed=NO; sw.title=@"BearBrowser Settings"; [sw center];
  NSView *cv=sw.contentView;
  NSTextField*(^label)(NSString*,CGFloat)=^NSTextField*(NSString*t,CGFloat yy){
    NSTextField *l=[NSTextField labelWithString:t]; l.frame=NSMakeRect(16,yy,168,20);
    l.alignment=NSTextAlignmentRight; [cv addSubview:l]; return l;
  };
  CGFloat y=Hh-58;
  label(@"Default search engine:",y);
  NSPopUpButton *pop=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(192,y-3,260,26) pullsDown:NO];
  NSString *cur=[ud stringForKey:@"BBSearchEngine"]?:@"ddg";
  for (NSDictionary *e in [BBDelegate searchEngines]) {
    [pop addItemWithTitle:e[@"name"]]; pop.lastItem.representedObject=e[@"id"];
    if ([e[@"id"] isEqualToString:cur]) [pop selectItem:pop.lastItem];
  }
  [cv addSubview:pop]; y-=46;
  label(@"Homepage:",y);
  NSTextField *home=[[NSTextField alloc]initWithFrame:NSMakeRect(192,y-2,260,24)];
  home.stringValue=[ud stringForKey:@"BBHomepage"]?:@""; home.placeholderString=@"Leave blank for the start page";
  [cv addSubview:home]; y-=44;
  NSButton *bmBar=[NSButton checkboxWithTitle:@"Show bookmarks bar" target:nil action:nil];
  bmBar.frame=NSMakeRect(192,y,260,20); bmBar.state=[ud boolForKey:@"BBShowBookmarksBar"]?NSControlStateValueOn:NSControlStateValueOff;
  [cv addSubview:bmBar]; y-=28;
  NSButton *inline_ac=[NSButton checkboxWithTitle:@"Inline autocomplete in address bar" target:nil action:nil];
  inline_ac.frame=NSMakeRect(192,y,280,20);
  inline_ac.state=([ud objectForKey:@"BBInlineAutocomplete"]==nil||[ud boolForKey:@"BBInlineAutocomplete"])?NSControlStateValueOn:NSControlStateValueOff;
  [cv addSubview:inline_ac]; y-=28;
  NSButton *sug=[NSButton checkboxWithTitle:@"Search suggestions (sends typing to the engine)" target:nil action:nil];
  sug.frame=NSMakeRect(192,y,280,20); sug.state=[ud boolForKey:@"BBSearchSuggestions"]?NSControlStateValueOn:NSControlStateValueOff;
  [cv addSubview:sug]; y-=28;
  NSButton *clr=[NSButton checkboxWithTitle:@"Clear history when quitting" target:nil action:nil];
  clr.frame=NSMakeRect(192,y,260,20); clr.state=[ud boolForKey:@"BBClearOnQuit"]?NSControlStateValueOn:NSControlStateValueOff;
  [cv addSubview:clr]; y-=40;
  // Download folder picker (Chrome-style)
  label(@"Downloads folder:",y+4);
  NSString *curDL=[ud stringForKey:@"BBDownloadDir"];
  NSString *shownPath=curDL.length?[curDL stringByAbbreviatingWithTildeInPath]:@"~/Downloads";
  NSTextField *dlPath=[NSTextField labelWithString:shownPath];
  dlPath.frame=NSMakeRect(192,y-2,180,22);
  dlPath.lineBreakMode=NSLineBreakByTruncatingMiddle; dlPath.toolTip=shownPath;
  [cv addSubview:dlPath];
  NSButton *dlPick=[[NSButton alloc]initWithFrame:NSMakeRect(376,y-4,76,26)];
  dlPick.title=@"Choose…"; dlPick.bezelStyle=NSBezelStyleRounded;
  objc_setAssociatedObject(self,"BBDLPathLabel",dlPath,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  dlPick.target=self; dlPick.action=@selector(pickDownloadDir:); [cv addSubview:dlPick];
  y-=40;
  // Site permission management
  label(@"Site permissions:",y+4);
  NSButton *clearPerms=[[NSButton alloc]initWithFrame:NSMakeRect(192,y-2,260,28)];
  clearPerms.title=@"Clear All Media Permissions…"; clearPerms.bezelStyle=NSBezelStyleRounded;
  clearPerms.target=self; clearPerms.action=@selector(clearMediaPermissions:); [cv addSubview:clearPerms];
  y-=38;
  label(@"Saved passwords:",y+4);
  NSButton *pwBtn=[[NSButton alloc]initWithFrame:NSMakeRect(192,y-2,260,28)];
  pwBtn.title=@"Manage Saved Passwords…"; pwBtn.bezelStyle=NSBezelStyleRounded;
  pwBtn.target=self; pwBtn.action=@selector(showSavedPasswords:); [cv addSubview:pwBtn];
  y-=38;
  label(@"Address autofill:",y+4);
  NSButton *prBtn=[[NSButton alloc]initWithFrame:NSMakeRect(192,y-2,260,28)];
  prBtn.title=@"Edit Address Profile…"; prBtn.bezelStyle=NSBezelStyleRounded;
  prBtn.target=self; prBtn.action=@selector(showProfileEditor:); [cv addSubview:prBtn];
  y-=38;
  label(@"Site data:",y+4);
  NSButton *sdBtn=[[NSButton alloc]initWithFrame:NSMakeRect(192,y-2,260,28)];
  sdBtn.title=@"Manage Site Data & Cookies…"; sdBtn.bezelStyle=NSBezelStyleRounded;
  sdBtn.target=self; sdBtn.action=@selector(showSiteDataManager:); [cv addSubview:sdBtn];
  NSButton *save=[[NSButton alloc]initWithFrame:NSMakeRect(W-104,16,88,32)];
  save.title=@"Save"; save.bezelStyle=NSBezelStyleRounded; save.keyEquivalent=@"\r";
  save.target=self; save.action=@selector(settingsAccept:); [cv addSubview:save];
  NSButton *cancel=[[NSButton alloc]initWithFrame:NSMakeRect(W-196,16,88,32)];
  cancel.title=@"Cancel"; cancel.bezelStyle=NSBezelStyleRounded; cancel.keyEquivalent=@"\033";
  cancel.target=self; cancel.action=@selector(settingsCancel:); [cv addSubview:cancel];

  NSModalResponse rc=[NSApp runModalForWindow:sw];
  [sw orderOut:nil];
  if (rc!=NSModalResponseOK) return;
  NSString *eid=pop.selectedItem.representedObject; if(eid)[ud setObject:eid forKey:@"BBSearchEngine"];
  NSString *hp=[home.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (hp.length) [ud setObject:hp forKey:@"BBHomepage"]; else [ud removeObjectForKey:@"BBHomepage"];
  [ud setBool:(bmBar.state==NSControlStateValueOn) forKey:@"BBShowBookmarksBar"];
  [ud setBool:(inline_ac.state==NSControlStateValueOn) forKey:@"BBInlineAutocomplete"];
  [ud setBool:(sug.state==NSControlStateValueOn) forKey:@"BBSearchSuggestions"];
  [ud setBool:(clr.state==NSControlStateValueOn) forKey:@"BBClearOnQuit"];
  // Apply the bookmarks-bar choice immediately.
  self.bookmarksBarVisible=(bmBar.state==NSControlStateValueOn);
  self.bookmarksBar.hidden=!self.bookmarksBarVisible;
  if (self.bookmarksBarVisible) [self reloadBookmarksBar];
  [self resizeWebViewForCurrentTab];
}

// ── Quad9 DNS-based safe browsing ────────────────────────────────────────────
// Queries Quad9 DoH (9.9.9.9) for the domain. Quad9 returns NXDOMAIN for known
// malware/phishing hosts. We treat NXDOMAIN as a blocked domain and show a
// warning page. Results cached (TTL 10 min) to avoid latency on every click.
- (void)checkQuad9:(NSString *)host completion:(void(^)(BOOL blocked))done {
  if (!host.length) { done(NO); return; }
  NSString *cacheKey=[NSString stringWithFormat:@"q9:%@",host];
  NSNumber *cached=[self.dnsBlockCache objectForKey:cacheKey];
  if (cached) { done(cached.boolValue); return; }
  NSString *dohURL=[NSString stringWithFormat:
    @"https://dns.quad9.net/dns-query?name=%@&type=A",
    [host stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
  NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:dohURL]
    cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:4.0];
  [req setValue:@"application/dns-json" forHTTPHeaderField:@"Accept"];
  NSURLSessionDataTask *task=[[NSURLSession sharedSession] dataTaskWithRequest:req
    completionHandler:^(NSData *data,NSURLResponse *resp,NSError *err){
      BOOL blocked=NO;
      if (!err && data) {
        NSDictionary *j=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        // Quad9 sets Status=3 (NXDOMAIN) for blocked domains
        NSNumber *status=j[@"Status"];
        blocked = (status && status.intValue==3);
      }
      // Cache result for 10 minutes
      [self.dnsBlockCache setObject:@(blocked) forKey:cacheKey];
      // Schedule eviction after TTL
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(600*NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_BACKGROUND,0),^{
          [self.dnsBlockCache removeObjectForKey:cacheKey];
        });
      dispatch_async(dispatch_get_main_queue(),^{ done(blocked); });
    }];
  [task resume];
}
- (void)showThreatWarning:(NSString *)host webView:(WKWebView *)wv blockedURL:(NSURL *)url {
  NSString *html=[NSString stringWithFormat:
    @"<!doctype html><html><head><meta charset='utf-8'>"
    @"<style>body{font-family:-apple-system,sans-serif;display:flex;align-items:center;"
    @"justify-content:center;min-height:100vh;margin:0;background:#1c1c1e;color:#f5f5f7;}"
    @".card{max-width:520px;padding:40px;background:#2c2c2e;border-radius:16px;"
    @"border:1px solid rgba(255,0,60,.3);text-align:center;}"
    @".icon{font-size:48px;margin-bottom:16px;}"
    @"h1{font-size:22px;font-weight:600;color:#ff3b30;margin:0 0 12px;}"
    @"p{font-size:15px;color:#98989d;line-height:1.6;margin:0 0 24px;}"
    @".host{color:#f5f5f7;font-weight:500;}"
    @"button{padding:10px 24px;border-radius:10px;border:none;font-size:14px;"
    @"cursor:pointer;margin:0 6px;}"
    @".back{background:#1b6b45;color:#fff;}"
    @".proceed{background:rgba(255,255,255,.08);color:#98989d;}</style></head>"
    @"<body><div class='card'>"
    @"<div class='icon'>⚠️</div>"
    @"<h1>Threat Detected</h1>"
    @"<p>Quad9 (9.9.9.9) has flagged <span class='host'>%@</span> as a known malware or phishing site. "
    @"Your connection was blocked before any data was sent.</p>"
    @"<button class='back' onclick='history.back()'>Go back to safety</button>"
    @"<button class='proceed' onclick='window.webkit.messageHandlers.navigate.postMessage(\"force:%@\")'>Proceed anyway</button>"
    @"</div></body></html>", host,
    [url.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
  [wv loadHTMLString:html baseURL:nil];
}
- (void)closeCurrentTab:(id)s     { [self tabItemDidClose:self.activeTabIndex]; }
- (void)reopenClosedTab:(id)s     {
  if (!self.recentlyClosed.count) return;
  NSDictionary *e=[self.recentlyClosed lastObject]; [self.recentlyClosed removeLastObject];
  [self insertTabAt:self.activeTabIndex+1 private:NO url:e[@"url"]];
}
// Reopen a specific entry chosen from the History ▸ Recently Closed submenu.
- (void)reopenSpecificClosed:(NSMenuItem *)s {
  NSInteger idx=s.tag; if (idx<0||idx>=(NSInteger)self.recentlyClosed.count) return;
  NSDictionary *e=self.recentlyClosed[idx];
  [self.recentlyClosed removeObjectAtIndex:idx];
  [self insertTabAt:self.activeTabIndex+1 private:NO url:e[@"url"]];
}
// Populate History ▸ Recently Closed when it opens (newest first).
- (void)menuNeedsUpdate:(NSMenu *)menu {
  if (![menu.title isEqualToString:@"Recently Closed"]) return;
  [menu removeAllItems];
  if (!self.recentlyClosed.count) {
    [menu addItemWithTitle:@"No Recently Closed Tabs" action:nil keyEquivalent:@""].enabled=NO;
    return;
  }
  for (NSInteger k=(NSInteger)self.recentlyClosed.count-1;k>=0;k--) {
    NSDictionary *e=self.recentlyClosed[k];
    NSString *t=e[@"title"]; if(!t.length) t=e[@"url"];
    if (t.length>60) t=[[t substringToIndex:57] stringByAppendingString:@"…"];
    NSMenuItem *it=[menu addItemWithTitle:t action:@selector(reopenSpecificClosed:) keyEquivalent:@""];
    it.target=self; it.tag=k; it.toolTip=e[@"url"];
  }
}
- (void)nextTab:(id)s { NSInteger n=self.tabs.count; if(n<2)return; [self tabItemDidSelect:(self.activeTabIndex+1)%n]; }
- (void)prevTab:(id)s { NSInteger n=self.tabs.count; if(n<2)return; [self tabItemDidSelect:(self.activeTabIndex-1+n)%n]; }
- (void)switchToTabByMenuItem:(NSMenuItem *)item {
  NSInteger idx=item.tag;
  if (idx==8) idx=(NSInteger)self.tabs.count-1; // Cmd+9 = last tab (Chrome behavior)
  if (idx>=0&&idx<(NSInteger)self.tabs.count) [self tabItemDidSelect:idx];
}
- (void)focusAddressBar:(id)s { [self.window makeFirstResponder:self.address]; [self.address selectText:nil]; }
- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)msg {
  if ([msg.name isEqualToString:@"focusAddress"]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.window makeFirstResponder:self.address];
      [self.address selectText:nil];
    });
  } else if ([msg.name isEqualToString:@"navigate"]) {
    NSString *input=[msg.body isKindOfClass:[NSString class]]?msg.body:@"";
    input=[input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!input.length) return;
    // Block any attempt by page JS to navigate to dangerous schemes via this bridge
    NSString *inputLower=input.lowercaseString;
    if ([inputLower hasPrefix:@"javascript:"]||[inputLower hasPrefix:@"view-source:"]||
        [inputLower hasPrefix:@"webkit-"]||[inputLower hasPrefix:@"x-webkit"]||
        [inputLower hasPrefix:@"file:"]||[inputLower hasPrefix:@"data:"]) return; // pages can't drive local/data nav via the bridge
    // force: prefix bypasses Quad9 block (user explicitly clicked "Proceed anyway")
    BOOL forceNav=[input hasPrefix:@"force:"];
    if (forceNav) input=[input substringFromIndex:6];
    input=[input stringByRemovingPercentEncoding]?:input;
    dispatch_async(dispatch_get_main_queue(), ^{
      self.address.stringValue=input;
      BOOL hasScheme=[input hasPrefix:@"http://"]||[input hasPrefix:@"https://"]||[input hasPrefix:@"file://"];
      BOOL looksLikeHost=[input rangeOfString:@" "].location==NSNotFound&&[input rangeOfString:@"."].location!=NSNotFound;
      NSURL *url=nil;
      if (hasScheme)          url=[NSURL URLWithString:input];
      else if (looksLikeHost) url=[NSURL URLWithString:[@"https://" stringByAppendingString:input]];
      else {
        NSString *q=[input stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        url=[NSURL URLWithString:[BBDelegate searchURLForQuery:input]];
      }
      if (url) {
        if (forceNav) {
          // Bypass cache entry so Quad9 check doesn't re-block immediately
          NSString *ck=[NSString stringWithFormat:@"q9:%@",url.host?:@""];
          [self.dnsBlockCache setObject:@NO forKey:ck];
        }
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
      }
      [self.window makeFirstResponder:self.webView];
    });
  } else if ([msg.name isEqualToString:@"honeypot"]) {
    NSDictionary *body=[msg.body isKindOfClass:[NSDictionary class]]?msg.body:@{};
    NSString *trap=body[@"trap"]?:@"unknown";
    NSString *url=body[@"url"]?:@"";
    BBLog([NSString stringWithFormat:@"[HONEYPOT] trap=%@ url=%@",trap,url]);
    BBEmitEvent(@"security.honeypot_triggered",@"alert",
      [NSString stringWithFormat:@"Canary '%@' accessed on %@",trap,url],
      @{@"trap":trap,@"url":url,@"time":@([body[@"time"] doubleValue])});
  } else if ([msg.name isEqualToString:@"netmon"]) {
    BBTab *src=[self tabForWebView:msg.webView];
    if (src.isPrivate) return; // don't log private-tab connections to the network monitor
    NSDictionary *body=[msg.body isKindOfClass:[NSDictionary class]]?msg.body:@{};
    NSString *domain=body[@"domain"]?:@"";
    NSString *page=body[@"page"]?:@"";
    NSString *type=body[@"type"]?:@"";
    if(!domain.length) return;
    BBFirewallDecision fw=[BBFirewall.shared decisionFor:[BBConnectionRecord etldForHost:domain]];
    BOOL blocked=(fw==BBFWBlock);
    [BBNetworkMonitor.shared record:domain page:page type:type blocked:blocked];
    BBNetworkRecord_push(domain,page,type,blocked);
  } else if ([msg.name isEqualToString:@"secmon"]) {
    NSDictionary *body=[msg.body isKindOfClass:[NSDictionary class]]?msg.body:@{};
    NSString *type=body[@"type"]?:@"";
    NSString *page=body[@"page"]?:@"";
    NSString *detail=body[@"detail"]?:@"";
    if (!type.length) return;
    BBSecSeverity sev=BBSecClassify(type,detail);
    [BBSecurityMonitor.shared record:type page:page detail:detail severity:sev];
    if (sev>=BBSecHigh)
      BBEmitEvent([NSString stringWithFormat:@"security.%@",type],@"alert",
        [NSString stringWithFormat:@"[%@] %@: %.200@",page,type,detail],
        @{@"type":type,@"page":page});
    [[BBSecurityPanel shared] pushEvent:[BBSecurityMonitor.shared snapshot].lastObject];
  } else if ([msg.name isEqualToString:@"historynav"]) {
    // SPA route changes (pushState/replaceState/popstate) never fire
    // didFinishNavigation, so record them here so in-app navigation on sites like
    // Gmail/YouTube actually lands in history. The title KVO patches the title.
    WKWebView *wv=msg.webView; if (wv!=self.webView) return;
    BBTab *tab=[self tabForWebView:wv]; if (!tab||tab.isPrivate) return;
    NSString *url=[msg.body isKindOfClass:[NSString class]]?msg.body:(wv.URL.absoluteString?:@"");
    if (!url.length) return;
    dispatch_async(dispatch_get_main_queue(),^{
      if (wv==self.webView) self.address.stringValue=[self isInternalURL:url]?@"":url;
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
      [[BBHistoryStore shared] recordTitle:wv.title?:@"" url:url];
    });
  } else if ([msg.name isEqualToString:@"hoverlink"]) {
    if (msg.webView!=self.webView) return;
    NSString *url=[msg.body isKindOfClass:[NSString class]]?msg.body:@"";
    dispatch_async(dispatch_get_main_queue(),^{ [self showStatus:url]; });
  } else if ([msg.name isEqualToString:@"audiostate"]) {
    BBTab *tab=[self tabForWebView:msg.webView]; if (!tab) return;
    BOOL playing=[[msg.body isKindOfClass:[NSNumber class]]?(NSNumber*)msg.body:@0 boolValue];
    if (tab.isPlayingAudio!=playing) {
      tab.isPlayingAudio=playing;
      dispatch_async(dispatch_get_main_queue(),^{ [self reloadTabBar]; });
    }
  } else if ([msg.name isEqualToString:@"loginform"]) {
    NSDictionary *m=[msg.body isKindOfClass:[NSDictionary class]]?(NSDictionary *)msg.body:@{};
    NSString *kind=m[@"k"]; NSDictionary *body=m[@"b"]; WKWebView *wv=msg.webView;
    if (![kind isKindOfClass:[NSString class]]||![body isKindOfClass:[NSDictionary class]]) return;
    BBTab *tab=[self tabForWebView:wv];
    // Never autofill/save inside a private tab — private mode should be hands-off.
    if (tab.isPrivate) return;
    if ([kind isEqualToString:@"save"]) {
      NSString *host=body[@"host"], *user=body[@"user"], *pass=body[@"pass"];
      if (![host isKindOfClass:[NSString class]]||![user isKindOfClass:[NSString class]]||![pass isKindOfClass:[NSString class]]) return;
      if (!host.length||!user.length||!pass.length) return;
      // De-dupe: skip the prompt when an identical (host,user,pass) is already saved.
      NSArray<BBPasswordEntry *> *existing=[[BBPasswordStore shared] entriesForHost:host];
      for (BBPasswordEntry *e in existing) if ([e.username isEqualToString:user]&&[e.password isEqualToString:pass]) return;
      dispatch_async(dispatch_get_main_queue(),^{ [self offerSaveLoginForHost:host username:user password:pass]; });
    } else if ([kind isEqualToString:@"editFocus"]) {
      BOOL e=[body[@"e"] boolValue];
      if (tab) tab.editableFocus=e;
    } else if ([kind isEqualToString:@"profileLookup"]) {
      BBProfile *p=[[BBProfileStore shared] profile];
      if (p.isEmpty) return;
      // Silently fill — same UX as Chrome's autofill once the profile is set.
      // No prompt: any field with existing value is skipped client-side.
      NSDictionary *d=[p toDict];
      NSData *jsonD=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
      NSString *json=[[NSString alloc]initWithData:jsonD encoding:NSUTF8StringEncoding];
      if (!json.length) return;
      NSString *js=[NSString stringWithFormat:
        @"if(typeof window.__bbApplyProfile==='function')window.__bbApplyProfile(%@);",json];
      dispatch_async(dispatch_get_main_queue(),^{ [wv evaluateJavaScript:js completionHandler:nil]; });
    } else if ([kind isEqualToString:@"genpassOffer"]) {
      // Focus on an autocomplete=new-password field — offer to generate one,
      // but only the first time per page load to avoid prompt-spam on refocus.
      if (tab.genpassOffered) return;
      tab.genpassOffered=YES;
      NSString *host=body[@"host"]?:@"";
      dispatch_async(dispatch_get_main_queue(),^{ [self offerGenPassForHost:host webView:wv]; });
    } else if ([kind isEqualToString:@"lookup"]) {
      NSString *host=body[@"host"]; if (![host isKindOfClass:[NSString class]]||!host.length) return;
      NSArray<BBPasswordEntry *> *entries=[[BBPasswordStore shared] entriesForHost:host];
      if (!entries.count) return;
      dispatch_async(dispatch_get_main_queue(),^{ [self offerFillForTab:tab webView:wv entries:entries]; });
    }
  }
}
static void BBNetworkRecord_push(NSString*domain,NSString*page,NSString*type,BOOL blocked){
  // Forward to the map panel if it's been built
  BBConnectionRecord *r=[BBConnectionRecord new];
  r.domain=[BBConnectionRecord etldForHost:domain];
  r.pageURL=page; r.resourceType=type; r.timestamp=[NSDate date]; r.blocked=blocked;
  r.category=[BBConnectionRecord classify:r.domain];
  [[BBNetworkMapPanel shared] pushRecord:r];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  SEL a=item.action;
  if (a==@selector(goBack:))           return self.webView.canGoBack;
  if (a==@selector(goForward:))        return self.webView.canGoForward;
  if (a==@selector(hardReload:))       return self.webView.URL!=nil;
  if (a==@selector(reopenClosedTab:))  return self.recentlyClosed.count>0;
  if (a==@selector(reloadOrStop:)) {
    item.title=self.activeTab.isLoading?@"Stop":@"Reload Page";
    return YES;
  }
  if (a==@selector(toggleReader:))     return self.webView.URL!=nil;
  if (a==@selector(translatePage:))    return self.webView.URL!=nil && !([self isInternalURL:self.webView.URL.absoluteString]);
  if (a==@selector(addToReadingList:)) return self.webView.URL!=nil && !([self isInternalURL:self.webView.URL.absoluteString]);
  if (a==@selector(showReadingList:))  return YES;
  if (a==@selector(toggleBookmarkCurrent:)) {
    NSString *url=self.webView.URL.absoluteString;
    BOOL isBookmarked=url.length&&[[BBBookmarksStore shared] isBookmarked:url];
    item.title=isBookmarked?@"Remove Bookmark":@"Bookmark This Page";
    return self.webView.URL!=nil;
  }
  if (a==@selector(printPage:))        return self.webView.URL!=nil;
  if (a==@selector(sharePage:))        return self.webView.URL!=nil;
  if (a==@selector(viewSource:))       return self.webView.URL!=nil;
  if (a==@selector(prevTab:)||a==@selector(nextTab:)) return self.tabs.count>1;
  if (a==@selector(moveTabLeft:))  return self.activeTabIndex>0;
  if (a==@selector(moveTabRight:)) return self.activeTabIndex<(NSInteger)self.tabs.count-1;
  if (a==@selector(newPrivateWindow:)) return YES;
  if (a==@selector(focusAddressBar:))  return YES;
  if (a==@selector(readAloud:)) {
    item.title=[BBVoice shared].speaking?@"Stop Reading":@"Read Aloud";
    return self.webView.URL!=nil;
  }
  if (a==@selector(muteTab:)) {
    item.title=self.activeTab.muted?@"Unmute Tab":@"Mute Tab";
    return self.webView.URL!=nil;
  }
  if (a==@selector(pinCurrentTab:)) {
    item.title=self.activeTab.pinned?@"Unpin Tab":@"Pin Tab";
    return YES;
  }
  return YES; // default enabled
}
- (void)goBack:(id)s    { if(self.webView.canGoBack)    [self.webView goBack]; }
- (void)goForward:(id)s { if(self.webView.canGoForward) [self.webView goForward]; }
- (void)showNavHistoryMenu:(BOOL)back at:(NSPoint)winLoc {
  WKBackForwardList *bfl=self.webView.backForwardList;
  NSArray<WKBackForwardListItem *> *items=back
    ? [[bfl.backList reverseObjectEnumerator] allObjects]
    : bfl.forwardList;
  if (!items.count) return;
  NSMenu *m=[[NSMenu alloc]initWithTitle:@""];
  for (WKBackForwardListItem *item in items) {
    NSString *t=item.title.length?item.title:item.URL.absoluteString;
    NSMenuItem *mi=[[NSMenuItem alloc]initWithTitle:t action:@selector(navHistoryGo:) keyEquivalent:@""];
    mi.target=self; mi.representedObject=item; [m addItem:mi];
  }
  [m popUpMenuPositioningItem:nil atLocation:winLoc inView:nil];
}
- (void)navHistoryGo:(NSMenuItem *)mi {
  WKBackForwardListItem *item=mi.representedObject;
  if ([item isKindOfClass:[WKBackForwardListItem class]]) [self.webView goToBackForwardListItem:item];
}
- (void)stopLoading:(id)s { if (self.activeTab.isLoading) [self.webView stopLoading]; else NSBeep(); }
- (void)reloadOrStop:(id)s {
  if (self.activeTab.isLoading) [self.webView stopLoading]; else [self.webView reload];
}
- (void)hardReload:(id)s {
  // Bypass all caches — equivalent to Shift+Reload in other browsers
  if (!self.webView.URL) return;
  NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:self.webView.URL];
  req.cachePolicy=NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
  [self.webView loadRequest:req];
}
- (void)pasteAndGo:(id)s {
  NSString *text=[[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
  if (!text.length) return;
  text=[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (!text.length) return;
  self.address.stringValue=text;
  // Smart navigate (same logic as Return key)
  BOOL hasScheme=[text hasPrefix:@"http://"]||[text hasPrefix:@"https://"]||[text hasPrefix:@"file://"];
  BOOL looksLikeHost=[text rangeOfString:@" "].location==NSNotFound&&[text rangeOfString:@"."].location!=NSNotFound;
  NSURL *url=nil;
  if (hasScheme)          url=[NSURL URLWithString:text];
  else if (looksLikeHost) url=[NSURL URLWithString:[@"https://" stringByAppendingString:text]];
  else {
    NSString *q=[text stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    url=[NSURL URLWithString:[BBDelegate searchURLForQuery:text]];
  }
  if (url) [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
  [self.window makeFirstResponder:self.webView];
}
- (void)zoomIn:(id)s    { [self setZoom:self.webView.pageZoom+0.1]; }
- (void)zoomOut:(id)s   { [self setZoom:self.webView.pageZoom-0.1]; }
- (void)zoomReset:(id)s { self.webView.magnification=1.0; [self setZoom:1.0]; }
- (NSString *)currentHost { return self.webView.URL.host?:@""; }
// Set zoom for the active tab, remember it per-host, and flash the level.
- (void)setZoom:(CGFloat)z {
  z=MAX(0.25,MIN(5.0,round(z*100)/100.0));
  self.webView.pageZoom=z;
  NSString *h=self.currentHost;
  if (h.length) {
    if (fabs(z-1.0)<0.001) [self.zoomByHost removeObjectForKey:h];
    else self.zoomByHost[h]=@(z);
    [[NSUserDefaults standardUserDefaults] setObject:self.zoomByHost forKey:@"BBZoomByHost"];
  }
  [self flashZoom:z];
}
// Re-apply a remembered zoom when navigating to / switching to a page.
- (void)applyZoomForCurrentTab {
  NSString *h=self.currentHost;
  CGFloat z=(h.length && self.zoomByHost[h]) ? self.zoomByHost[h].doubleValue : 1.0;
  self.webView.pageZoom=z;
}
- (void)flashZoom:(CGFloat)z {
  [self showStatus:[NSString stringWithFormat:@"Zoom %d%%",(int)lround(z*100)]];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
    if ([self.statusBar.stringValue hasPrefix:@"Zoom "]) self.statusBar.hidden=YES;
  });
}

- (void)printPage:(id)s {
  NSPrintOperation *op=[self.webView printOperationWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
  [op runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:nil];
}
- (void)printSelection:(id)s {
  // Grab the page selection — fall back to the whole page when nothing's selected.
  [self.webView evaluateJavaScript:
    @"(function(){var s=window.getSelection?window.getSelection():null;if(!s||s.rangeCount==0)return '';"
    @"var c=document.createElement('div');for(var i=0;i<s.rangeCount;i++){c.appendChild(s.getRangeAt(i).cloneContents());}return c.innerHTML;})()"
    completionHandler:^(id r,NSError *e){
      NSString *html=[r isKindOfClass:[NSString class]]?(NSString*)r:@"";
      if (!html.length) {
        [self printPage:nil]; return;
      }
      NSString *wrapped=[NSString stringWithFormat:
        @"<!doctype html><html><head><meta charset=\"utf-8\"><style>body{font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;margin:24px;color:#000;}img{max-width:100%%;}</style></head><body>%@</body></html>",html];
      WKWebView *temp=[[WKWebView alloc]initWithFrame:NSMakeRect(0,0,800,1100)];
      [temp loadHTMLString:wrapped baseURL:self.webView.URL];
      // Defer print until the temp view finishes loading.
      objc_setAssociatedObject(self,"BBPrintTempWV",temp,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSPrintOperation *op=[temp printOperationWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
        [op runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:nil];
        objc_setAssociatedObject(self,"BBPrintTempWV",nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      });
    }];
}
- (void)viewSource:(id)s {
  // Fetch source via JS to avoid loading the blocked view-source: scheme through nav policy.
  NSString *pageTitle=self.activeTab.title?:@"Source";
  [self.webView evaluateJavaScript:@"document.documentElement.outerHTML" completionHandler:^(id r,NSError*e){
    NSString *html=[r isKindOfClass:[NSString class]]?r:@"";
    // Escape for display inside a <pre> block
    NSString *escaped=[html stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped=[escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped=[escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    NSString *srcPage=[NSString stringWithFormat:
      @"<!doctype html><html><head><meta charset='utf-8'>"
      @"<title>Source: %@</title>"
      @"<style>body{margin:0;background:#1c1c1e;color:#e5e5ea;"
      @"font-family:ui-monospace,'SF Mono',monospace;font-size:12px;}"
      @"pre{padding:16px;white-space:pre-wrap;word-break:break-all;}"
      @"</style></head><body><pre>%@</pre></body></html>",
      pageTitle, escaped];
    dispatch_async(dispatch_get_main_queue(),^{
      [self addTabPrivate:NO];
      [self.webView loadHTMLString:srcPage baseURL:nil];
    });
  }];
}
- (void)openDevTools:(id)s {
  // Open the Web Inspector via the private _WKInspector. Requires inspectable=YES
  // (set on every webview) and developerExtrasEnabled (set in baseConfig).
  // NOTE: _WKInspector's selector is `show` (no colon) — the old `show:` silently
  // no-op'd, which is why Dev Tools never opened.
  SEL getInspector=NSSelectorFromString(@"_inspector");
  if(![self.webView respondsToSelector:getInspector]) {
    [self showDevToolsUnavailable]; return;
  }
  id inspector=((id(*)(id,SEL))objc_msgSend)(self.webView,getInspector);
  SEL show=NSSelectorFromString(@"show");
  if(inspector && [inspector respondsToSelector:show]) {
    ((void(*)(id,SEL))objc_msgSend)(inspector,show);
  } else {
    [self showDevToolsUnavailable];
  }
}
- (void)showDevToolsUnavailable {
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Developer Tools unavailable";
  a.informativeText=@"The Web Inspector could not be opened on this WebKit build. Right-click ▸ Inspect Element also requires it.";
  [a addButtonWithTitle:@"OK"];
  [a beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)openFile:(id)s {
  NSOpenPanel *p=[NSOpenPanel openPanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  p.allowedFileTypes=@[@"html",@"htm",@"xhtml"];
#pragma clang diagnostic pop
  p.canChooseFiles=YES; p.canChooseDirectories=NO;
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc) {
    if (rc==NSModalResponseOK&&p.URL)
      [self.webView loadFileURL:p.URL allowingReadAccessToURL:[p.URL URLByDeletingLastPathComponent]];
  }];
}
- (void)sharePage:(id)s {
  NSURL *url=self.webView.URL; if (!url) return;
  NSString *title=self.webView.title?:url.absoluteString;
  NSSharingServicePicker *pick=[[NSSharingServicePicker alloc]initWithItems:@[url,title]];
  // Show picker anchored to the ellipsis (bear panel) button if available, else center of toolbar
  NSView *anchor=self.securityButton?:self.toolbarBg;
  [pick showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMinY];
}
- (void)savePage:(id)s {
  NSSavePanel *p=[NSSavePanel savePanel];
  p.nameFieldStringValue=[self.webView.title?:@"page" stringByAppendingString:@".html"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  p.allowedFileTypes=@[@"html"];
#pragma clang diagnostic pop
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc) {
    if (rc!=NSModalResponseOK||!p.URL) return;
    [self.webView evaluateJavaScript:@"document.documentElement.outerHTML"
                   completionHandler:^(id r,NSError *e) {
      if (!e&&[r isKindOfClass:[NSString class]])
        [(NSString *)r writeToURL:p.URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
  }];
}

// ── Favicon fetch ─────────────────────────────────────────────────────────────
static NSString *kFaviconJS=@"(function(){"
  @"var links=document.querySelectorAll('link[rel~=\"icon\"],link[rel~=\"shortcut\"]');"
  @"for(var i=links.length-1;i>=0;i--){var h=links[i].href;if(h&&h.startsWith('http'))return h;}"
  @"return (location.origin&&location.origin!=='null')?location.origin+'/favicon.ico':'';"
  @"})()";

- (void)fetchFaviconForTab:(BBTab *)tab {
  WKWebView *wv=tab.webView;
  [wv evaluateJavaScript:kFaviconJS completionHandler:^(id result,NSError *e) {
    if (e||![result isKindOfClass:[NSString class]]||![(NSString*)result length]) return;
    NSURL *furl=[NSURL URLWithString:result];
    if (!furl) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
      NSData *data=[NSData dataWithContentsOfURL:furl];
      if (!data) return;
      NSImage *img=[[NSImage alloc]initWithData:data];
      if (!img) return;
      dispatch_async(dispatch_get_main_queue(), ^{
        tab.favicon=img;
        [self reloadTabBar];
      });
    });
  }];
}

// ── Find ──────────────────────────────────────────────────────────────────────
- (void)toggleFind:(id)s {
  self.findBarVisible=!self.findBarVisible;
  self.findBar.hidden=!self.findBarVisible;
  [self resizeWebViewForCurrentTab];
  if (self.findBarVisible) [self.window makeFirstResponder:self.findBar.queryField];
  else { [self clearFind]; [self.window makeFirstResponder:self.webView]; }
}
- (void)closeFind:(id)s  { if(self.findBarVisible)[self toggleFind:nil]; }
- (void)doFind:(BOOL)back {
  NSString *q=self.findBar.queryField.stringValue; if(!q.length){[self clearFind];return;}
  WKFindConfiguration *cfg=[[WKFindConfiguration alloc]init];
  cfg.backwards=back; cfg.wraps=YES; cfg.caseSensitive=NO;
  [self.webView findString:q withConfiguration:cfg completionHandler:^(WKFindResult *r){
    if (!r.matchFound) {
      self.findBar.resultLabel.stringValue=@"Not found";
      self.findBar.resultLabel.textColor=[NSColor systemRedColor];
      return;
    }
    self.findBar.resultLabel.textColor=[NSColor secondaryLabelColor];
    [self updateFindCount:q];
  }];
}
// WKFindResult exposes no match count, so count occurrences in the page text.
// Approximate (visible text only; excludes inputs/shadow DOM) but Chrome-like.
- (void)updateFindCount:(NSString *)q {
  NSString *js=[NSString stringWithFormat:
    @"(function(){try{var t=(document.body&&document.body.innerText)||'';"
    @"var q=%@;if(!q)return 0;var n=0,i=0,ql=q.toLowerCase(),tl=t.toLowerCase();"
    @"while((i=tl.indexOf(ql,i))!==-1){n++;i+=ql.length;}return n;}catch(e){return -1;}})();",
    [self jsStringLiteral:q]];
  [self.webView evaluateJavaScript:js completionHandler:^(id r,NSError *e){
    NSInteger n=[r isKindOfClass:[NSNumber class]]?[r integerValue]:-1;
    if (n<0) { self.findBar.resultLabel.stringValue=@""; return; }
    self.findBar.resultLabel.stringValue=(n==1)?@"1 match":[NSString stringWithFormat:@"%ld matches",(long)n];
  }];
}
- (void)findNext:(id)s { [self doFind:NO]; }
- (void)findPrev:(id)s { [self doFind:YES]; }
- (void)clearFind {
  WKFindConfiguration *cfg=[[WKFindConfiguration alloc]init];
  [self.webView findString:@"" withConfiguration:cfg completionHandler:^(WKFindResult *r){}];
  self.findBar.resultLabel.stringValue=@"";
}

// ── Address bar ───────────────────────────────────────────────────────────────
- (void)controlTextDidBeginEditing:(NSNotification *)n { (void)n; }
- (NSString *)bestURLCompletionFor:(NSString *)prefix {
  // Strip scheme from prefix so "git" matches "https://github.com"
  NSString *pl=prefix.lowercaseString;
  NSArray *schemes=@[@"https://www.",@"http://www.",@"https://",@"http://"];
  // Bookmarks first (user explicitly saved = high confidence)
  for (BBBookmark *b in [BBBookmarksStore shared].items) {
    NSString *url=b.urlString; NSString *urlL=url.lowercaseString;
    NSString *bare=urlL;
    for (NSString *sc in schemes) { if ([urlL hasPrefix:sc]){bare=[urlL substringFromIndex:sc.length];break;} }
    if ([bare hasPrefix:pl]||[urlL hasPrefix:pl]) return b.urlString;
  }
  // Then history
  for (BBHistoryEntry *e in [[BBHistoryStore shared] search:prefix limit:5]) {
    NSString *url=e.urlString; NSString *urlL=url.lowercaseString;
    NSString *bare=urlL;
    for (NSString *sc in schemes) { if ([urlL hasPrefix:sc]){bare=[urlL substringFromIndex:sc.length];break;} }
    if ([bare hasPrefix:pl]||[urlL hasPrefix:pl]) return e.urlString;
  }
  return nil;
}
- (void)controlTextDidChange:(NSNotification *)n {
  // Tab Search panel intercept — must be first so we return before the address-bar path
  if ([n.object isKindOfClass:[NSSearchField class]] && ((NSSearchField*)n.object).tag==0xCAFE) {
    NSString *q=((NSSearchField*)n.object).stringValue.lowercaseString;
    NSMutableArray *filtered=[NSMutableArray array];
    for (BBTab *t in self.tabs) {
      NSString *title=(t.title?:@"").lowercaseString;
      NSString *u=(t.suspended?t.suspendedURL:t.webView.URL.absoluteString)?:@"";
      if (!q.length||[title containsString:q]||[u.lowercaseString containsString:q]) [filtered addObject:t];
    }
    objc_setAssociatedObject(self,"tabSearchFiltered",filtered,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSPanel *p=(NSPanel *)objc_getAssociatedObject(self,"tabSearchPanel");
    NSTableView *tv2=(NSTableView *)objc_getAssociatedObject(p,"tv");
    [tv2 reloadData];
    if (filtered.count>0) [tv2 selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    return;
  }
  if (n.object!=self.address) return;
  if (self.suppressInlineCompletion) return;
  NSString *q=[self.address.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  // Remote suggestions only when enabled in Settings AND not in a private tab — never
  // send incognito keystrokes to the suggest endpoint.
  self.addressDropdown.remoteSuggestEnabled =
    [[NSUserDefaults standardUserDefaults] boolForKey:@"BBSearchSuggestions"] && !self.activeTab.isPrivate;
  NSMutableArray *snap=[NSMutableArray array];
  for (NSInteger k=0;k<(NSInteger)self.tabs.count;k++) {
    if (k==self.activeTabIndex) continue;
    BBTab *t=self.tabs[k];
    NSString *u=t.suspended?t.suspendedURL:t.webView.URL.absoluteString;
    if (!u.length || [self isInternalURL:u]) continue;
    [snap addObject:@{@"idx":@(k),@"title":t.title?:@"",@"url":u}];
  }
  self.addressDropdown.openTabsSnapshot=snap;
  if (q.length) [self.addressDropdown updateForQuery:q belowField:self.address inWindow:self.window];
  else [self.addressDropdown hide];
  // Inline autocomplete (default ON, disabled by user pref or private mode)
  // Only attempt if the typed text is URL-like (no spaces) and at least 2 chars.
  NSUserDefaults *ud=[NSUserDefaults standardUserDefaults];
  BOOL inlineON=([ud objectForKey:@"BBInlineAutocomplete"]==nil||[ud boolForKey:@"BBInlineAutocomplete"])
                && !self.activeTab.isPrivate && q.length>=2 && ![q containsString:@" "];
  if (inlineON) {
    NSString *full=[self bestURLCompletionFor:q];
    if (full) {
      // Determine what to show inline: strip scheme to match what the user typed
      NSString *display=full;
      NSArray *schemes=@[@"https://www.",@"http://www.",@"https://",@"http://"];
      for (NSString *sc in schemes) {
        if ([full.lowercaseString hasPrefix:sc.lowercaseString]) {
          display=[full substringFromIndex:sc.length]; break;
        }
      }
      if (display.length>q.length && [display.lowercaseString hasPrefix:q.lowercaseString]) {
        NSTextView *tv=(NSTextView*)[self.address currentEditor];
        if (tv) {
          self.suppressInlineCompletion=YES;
          // Set text to the completion, select only the appended portion
          NSString *prev=tv.string;
          tv.string=display;
          // Only select the appended tail — so typing replaces it, Delete undoes it
          NSRange tail=NSMakeRange(q.length, display.length-q.length);
          [tv setSelectedRange:tail];
          self.suppressInlineCompletion=NO;
          // If we changed the field's displayed text, update again with the typed part
          if (![prev isEqualToString:display]) {
            [self.addressDropdown updateForQuery:q belowField:self.address inWindow:self.window];
          }
        }
      }
    }
  }
}
- (void)controlTextDidEndEditing:(NSNotification *)n {
  if (n.object==self.address) [self.addressDropdown hide];
}
- (BOOL)control:(NSControl *)ctrl textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
  // Tab Search field — Enter confirms, Escape closes, arrows navigate the list
  if ([ctrl isKindOfClass:[NSSearchField class]] && ((NSSearchField *)ctrl).tag==0xCAFE) {
    NSPanel *p=(NSPanel *)objc_getAssociatedObject(self,"tabSearchPanel");
    NSTableView *tsv=(NSTableView *)objc_getAssociatedObject(p,"tv");
    if (sel==@selector(insertNewline:))   { [self tabSearchConfirm:nil]; return YES; }
    if (sel==@selector(cancelOperation:)) {
      [p orderOut:nil];
      objc_setAssociatedObject(self,"tabSearchPanel",nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      objc_setAssociatedObject(self,"tabSearchFiltered",nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      return YES;
    }
    if (sel==@selector(moveDown:)) {
      NSInteger row=tsv.selectedRow; NSInteger n=(NSInteger)tsv.numberOfRows;
      if (n>0) { NSInteger nr=MIN(row+1,n-1); [tsv selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)nr] byExtendingSelection:NO]; [tsv scrollRowToVisible:nr]; }
      return YES;
    }
    if (sel==@selector(moveUp:)) {
      NSInteger row=tsv.selectedRow;
      if (row>0) { NSInteger nr=row-1; [tsv selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)nr] byExtendingSelection:NO]; [tsv scrollRowToVisible:nr]; }
      return YES;
    }
    return NO;
  }
  if (ctrl==self.findBar.queryField) {
    if (sel==@selector(insertNewline:))   { [self findNext:nil]; return YES; }
    if (sel==@selector(cancelOperation:)) { [self closeFind:nil]; return YES; }
    return NO;
  }
  if (ctrl==self.address) {
    if (sel==@selector(moveDown:))   { [self.addressDropdown selectNext]; return YES; }
    if (sel==@selector(moveUp:))     { [self.addressDropdown selectPrev]; return YES; }
    if (sel==@selector(insertNewline:)) {
      if ([self.addressDropdown confirmSelection]) return YES;
      // Ctrl+Return → www.{text}.com expansion (Chrome behavior)
      NSUInteger mods=[NSApp currentEvent].modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
      if (mods & NSEventModifierFlagControl) {
        NSString *t=[self.address.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length && ![t containsString:@"."] && ![t containsString:@" "]) {
          NSString *expanded=[NSString stringWithFormat:@"https://www.%@.com",t];
          NSURL *eu=[NSURL URLWithString:expanded];
          if (eu) { [self.webView loadRequest:[NSURLRequest requestWithURL:eu]]; [self.window makeFirstResponder:self.webView]; return YES; }
        }
      }
      // Open in new tab when either Cmd (Chrome standard on macOS) or Option is held with Enter.
      BOOL openInNewTab=((mods & NSEventModifierFlagOption) | (mods & NSEventModifierFlagCommand)) != 0;
      NSString *raw=[self.address.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      // Reject any dangerous scheme typed directly into the address bar
      NSString *rawLower=raw.lowercaseString;
      if ([rawLower hasPrefix:@"javascript:"]||[rawLower hasPrefix:@"view-source:"]||
          [rawLower hasPrefix:@"webkit-"]||[rawLower hasPrefix:@"x-webkit"]) {
        self.address.stringValue=@""; [self.window makeFirstResponder:self.webView]; return YES;
      }
      BOOL hasScheme=[raw hasPrefix:@"http://"]||[raw hasPrefix:@"https://"]||[raw hasPrefix:@"file://"];
      BOOL looksLikeHost=[raw rangeOfString:@" "].location==NSNotFound&&[raw rangeOfString:@"."].location!=NSNotFound;
      NSURL *url=nil;
      if (hasScheme)         url=[NSURL URLWithString:raw];
      else if (looksLikeHost) url=[NSURL URLWithString:[@"https://" stringByAppendingString:raw]];
      else {
        NSString *q=[raw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        url=[NSURL URLWithString:[BBDelegate searchURLForQuery:raw]];
      }
      if (url) {
        [self emitNav:@"navigation.requested" url:url.absoluteString reason:@"User navigation." private:self.activeTab.isPrivate];
        if (openInNewTab) { [self addTabPrivate:self.activeTab.isPrivate]; }
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
      }
      [self.window makeFirstResponder:self.webView]; return YES;
    }
    if (sel==@selector(cancelOperation:)) {
      NSString *url=self.webView.URL.absoluteString?:@"";
      self.address.stringValue=[self isInternalURL:url]?@"":url;
      [self.window makeFirstResponder:self.webView]; return YES;
    }
  }
  return NO;
}

// ── Navigation delegate ───────────────────────────────────────────────────────
// beforeunload dialogs — suppress "are you sure you want to leave?" gates
- (void)webViewDidClose:(WKWebView*)wv { /* no action — suppresses beforeunload UI */ }

- (WKWebView *)webView:(WKWebView *)wv createWebViewWithConfiguration:(WKWebViewConfiguration *)cfg forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
  // Always open as a real tab — matching Safari's behavior.
  // WebKit's own popup blocker gates window.open() by gesture before calling this delegate,
  // so we don't re-gate on timing (which would expose a unique per-browser fingerprint via
  // entropy matching). Use cfg as-is: macOS 26 SOAuthorizationCoordinator requires the new
  // view to share cfg's websiteDataStore for SSO session cookies.
  CGFloat W=self.root.bounds.size.width;
  CGFloat chromH=kToolbarH+kTabBarH+2;
  CGFloat findOff=self.findBarVisible?kFindBarH:0;
  WKWebView *newWV=[[WKWebView alloc]initWithFrame:NSMakeRect(0,findOff,W,self.root.bounds.size.height-chromH-findOff)
                                     configuration:cfg];
  newWV.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  newWV.customUserAgent=@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";
  newWV.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
  newWV.navigationDelegate=self; newWV.UIDelegate=self;
  newWV.allowsBackForwardNavigationGestures=YES; newWV.allowsLinkPreview=YES;
  newWV.allowsMagnification=YES; // trackpad pinch-to-zoom (Chrome parity)
  if (@available(macOS 13.3, *)) newWV.inspectable=YES;
  [newWV addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:(__bridge void *)newWV];
  [newWV addObserver:self forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:(__bridge void *)newWV];

  BBTab *tab=[[BBTab alloc]init];
  // Inherit private-ness from the opener: window.open/target=_blank reuse the
  // opener's configuration, so a popup from a private tab shares its ephemeral
  // data store. Mark the tab private to match — otherwise its navigations would
  // leak into history and session restore. (A non-persistent store == private.)
  tab.isPrivate = !cfg.websiteDataStore.persistent;
  tab.webView=newWV;
  [self.tabs addObject:tab];
  if (action.request.URL) [tab.webView loadRequest:action.request];
  NSInteger ni=self.tabs.count-1; [self reloadTabBar];
  dispatch_async(dispatch_get_main_queue(),^{[self activateTab:ni];[self reloadTabBar];});
  return newWV;
}
// ── JS dialogs + file upload (WKUIDelegate) ───────────────────────────────────
// Real NSAlert sheets for alert/confirm/prompt and NSOpenPanel for file upload.
// Chrome-style abuse protection: after 3 dialogs without navigation the user gets
// a "Block additional dialogs" checkbox. Once suppressed, dialogs no-op until nav.
static const NSInteger kDialogAbuseThreshold = 3;

- (NSString *)jsDialogTitleForFrame:(WKFrameInfo *)frame {
  NSString *host=frame.request.URL.host;
  return host.length?[NSString stringWithFormat:@"%@ says",host]:@"This page says";
}
- (BOOL)checkDialogAbuseForWebView:(WKWebView *)wv voidCompletion:(void(^)(void))voidDone
    boolCompletion:(void(^)(BOOL))boolDone stringCompletion:(void(^)(NSString*))strDone {
  BBTab *tab=[self tabForWebView:wv]; if (!tab) return NO;
  if (tab.dialogsSuppressed) {
    if (voidDone) voidDone();
    else if (boolDone) boolDone(NO);
    else if (strDone) strDone(nil);
    return YES;
  }
  tab.dialogCount++;
  return NO;
}
- (void)addSuppressCheckboxIfNeeded:(NSAlert *)alert webView:(WKWebView *)wv {
  BBTab *tab=[self tabForWebView:wv]; if (!tab) return;
  if (tab.dialogCount < kDialogAbuseThreshold) return;
  NSButton *cb=[NSButton checkboxWithTitle:@"Block additional dialogs from this page" target:nil action:nil];
  alert.accessoryView=cb;
}
- (void)handleSuppressCheckbox:(NSAlert *)alert webView:(WKWebView *)wv {
  if (![alert.accessoryView isKindOfClass:[NSButton class]]) return;
  NSButton *cb=(NSButton *)alert.accessoryView;
  if (cb.state==NSControlStateValueOn) {
    BBTab *tab=[self tabForWebView:wv];
    if (tab) tab.dialogsSuppressed=YES;
  }
}
- (void)webView:(WKWebView *)wv runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
  if ([self checkDialogAbuseForWebView:wv voidCompletion:completionHandler boolCompletion:nil stringCompletion:nil]) return;
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[self jsDialogTitleForFrame:frame]; a.informativeText=message?:@"";
  [a addButtonWithTitle:@"OK"];
  [self addSuppressCheckboxIfNeeded:a webView:wv];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    [self handleSuppressCheckbox:a webView:wv];
    completionHandler();
  }];
}
- (void)webView:(WKWebView *)wv runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
  if ([self checkDialogAbuseForWebView:wv voidCompletion:nil boolCompletion:completionHandler stringCompletion:nil]) return;
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[self jsDialogTitleForFrame:frame]; a.informativeText=message?:@"";
  [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
  [self addSuppressCheckboxIfNeeded:a webView:wv];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    [self handleSuppressCheckbox:a webView:wv];
    completionHandler(rc==NSAlertFirstButtonReturn);
  }];
}
- (void)webView:(WKWebView *)wv runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(NSString *))completionHandler {
  if ([self checkDialogAbuseForWebView:wv voidCompletion:nil boolCompletion:nil stringCompletion:completionHandler]) return;
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[self jsDialogTitleForFrame:frame]; a.informativeText=prompt?:@"";
  NSTextField *tf=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,260,24)];
  tf.stringValue=defaultText?:@"";
  // accessoryView is the text field; suppress checkbox only applies when count < threshold
  BBTab *tab=[self tabForWebView:wv];
  if (tab && tab.dialogCount >= kDialogAbuseThreshold) {
    NSStackView *sv=[NSStackView stackViewWithViews:@[tf,
      [NSButton checkboxWithTitle:@"Block additional dialogs from this page" target:nil action:nil]]];
    sv.orientation=NSUserInterfaceLayoutOrientationVertical; sv.alignment=NSLayoutAttributeLeading;
    sv.spacing=6; a.accessoryView=sv;
  } else {
    a.accessoryView=tf;
  }
  [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if ([a.accessoryView isKindOfClass:[NSStackView class]]) {
      NSStackView *sv=(NSStackView *)a.accessoryView;
      for (NSView *v in sv.arrangedSubviews) {
        if ([v isKindOfClass:[NSButton class]] && ((NSButton*)v).state==NSControlStateValueOn) {
          if (tab) tab.dialogsSuppressed=YES;
        }
      }
    }
    completionHandler(rc==NSAlertFirstButtonReturn?tf.stringValue:nil);
  }];
}
- (void)webView:(WKWebView *)wv runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler {
  NSOpenPanel *p=[NSOpenPanel openPanel];
  p.canChooseFiles=YES; p.canChooseDirectories=NO;
  p.allowsMultipleSelection=parameters.allowsMultipleSelection;
  [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    completionHandler(rc==NSModalResponseOK?p.URLs:nil);
  }];
}
- (void)webView:(WKWebView *)wv navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)download {
  download.delegate=self;
}
- (void)webView:(WKWebView *)wv navigationResponse:(WKNavigationResponse *)response didBecomeDownload:(WKDownload *)download {
  download.delegate=self;
}
// ── Navigation response policy — trigger download for Content-Disposition: attachment ────
- (void)webView:(WKWebView *)wv decidePolicyForNavigationResponse:(WKNavigationResponse *)response
    decisionHandler:(void(^)(WKNavigationResponsePolicy))decisionHandler {
  NSHTTPURLResponse *http=(NSHTTPURLResponse *)response.response;
  if ([http isKindOfClass:[NSHTTPURLResponse class]]) {
    NSString *cd=http.allHeaderFields[@"Content-Disposition"]?:@"";
    if ([cd hasPrefix:@"attachment"]) { decisionHandler(WKNavigationResponsePolicyDownload); return; }
  }
  decisionHandler(response.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}
// ── HTTP Basic / Digest auth challenge ────────────────────────────────────────
- (void)webView:(WKWebView *)wv didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void(^)(NSURLSessionAuthChallengeDisposition,NSURLCredential*))done {
  NSString *method=challenge.protectionSpace.authenticationMethod;
  if ([method isEqualToString:NSURLAuthenticationMethodHTTPBasic] ||
      [method isEqualToString:NSURLAuthenticationMethodHTTPDigest] ||
      [method isEqualToString:NSURLAuthenticationMethodNTLM]) {
    dispatch_async(dispatch_get_main_queue(),^{
      NSAlert *a=[[NSAlert alloc]init];
      a.messageText=[NSString stringWithFormat:@"Sign in to %@",challenge.protectionSpace.host];
      a.informativeText=challenge.protectionSpace.realm.length?
        [NSString stringWithFormat:@"Realm: %@",challenge.protectionSpace.realm]:@"";
      NSTextField *user=[[NSTextField alloc]initWithFrame:NSMakeRect(0,30,260,22)];
      user.placeholderString=@"Username";
      NSSecureTextField *pass=[[NSSecureTextField alloc]initWithFrame:NSMakeRect(0,0,260,22)];
      pass.placeholderString=@"Password";
      NSView *acc=[[NSView alloc]initWithFrame:NSMakeRect(0,0,260,58)];
      [acc addSubview:user]; [acc addSubview:pass];
      a.accessoryView=acc;
      [a addButtonWithTitle:@"Sign In"]; [a addButtonWithTitle:@"Cancel"];
      [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
        if (rc==NSAlertFirstButtonReturn && user.stringValue.length) {
          NSURLCredential *cred=[NSURLCredential credentialWithUser:user.stringValue
            password:pass.stringValue persistence:NSURLCredentialPersistenceForSession];
          done(NSURLSessionAuthChallengeUseCredential,cred);
        } else {
          done(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
        }
      }];
    });
    return;
  }
  // Server trust (HTTPS) — default WebKit handling
  if ([method isEqualToString:NSURLAuthenticationMethodServerTrust])
    done(NSURLSessionAuthChallengePerformDefaultHandling,nil);
  else
    done(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
}
// ── HTTPS upgrade + mixed-content guard ───────────────────────────────────────
- (void)webView:(WKWebView *)wv decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  NSURL *url=action.request.URL;

  // Hard-block any scheme that could expose the WebKit inspector, source viewer,
  // or remote debugging protocol — regardless of who requested the navigation.
  NSString *scheme=url.scheme.lowercaseString?:@"";
  if ([scheme isEqualToString:@"view-source"] ||
      [scheme isEqualToString:@"webkit-developer"] ||
      [scheme isEqualToString:@"webkit-javascript"] ||
      [scheme hasPrefix:@"x-webkit"] ||
      [scheme isEqualToString:@"javascript"]) {
    decisionHandler(WKNavigationActionPolicyCancel);
    BBEmitEvent(@"security.blocked_scheme",@"block",
      [NSString stringWithFormat:@"Blocked navigation to %@:// scheme",scheme],
      @{@"scheme":scheme,@"url":url.absoluteString?:@""});
    return;
  }

  // Modifier-click behaviors on links (Chrome parity):
  //   ⌘⇧-click → new tab AND switch to it (foreground)
  //   ⌘-click  → new background tab (stay on current)
  //   ⇧-click  → new window
  if (action.navigationType==WKNavigationTypeLinkActivated) {
    NSEventModifierFlags m=action.modifierFlags;
    BOOL cmd=(m & NSEventModifierFlagCommand)!=0;
    BOOL shift=(m & NSEventModifierFlagShift)!=0;
    if (cmd) {
      decisionHandler(WKNavigationActionPolicyCancel);
      dispatch_async(dispatch_get_main_queue(),^{
        NSInteger prev=self.activeTabIndex;
        [self addTabPrivate:self.activeTab.isPrivate];
        [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
        if (!shift) [self tabItemDidSelect:prev]; // ⌘+click stays, ⌘⇧+click foregrounds
      });
      return;
    }
    if (shift) {
      decisionHandler(WKNavigationActionPolicyCancel);
      dispatch_async(dispatch_get_main_queue(),^{
        BBDelegate *w=[[BBDelegate alloc]init];
        NSNotification *dummy=[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp];
        [w applicationDidFinishLaunching:dummy];
        [w.webView loadRequest:[NSURLRequest requestWithURL:url]];
      });
      return;
    }
  }

  // Tracking-parameter strip — remove well-known analytics tags before loading
  static NSSet *_tp=nil;
  static dispatch_once_t _tpOnce;
  dispatch_once(&_tpOnce,^{
    _tp=[NSSet setWithArray:@[
      @"utm_source",@"utm_medium",@"utm_campaign",@"utm_term",@"utm_content",
      @"utm_id",@"utm_source_platform",@"utm_creative_format",@"utm_marketing_tactic",
      @"fbclid",@"gclid",@"gclsrc",@"dclid",@"gbraid",@"wbraid",
      @"mc_eid",@"yclid",@"twclid",@"msclkid",@"igshid",@"mkt_tok",
      @"hmb_campaign",@"hmb_source",@"hmb_medium",@"_hsenc",@"_hsmi",
      @"mc_cid",@"si",@"trk",@"trkCampaign",@"sc_campaign",@"sc_channel"
    ]];
  });
  if (action.navigationType==WKNavigationTypeLinkActivated) {
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSArray<NSURLQueryItem*> *orig=c.queryItems;
    if (orig.count) {
      NSArray<NSURLQueryItem*> *clean=[orig filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURLQueryItem *qi,NSDictionary *_){
          return ![_tp containsObject:qi.name.lowercaseString];
        }]];
      if (clean.count!=orig.count) {
        c.queryItems=clean.count?clean:nil;
        NSURL *stripped=c.URL;
        if (stripped) {
          decisionHandler(WKNavigationActionPolicyCancel);
          [wv loadRequest:[NSURLRequest requestWithURL:stripped]];
          return;
        }
      }
    }
  }

  // Non-http(s) external schemes (mailto:, tel:, sms:, ftp:, magnet:, etc.) — hand off to the OS.
  BOOL isWebScheme=[scheme isEqualToString:@"https"]||[scheme isEqualToString:@"http"]
                   ||[scheme isEqualToString:@"file"]||[scheme isEqualToString:@"blob"]
                   ||[scheme isEqualToString:@"about"]||[scheme isEqualToString:@"data"]
                   ||[scheme isEqualToString:@"bbfont"]||[scheme isEqualToString:@"bearbrowser"];
  if (!isWebScheme && scheme.length) {
    decisionHandler(WKNavigationActionPolicyCancel);
    [[NSWorkspace sharedWorkspace] openURL:url];
    return;
  }

  // Auto-upgrade plain HTTP to HTTPS (skip localhost and .local)
  if ([url.scheme isEqualToString:@"http"]) {
    NSString *host=url.host?:@"";
    BOOL isLocal=[host isEqualToString:@"localhost"]||[host isEqualToString:@"127.0.0.1"]
                 ||[host hasSuffix:@".local"]||[host hasSuffix:@".localhost"];
    if (!isLocal) {
      NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
      c.scheme=@"https";
      NSURL *upgraded=c.URL;
      if (upgraded) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [wv loadRequest:[NSURLRequest requestWithURL:upgraded]];
        return;
      }
    }
  }

  // Quad9 safe-browsing — async DNS check, only for external http/https navigations
  NSString *host=url.host;
  BOOL isExternal=([url.scheme isEqualToString:@"https"]||[url.scheme isEqualToString:@"http"])
                  && host.length && ![host isEqualToString:@"localhost"]
                  && ![host isEqualToString:@"127.0.0.1"] && ![host hasSuffix:@".local"];
  if (isExternal && action.navigationType!=WKNavigationTypeBackForward) {
    // Allow immediately — if Quad9 says blocked, we interrupt with warning page
    decisionHandler(WKNavigationActionPolicyAllow);
    NSURL *navURL=url;
    [self checkQuad9:host completion:^(BOOL blocked){
      if (blocked) [self showThreatWarning:host webView:wv blockedURL:navURL];
    }];
    return;
  }

  decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)contextOpenLinkNewTab:(NSMenuItem *)item {
  NSURL *url=item.representedObject; if (!url) return;
  // Chrome's "Open Link in New Tab" opens in BACKGROUND — current tab stays focused.
  NSInteger prev=self.activeTabIndex;
  [self addTabPrivate:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
  if (prev>=0 && prev<(NSInteger)self.tabs.count-1) [self tabItemDidSelect:prev];
}
- (void)contextCopyLink:(NSMenuItem *)item {
  NSURL *url=item.representedObject; if (!url) return;
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] setString:url.absoluteString forType:NSPasteboardTypeString];
}
- (void)contextCopyPageURL:(NSMenuItem *)item {
  NSString *u=self.webView.URL.absoluteString?:@""; if (!u.length) return;
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] setString:u forType:NSPasteboardTypeString];
}
- (void)contextAddLinkToSession:(NSMenuItem *)item {
  NSURL *url=item.representedObject; if (!url) return;
  NSString *name=[self promptForSessionName:@"Add Link to Research Session" existing:YES];
  if (!name.length) return;
  BBResearchSession *sess=[[BBResearchStore shared] sessionNamed:name create:YES];
  BBResearchItem *it=[BBResearchItem new];
  it.urlString=url.absoluteString; it.title=url.host?:url.absoluteString;
  it.note=@""; it.status=BBResearchStatusUnread; it.addedAt=[NSDate date];
  [sess.items addObject:it]; [[BBResearchStore shared] save];
}
- (void)contextOpenLinkNewWindow:(NSMenuItem *)item {
  NSURL *url=item.representedObject; if (!url) return;
  [self openURLInNewWindow:url];
}
- (void)contextOpenLinkIncognito:(NSMenuItem *)item {
  NSURL *url=item.representedObject; if (!url) return;
  BBDelegate *w=[[BBDelegate alloc]init];
  [w applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
  if (url) { [w addTabPrivate:YES]; [w.webView loadRequest:[NSURLRequest requestWithURL:url]]; }
}
- (void)contextCopyImage:(NSMenuItem *)item {
  NSString *urlStr=item.representedObject; if (!urlStr) return;
  NSURL *src=[NSURL URLWithString:urlStr]; if (!src) return;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
    NSData *data=[NSData dataWithContentsOfURL:src]; if (!data) return;
    NSImage *img=[[NSImage alloc]initWithData:data]; if (!img) return;
    dispatch_async(dispatch_get_main_queue(),^{
      [[NSPasteboard generalPasteboard] clearContents];
      [[NSPasteboard generalPasteboard] writeObjects:@[img]];
    });
  });
}
- (void)openURLInNewWindow:(NSURL *)url {
  BBDelegate *w=[[BBDelegate alloc]init]; // retained by gBBWindowControllers in launch
  [w applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
  if (url) [w.webView loadRequest:[NSURLRequest requestWithURL:url]];
}
- (void)contextCopySelection:(NSMenuItem *)item {
  NSString *t=item.representedObject; if(!t.length) return;
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] setString:t forType:NSPasteboardTypeString];
}
- (void)contextSearchSelection:(NSMenuItem *)item {
  NSString *t=item.representedObject; if(!t.length) return;
  NSURL *u=[NSURL URLWithString:[BBDelegate searchURLForQuery:t]]; if(!u) return;
  [self addTabPrivate:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}
// Install a right-click monitor so we can show our own Chrome-style context menu.
- (void)installContextMenuMonitor {
  __weak BBDelegate *weak=self;
  self.contextMenuMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown handler:^NSEvent*(NSEvent *e){
    BBDelegate *s=weak; if (!s||e.window!=s.window) return e;
    // Right-click on back / forward button → show nav-history dropdown (Chrome UX).
    NSPoint toolPt=[s.toolbarBg convertPoint:e.locationInWindow fromView:nil];
    if (NSPointInRect(toolPt,s.backButton.frame))    { [s showNavHistoryMenu:YES  at:e.locationInWindow]; return nil; }
    if (NSPointInRect(toolPt,s.forwardButton.frame)) { [s showNavHistoryMenu:NO   at:e.locationInWindow]; return nil; }
    NSPoint pt=[s.webView convertPoint:e.locationInWindow fromView:nil];
    if (!NSPointInRect(pt,s.webView.bounds)) return e;
    // If the focused element is editable (input/textarea/contentEditable), defer to
    // the native WKWebView context menu so the OS spell-check items remain reachable.
    if (s.activeTab.editableFocus) return e;
    // Probe the page at the click point for a link, an image, any selection, AND
    // whether the click target is an editable input (so native spell-check stays
    // available on misspelled words in text fields).
    NSString *js=[NSString stringWithFormat:
      @"(function(){var el=document.elementFromPoint(%f,%f);var link='',img='',n=el,edit=false;"
      @"while(n){if(n.tagName==='A'&&n.href){link=n.href;break;}n=n.parentElement;}"
      @"n=el;while(n){if(n.tagName==='IMG'&&n.src){img=n.src;break;}n=n.parentElement;}"
      @"n=el;while(n){if(n.isContentEditable||n.tagName==='INPUT'||n.tagName==='TEXTAREA'){edit=true;break;}n=n.parentElement;}"
      @"var sel=(window.getSelection?String(window.getSelection()):'')||'';"
      @"return {link:link,image:img,sel:sel,edit:edit};})();", pt.x, s.webView.bounds.size.height-pt.y];
    [s.webView evaluateJavaScript:js completionHandler:^(id result,NSError *err){
      dispatch_async(dispatch_get_main_queue(),^{
        NSDictionary *r=[result isKindOfClass:[NSDictionary class]]?result:@{};
        NSString *href=[r[@"link"] isKindOfClass:[NSString class]]?r[@"link"]:@"";
        NSString *imgSrc=[r[@"image"] isKindOfClass:[NSString class]]?r[@"image"]:@"";
        NSString *sel=[r[@"sel"] isKindOfClass:[NSString class]]?r[@"sel"]:@"";
        sel=[sel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *linkURL=href.length?[NSURL URLWithString:href]:nil;
        NSURL *imgURL=imgSrc.length?[NSURL URLWithString:imgSrc]:nil;
        NSMenu *menu=[[NSMenu alloc]initWithTitle:@""];
        NSMenuItem*(^add)(NSString*,SEL,id)=^NSMenuItem*(NSString*t,SEL a,id rep){
          NSMenuItem *it=[[NSMenuItem alloc]initWithTitle:t action:a keyEquivalent:@""];
          it.target=s; it.representedObject=rep; [menu addItem:it]; return it;
        };
        if (sel.length) {
          add(@"Copy",@selector(contextCopySelection:),sel);
          NSString *shown=sel.length>24?[[sel substringToIndex:24] stringByAppendingString:@"…"]:sel;
          add([NSString stringWithFormat:@"Search for “%@”",shown],@selector(contextSearchSelection:),sel);
          [menu addItem:[NSMenuItem separatorItem]];
        }
        if (linkURL) {
          add(@"Open Link in New Tab",@selector(contextOpenLinkNewTab:),linkURL);
          add(@"Open Link in New Window",@selector(contextOpenLinkNewWindow:),linkURL);
          add(@"Open Link in Incognito Window",@selector(contextOpenLinkIncognito:),linkURL);
          add(@"Copy Link Address",@selector(contextCopyLink:),linkURL);
          add(@"Save Link As…",@selector(contextSaveLink:),linkURL);
          add(@"Add Link to Research Session…",@selector(contextAddLinkToSession:),linkURL);
          [menu addItem:[NSMenuItem separatorItem]];
        }
        if (imgURL) {
          add(@"Open Image in New Tab",@selector(contextOpenLinkNewTab:),imgURL);
          add(@"Copy Image",@selector(contextCopyImage:),imgURL);
          add(@"Copy Image Address",@selector(contextCopyLink:),imgURL);
          add(@"Save Image As…",@selector(contextSaveImage:),imgURL);
          add(@"Search Image on Google Lens",@selector(contextSearchImageOnLens:),imgURL);
          add(@"Search Image on TinEye",@selector(contextSearchImageOnTinEye:),imgURL);
          [menu addItem:[NSMenuItem separatorItem]];
        }
        NSMenuItem *back=add(@"Back",@selector(goBack:),nil); back.enabled=s.webView.canGoBack;
        NSMenuItem *fwd=add(@"Forward",@selector(goForward:),nil); fwd.enabled=s.webView.canGoForward;
        add(@"Reload",@selector(reloadOrStop:),nil);
        [menu addItem:[NSMenuItem separatorItem]];
        add(@"Copy Page URL",@selector(contextCopyPageURL:),nil);
        add(@"Add Page to Research Session…",@selector(addCurrentTabToSession:),nil);
        add(@"Add to Reading List",@selector(addToReadingList:),nil);
        add(@"Save Page As…",@selector(savePage:),nil);
        add(@"Share Page…",@selector(sharePage:),nil);
        add(@"Print…",@selector(printPage:),nil);
        [menu addItem:[NSMenuItem separatorItem]];
        add(@"View Page Source",@selector(viewSource:),nil);
        add(@"Inspect Element",@selector(openDevTools:),nil);
        [menu popUpMenuPositioningItem:nil atLocation:e.locationInWindow inView:nil];
      });
    }];
    return nil; // swallow the original right-click
  }];
  // Middle-click a link → open in a new background tab (Chrome behavior).
  self.middleClickMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskOtherMouseDown handler:^NSEvent*(NSEvent *e){
    if (e.buttonNumber!=2) return e;
    BBDelegate *s=weak; if(!s||e.window!=s.window) return e;
    NSPoint pt=[s.webView convertPoint:e.locationInWindow fromView:nil];
    if(!NSPointInRect(pt,s.webView.bounds)) return e;
    NSString *js=[NSString stringWithFormat:
      @"(function(){var el=document.elementFromPoint(%f,%f);"
      @"while(el){if(el.tagName==='A'&&el.href)return el.href;el=el.parentElement;}return '';})();",
      pt.x, s.webView.bounds.size.height-pt.y];
    [s.webView evaluateJavaScript:js completionHandler:^(id r,NSError *err){
      NSString *href=[r isKindOfClass:[NSString class]]?r:@""; if(!href.length) return;
      NSURL *u=[NSURL URLWithString:href]; if(!u) return;
      dispatch_async(dispatch_get_main_queue(),^{
        NSInteger prev=s.activeTabIndex;
        [s addTabPrivate:s.activeTab.isPrivate];
        [s.webView loadRequest:[NSURLRequest requestWithURL:u]];
        [s tabItemDidSelect:prev]; // stay on the current tab (open in background)
      });
    }];
    return e;
  }];
}

- (void)webView:(WKWebView *)wv didStartProvisionalNavigation:(WKNavigation *)nav {
  BBTab *tab=[self tabForWebView:wv]; if (!tab) return;
  tab.dialogCount=0; tab.dialogsSuppressed=NO; // reset per-page dialog abuse state
  tab.genpassOffered=NO;                       // re-arm the password-generator prompt
  tab.translateOffered=NO;                     // re-arm the translate prompt
  tab.isLoading=YES;
  if (wv==self.webView) {
    self.progressBar.doubleValue=0; self.progressBar.hidden=NO;
    NSImage *xi=[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Stop"];
    xi=[xi imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
    [xi setTemplate:YES]; self.reloadButton.image=xi; self.reloadButton.toolTip=@"Stop";
    self.address.stringValue=wv.URL.absoluteString?:@"";
  }
  [self reloadTabBar];
}
// Fires when the response has committed and the new page has begun rendering.
// Update URL bar here to catch redirect chains: provisional URL might differ from the final one.
- (void)webView:(WKWebView *)wv didCommitNavigation:(WKNavigation *)nav {
  if (wv!=self.webView) return;
  NSString *url=wv.URL.absoluteString?:@"";
  self.address.stringValue=[self isInternalURL:url]?@"":url;
  [self updateSecurityIndicator:wv.URL];
}
- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {
  BBTab *tab=[self tabForWebView:wv]; if (!tab) return;
  tab.isLoading=NO;
  tab.title=wv.title.length?wv.title:@"New Tab";
  [self fetchFaviconForTab:tab];
  // Re-apply mute across page navigations so a muted tab stays muted on a fresh URL.
  if (tab.muted) [wv evaluateJavaScript:
    @"document.querySelectorAll('audio,video').forEach(function(m){m.muted=true;})"
    completionHandler:nil];
  // Translate offer: peek <html lang>, suggest translation if not in user's prefs.
  if (wv==self.webView && !tab.translateOffered) {
    [wv evaluateJavaScript:@"document.documentElement.lang||document.documentElement.getAttribute('xml:lang')||''"
      completionHandler:^(id r,NSError *e){
        NSString *lang=[r isKindOfClass:[NSString class]]?(NSString*)r:@"";
        if (lang.length) [self maybeOfferTranslateForLang:lang tab:tab];
      }];
  }
  NSString *url=wv.URL.absoluteString?:@"";
  if (wv==self.webView) {
    self.progressBar.hidden=YES;
    NSImage *ri=[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Reload"];
    ri=[ri imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]];
    [ri setTemplate:YES]; self.reloadButton.image=ri; self.reloadButton.toolTip=@"Reload";
    self.address.stringValue=[self isInternalURL:url]?@"":url;
    self.backButton.enabled=wv.canGoBack; self.forwardButton.enabled=wv.canGoForward;
    self.window.title=[self windowTitleForTab:tab];
    [self updateSecurityIndicator:wv.URL];
    [self updateStarButton];
    [self applyZoomForCurrentTab];
  }
  // Record navigation to network monitor
  if(wv.URL.host.length && !tab.isPrivate)
    BBNetworkRecord_push(wv.URL.host, url, @"navigation", [BBFirewall.shared decisionFor:[BBConnectionRecord etldForHost:wv.URL.host]]==BBFWBlock);
  // Record to history (async so it never blocks the main thread)
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
    [[BBHistoryStore shared] recordTitle:tab.title url:url];
  });
  // Capture server trust for cert inspector — private KVC. `_serverTrust` was
  // removed/renamed on newer WebKit (macOS 26 / WebKit 21623+), and valueForKey:
  // on an UNDEFINED key raises NSUndefinedKeyException (it does NOT return nil),
  // which would abort the app on every finished navigation. Guard it.
  if (wv==self.webView) {
    SecTrustRef trust=NULL;
    @try { trust=(__bridge SecTrustRef)[wv valueForKey:@"_serverTrust"]; }
    @catch (NSException *e) { trust=NULL; }
    if (trust) { CFRetain(trust); if(self.currentTrust) CFRelease(self.currentTrust); self.currentTrust=trust; }
    else        { if(self.currentTrust){ CFRelease(self.currentTrust); self.currentTrust=nil; } }
  }
  if ([self isStartPage:wv.URL]) [self injectTopSitesInto:wv];
  [self emitNav:@"navigation.committed" url:url reason:@"Navigation committed." private:tab.isPrivate];
  [self reloadTabBar];
}
- (NSString *)errorPageHTMLFor:(NSError *)err url:(NSURL *)url {
  NSString *title=@"Can't Connect to This Page";
  NSString *desc=@"BearBrowser can't load the page.";
  if ([err.domain isEqualToString:NSURLErrorDomain]) {
    switch (err.code) {
      case NSURLErrorNotConnectedToInternet:
      case NSURLErrorNetworkConnectionLost:
        title=@"No Internet Connection"; desc=@"Your device isn't connected to the internet. Check your network and try again."; break;
      case NSURLErrorCannotFindHost:
      case NSURLErrorDNSLookupFailed:
        title=@"Can't Find the Server"; desc=[NSString stringWithFormat:@"BearBrowser can't find the server at <b>%@</b>. Check the address and try again.",url.host?:@"??"]; break;
      case NSURLErrorTimedOut:
        title=@"Connection Timed Out"; desc=@"The server is taking too long to respond."; break;
      case NSURLErrorSecureConnectionFailed:
      case NSURLErrorServerCertificateUntrusted:
        title=@"Your Connection Is Not Private"; desc=@"Attackers might be trying to steal your information. BearBrowser blocked the connection."; break;
      default: desc=[err.localizedDescription stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]; break;
    }
  }
  return [NSString stringWithFormat:
    @"<!doctype html><html><head><meta charset='utf-8'>"
    @"<style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,sans-serif;"
    @"display:flex;align-items:center;justify-content:center;min-height:100vh;background:#f0f2f4;color:#1d1d1f}"
    @".card{max-width:520px;padding:40px;text-align:center}.icon{font-size:56px;margin-bottom:20px}"
    @"h1{font-size:22px;font-weight:600;margin-bottom:12px;color:#1d1d1f}p{font-size:15px;color:#6e6e73;"
    @"line-height:1.5;margin-bottom:24px}button{padding:10px 24px;border:none;border-radius:8px;"
    @"background:#1b6b45;color:#fff;font-size:15px;font-weight:500;cursor:pointer}"
    @"button:hover{background:#145835}@media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}"
    @"h1{color:#f5f5f7}.icon{filter:invert(.9)}}</style></head>"
    @"<body><div class='card'><div class='icon'>🔌</div><h1>%@</h1><p>%@</p>"
    @"<button onclick='location.reload()'>Try Again</button></div></body></html>",
    title, desc];
}
- (void)showErrorPage:(NSError *)err inWebView:(WKWebView *)wv {
  NSURL *url=wv.URL?:[NSURL URLWithString:@"about:blank"];
  NSString *html=[self errorPageHTMLFor:err url:url];
  [wv loadHTMLString:html baseURL:url];
}
- (void)webView:(WKWebView *)wv didFailProvisionalNavigation:(WKNavigation *)nav withError:(NSError *)err {
  // Cancelled (e.g., user hit Stop or a redirect cancelled the provisional) — not an error.
  if (err.code==NSURLErrorCancelled) return;
  BBTab *tab=[self tabForWebView:wv]; if(!tab) return; tab.isLoading=NO;
  if (wv==self.webView) {
    self.progressBar.hidden=YES;
    NSImage *ri=[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Reload"];
    ri=[ri imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]];
    [ri setTemplate:YES]; self.reloadButton.image=ri; self.reloadButton.toolTip=@"Reload";
  }
  [self showErrorPage:err inWebView:wv];
  [self reloadTabBar];
}
- (void)webView:(WKWebView *)wv didFailNavigation:(WKNavigation *)nav withError:(NSError *)err {
  if (err.code==NSURLErrorCancelled) return;
  BBTab *tab=[self tabForWebView:wv]; if(!tab) return; tab.isLoading=NO;
  if (wv==self.webView) {
    self.progressBar.hidden=YES;
    NSImage *ri=[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Reload"];
    ri=[ri imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]];
    [ri setTemplate:YES]; self.reloadButton.image=ri; self.reloadButton.toolTip=@"Reload";
  }
  [self showErrorPage:err inWebView:wv];
  [self reloadTabBar];
}
- (void)webView:(WKWebView *)wv didReceiveServerRedirectForProvisionalNavigation:(WKNavigation *)nav {
  if (wv==self.webView) { NSString *u=wv.URL.absoluteString?:@""; self.address.stringValue=[self isInternalURL:u]?@"":u; [self updateSecurityIndicator:wv.URL]; }
}

// ── Download delegate ─────────────────────────────────────────────────────────
- (BBDownloadItem *)downloadItemFor:(WKDownload *)dl {
  for (BBDownloadItem *i in self.downloadPanel.items) if(i.download==dl) return i;
  return nil;
}
- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)filename completionHandler:(void(^)(NSURL *))completionHandler {
  // Honor per-user download dir if Settings has saved one and it still exists.
  NSString *custom=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBDownloadDir"];
  BOOL isDir=NO;
  NSURL *dlDir;
  if (custom.length && [[NSFileManager defaultManager] fileExistsAtPath:custom isDirectory:&isDir] && isDir)
    dlDir=[NSURL fileURLWithPath:custom];
  else
    dlDir=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"]];
  [[NSFileManager defaultManager] createDirectoryAtURL:dlDir withIntermediateDirectories:YES attributes:nil error:nil];
  // SANITIZE the server-supplied filename: take only the last path component and
  // strip path separators so a malicious Content-Disposition (e.g. "../../foo")
  // can never escape ~/Downloads (path traversal).
  NSString *safe=filename.lastPathComponent;
  safe=[safe stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  safe=[safe stringByReplacingOccurrencesOfString:@":" withString:@"_"]; // HFS path separator
  if (!safe.length || [safe isEqualToString:@"."] || [safe isEqualToString:@".."]) safe=@"download";
  NSURL *dest=[dlDir URLByAppendingPathComponent:safe];
  NSInteger n=0; NSString *base=[safe stringByDeletingPathExtension]; NSString *ext=safe.pathExtension;
  while ([[NSFileManager defaultManager] fileExistsAtPath:dest.path]) {
    n++;
    dest=[dlDir URLByAppendingPathComponent:ext.length?[NSString stringWithFormat:@"%@ (%ld).%@",base,(long)n,ext]:[NSString stringWithFormat:@"%@ (%ld)",base,(long)n]];
  }
  // Belt-and-suspenders: never hand back a path outside the Downloads directory.
  if (![dest.URLByStandardizingPath.path hasPrefix:dlDir.URLByStandardizingPath.path])
    dest=[dlDir URLByAppendingPathComponent:@"download"];
  // Register in download panel
  BBDownloadItem *item=[BBDownloadItem new];
  item.filename=dest.lastPathComponent; item.destURL=dest; item.download=download;
  item.state=BBDownloadStateActive; item.startedAt=[NSDate date];
  item.totalBytes=response.expectedContentLength>0?response.expectedContentLength:0;
  dispatch_async(dispatch_get_main_queue(),^{ [self.downloadPanel addItem:item]; });
  completionHandler(dest);
  BBLog([NSString stringWithFormat:@"download started: %@",filename]);
}
- (void)downloadDidFinish:(WKDownload *)download {
  dispatch_async(dispatch_get_main_queue(),^{
    BBDownloadItem *item=[self downloadItemFor:download];
    if (item) {
      item.state=BBDownloadStateDone;
      NSDictionary *attr=[[NSFileManager defaultManager] attributesOfItemAtPath:item.destURL.path error:nil];
      if (attr) item.writtenBytes=[attr[NSFileSize] longLongValue];
      [self.downloadPanel refresh];
    }
    BBLog(@"download finished");
  });
}
- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
  dispatch_async(dispatch_get_main_queue(),^{
    BBDownloadItem *item=[self downloadItemFor:download];
    if (item) { item.state=BBDownloadStateFailed; item.errorMessage=error.localizedDescription; [self.downloadPanel refresh]; }
    BBLog([NSString stringWithFormat:@"download failed: %@",error.localizedDescription]);
  });
}

// ── Bear panel ────────────────────────────────────────────────────────────────
- (void)showBearPanel:(id)s {
  NSMenu *m=[[NSMenu alloc]init];
  [m addItemWithTitle:@"Summarize Page"          action:@selector(summarizePage:)          keyEquivalent:@""];
  [m addItemWithTitle:@"Propose Page Share"      action:@selector(proposePageShare:)       keyEquivalent:@""];
  [m addItemWithTitle:@"Create Memory Candidate" action:@selector(createMemoryCandidate:)  keyEquivalent:@""];
  [m addItem:[NSMenuItem separatorItem]];
  [m addItemWithTitle:@"Resolve Held Actions"    action:@selector(resolveHeld:)            keyEquivalent:@""];
  [m addItemWithTitle:@"Agent Server Status"     action:@selector(showAgentServerStatus:)  keyEquivalent:@""];
  [m addItemWithTitle:@"Sidecar Status"          action:@selector(openSidecarStatus:)      keyEquivalent:@""];
  NSButton *btn=(NSButton *)s;
  [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,btn.bounds.size.height+4) inView:btn];
}

// ── Governance ────────────────────────────────────────────────────────────────
- (NSString *)runCmd:(NSString *)cmd status:(int *)st {
  NSTask *t=[[NSTask alloc]init]; NSPipe *p=[NSPipe pipe];
  t.launchPath=@"/bin/bash"; t.arguments=@[@"-lc",[NSString stringWithFormat:@"PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; %@",cmd]];
  t.standardOutput=p; t.standardError=p; [t launch]; [t waitUntilExit];
  if(st) *st=t.terminationStatus;
  NSData *d=[[p fileHandleForReading] readDataToEndOfFile];
  return [[[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding]?:@"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
- (void)runCommand:(NSString *)cmd ok:(NSString *)ok {
  int st=0; [self runCmd:cmd status:&st];
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=st==0?ok:@"Command failed";
  a.informativeText=st==0?@"":@"Check ~/Library/Logs/BearBrowser/launcher.log";
  [a addButtonWithTitle:@"OK"]; [a beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)summarizePage:(id)s {
  [self.webView evaluateJavaScript:@"(document.body&&document.body.innerText?document.body.innerText:'').slice(0,12000)"
                 completionHandler:^(id r,NSError *e){
    if(e||![r isKindOfClass:[NSString class]]) return;
    NSString *dir=[BBSupportDir() stringByAppendingPathComponent:@"summaries"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *pt=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"visible-%@.txt",BBRandomHex(8)]];
    [(NSString*)r writeToFile:pt atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self runCommand:[NSString stringWithFormat:@"bearbrowser-page-summary create --text-file %@ --source-url %@",BBShellQuote(pt),BBShellQuote([self currentURLString])] ok:@"Page summary proposed"];
  }];
}
- (void)proposePageShare:(id)s {
  NSString *u=[self currentURLString];
  BBProposeAction(@"share_page_with_agent",@"page",@"native-propose-share",u,@"medium",@"hold",YES,@"Held page-share proposal.");
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Page share held";
  a.informativeText=@"Recorded a held share_page_with_agent action. Use Resolve Held to approve.";
  [a addButtonWithTitle:@"OK"]; [a beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)createMemoryCandidate:(id)s {
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Create memory candidate";
  NSTextField *f=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,420,28)];
  f.placeholderString=@"What should BearBrowser remember?"; a.accessoryView=f;
  [a addButtonWithTitle:@"Create"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if(rc!=NSAlertFirstButtonReturn||!f.stringValue.length) return;
    BBProposeAction(@"write_memory_candidate",@"memory",@"native-memory-candidate",[self currentURLString],@"medium",@"hold",YES,@"Held memory candidate.");
    BBCreateMemoryCandidate(f.stringValue,[self currentURLString],@"native-memory-candidate");
  }];
}
- (void)resolveHeld:(id)s {
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Resolve held state";
  [a addButtonWithTitle:@"Allow"]; [a addButtonWithTitle:@"Deny"];
  [a addButtonWithTitle:@"Commit Memory"]; [a addButtonWithTitle:@"Reject Memory"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    NSDictionary *cmds=@{
      @(NSAlertFirstButtonReturn):@"bearbrowser-resolve-action --latest-held --decision allow --actor-type human --actor-id native-shell --reason 'Allowed.'",
      @(NSAlertSecondButtonReturn):@"bearbrowser-resolve-action --latest-held --decision deny --actor-type human --actor-id native-shell --reason 'Denied.'",
      @(NSAlertThirdButtonReturn):@"bearbrowser-memory-candidate resolve --latest-candidate --decision commit --actor-type human --actor-id native-shell --reason 'Committed.'",
      @(NSAlertThirdButtonReturn+1):@"bearbrowser-memory-candidate resolve --latest-candidate --decision reject --actor-type human --actor-id native-shell --reason 'Rejected.'"
    };
    NSString *cmd=cmds[@(rc)]; if(cmd)[self runCommand:cmd ok:@"Done"];
  }];
}
- (void)showAgentServerStatus:(id)s {
  BBAgentServer *srv=[BBAgentServer shared];
  BOOL sockExists=[[NSFileManager defaultManager]fileExistsAtPath:srv.socketPath];
  NSString *tokenContent=[NSString stringWithContentsOfFile:srv.tokenPath
    encoding:NSUTF8StringEncoding error:nil]?:@"(not found)";
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Agent Server";
  a.informativeText=[NSString stringWithFormat:
    @"Socket: %@\nSocket exists: %@\n\nToken file: %@\n\nTo connect from Claude Code or a script:\n\n"
    @"TOKEN=$(cat \"%@\")\n"
    @"echo '{\"v\":1,\"token\":\"'$TOKEN'\",\"action\":\"observe.url\"}' | nc -U \"%@\"",
    srv.socketPath, sockExists?@"yes":@"no",
    srv.tokenPath, srv.tokenPath, srv.socketPath];
  [a addButtonWithTitle:@"Copy nc command"];
  [a addButtonWithTitle:@"OK"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){
    if(r==NSAlertFirstButtonReturn){
      NSString *cmd=[NSString stringWithFormat:
        @"TOKEN=$(cat \"%@\"); echo '{\"v\":1,\"token\":\"'$TOKEN'\",\"action\":\"observe.url\"}' | nc -U \"%@\"",
        srv.tokenPath, srv.socketPath];
      [[NSPasteboard generalPasteboard]clearContents];
      [[NSPasteboard generalPasteboard]setString:cmd forType:NSPasteboardTypeString];
    }
  }];
}
- (void)openSidecarStatus:(id)s {
  int st=0; NSString *out=[self runCmd:@"bearbrowser-sidecar-open --print-url" status:&st];
  if(st==0&&[out hasPrefix:@"http://127.0.0.1:"])
    [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:out]]];
  else
    [self.webView loadHTMLString:@"<h1>BearBrowser Sidecar</h1><p>Not running.</p>" baseURL:nil];
}

@end

int main(int argc,const char *argv[]) {
  @autoreleasepool {
    NSApplication *app=[NSApplication sharedApplication];
    [app setDelegate:[[BBDelegate alloc]init]];
    [app run];
  }
  return 0;
}
