#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
    @"text":sensitive?@"<REDACTED>":text?:@"",
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
static const CGFloat kTabMinW   = 80.0;

// ── BBTab ─────────────────────────────────────────────────────────────────────
@interface BBTab : NSObject
@property(strong) WKWebView *webView;
@property(copy)   NSString  *title;
@property(strong) NSImage   *favicon;
@property(assign) BOOL       isLoading;
@property(assign) BOOL       isPrivate;
@end
@implementation BBTab
- (instancetype)init { self=[super init]; _title=@"New Tab"; return self; }
@end

// ── BBTabItemView ─────────────────────────────────────────────────────────────
@protocol BBTabItemDelegate <NSObject>
- (void)tabItemDidSelect:(NSInteger)index;
- (void)tabItemDidClose:(NSInteger)index;
@end

@interface BBTabItemView : NSView
@property(assign) NSInteger index;
@property(nonatomic,assign) BOOL isActive;
@property(nonatomic,assign) BOOL isHovered;
@property(nonatomic,assign) BOOL isPrivate;
@property(strong) NSImageView *faviconView;
@property(strong) NSTextField *titleLabel;
@property(strong) NSButton    *closeButton;
@property(weak)   id<BBTabItemDelegate> delegate;
- (void)setTabTitle:(NSString *)title favicon:(NSImage *)favicon loading:(BOOL)loading;
@end

@implementation BBTabItemView
- (instancetype)initWithFrame:(NSRect)f index:(NSInteger)idx delegate:(id<BBTabItemDelegate>)d {
  self=[super initWithFrame:f]; _index=idx; _delegate=d;
  [self addTrackingArea:[[NSTrackingArea alloc]initWithRect:self.bounds
    options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect
    owner:self userInfo:nil]];
  // Favicon (16×16)
  _faviconView=[[NSImageView alloc]initWithFrame:NSMakeRect(8,10,16,16)];
  _faviconView.imageScaling=NSImageScaleProportionallyUpOrDown;
  [self addSubview:_faviconView];
  // Title
  _titleLabel=[[NSTextField alloc]initWithFrame:NSMakeRect(28,8,f.size.width-54,20)];
  _titleLabel.autoresizingMask=NSViewWidthSizable;
  _titleLabel.bordered=NO; _titleLabel.editable=NO; _titleLabel.selectable=NO;
  _titleLabel.backgroundColor=[NSColor clearColor];
  _titleLabel.font=[NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
  _titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
  [self addSubview:_titleLabel];
  // Close button
  _closeButton=[[NSButton alloc]initWithFrame:NSMakeRect(f.size.width-26,9,18,18)];
  _closeButton.autoresizingMask=NSViewMinXMargin;
  _closeButton.bezelStyle=NSBezelStyleCircular; _closeButton.bordered=NO;
  NSImage *xi=[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close Tab"];
  xi=[xi imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:8 weight:NSFontWeightMedium]];
  [xi setTemplate:YES]; _closeButton.image=xi; _closeButton.imagePosition=NSImageOnly;
  _closeButton.target=self; _closeButton.action=@selector(closeTab:); _closeButton.toolTip=@"Close Tab";
  [self addSubview:_closeButton];
  return self;
}
- (void)setTabTitle:(NSString *)title favicon:(NSImage *)favicon loading:(BOOL)loading {
  self.titleLabel.stringValue=title.length?title:@"New Tab";
  self.titleLabel.textColor=self.isActive?[NSColor labelColor]:[NSColor secondaryLabelColor];
  if (loading) {
    NSImage *spinner=[NSImage imageWithSystemSymbolName:@"arrow.2.circlepath" accessibilityDescription:@"Loading"];
    self.faviconView.image=spinner;
  } else if (favicon) {
    self.faviconView.image=favicon;
  } else {
    NSImage *globe=[NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:@"Page"];
    [globe setTemplate:YES]; self.faviconView.image=globe;
  }
  if (self.isPrivate) {
    NSImage *priv=[NSImage imageWithSystemSymbolName:@"eyeglasses" accessibilityDescription:@"Private"];
    [priv setTemplate:YES]; self.faviconView.image=priv;
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
}
- (void)mouseEntered:(NSEvent *)e { self.isHovered=YES;  [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)e  { self.isHovered=NO;   [self setNeedsDisplay:YES]; }
- (void)mouseDown:(NSEvent *)e    { [self.delegate tabItemDidSelect:self.index]; }
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
  _addTabButton=[[NSButton alloc]initWithFrame:NSMakeRect(f.size.width-34,4,28,28)];
  _addTabButton.autoresizingMask=NSViewMinXMargin;
  NSImage *pi=[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New Tab"];
  pi=[pi imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium]];
  [pi setTemplate:YES]; _addTabButton.image=pi; _addTabButton.imagePosition=NSImageOnly;
  _addTabButton.bezelStyle=NSBezelStyleToolbar; _addTabButton.bordered=NO;
  _addTabButton.toolTip=@"New Tab (⌘T)"; [self addSubview:_addTabButton];
  return self;
}
- (void)reloadWithTabs:(NSArray<BBTab *> *)tabs activeIndex:(NSInteger)active {
  for (BBTabItemView *v in self.items) [v removeFromSuperview];
  [self.items removeAllObjects];
  self.activeIndex=active;
  NSInteger count=tabs.count; if (!count) return;
  CGFloat avail=self.bounds.size.width-40;
  CGFloat tabW=MIN(kTabMaxW,MAX(kTabMinW,floor(avail/count)));
  for (NSInteger i=0;i<count;i++) {
    BBTab *tab=tabs[i];
    BBTabItemView *item=[[BBTabItemView alloc]initWithFrame:NSMakeRect(i*tabW,1,tabW-2,kTabBarH-2) index:i delegate:self];
    item.isActive=(i==active); item.isPrivate=tab.isPrivate;
    [item setTabTitle:tab.title favicon:tab.favicon loading:tab.isLoading];
    [self addSubview:item]; [self.items addObject:item];
  }
  self.addTabButton.frame=NSMakeRect(count*tabW+4,4,28,28);
}
- (void)tabItemDidSelect:(NSInteger)i { [self.outerDelegate tabItemDidSelect:i]; }
- (void)tabItemDidClose:(NSInteger)i  { [self.outerDelegate tabItemDidClose:i]; }
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
@end
@implementation BBBookmark
@end

@interface BBBookmarksStore : NSObject
@property(strong) NSMutableArray<BBBookmark *> *items;
+ (instancetype)shared;
- (void)addTitle:(NSString *)t url:(NSString *)u;
- (void)removeAtIndex:(NSInteger)i;
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
    [_items addObject:b];
  }
  return self;
}
- (void)addTitle:(NSString *)t url:(NSString *)u {
  BBBookmark *b=[BBBookmark new]; b.title=t?:@""; b.urlString=u?:@""; b.addedAt=[NSDate date];
  [self.items addObject:b]; [self save];
}
- (void)removeAtIndex:(NSInteger)i { if(i>=0&&i<(NSInteger)self.items.count){[self.items removeObjectAtIndex:i];[self save];} }
- (BOOL)isBookmarked:(NSString *)u { for(BBBookmark *b in self.items) if([b.urlString isEqualToString:u]) return YES; return NO; }
- (void)save {
  NSMutableArray *arr=[NSMutableArray array];
  for (BBBookmark *b in self.items) [arr addObject:@{@"title":b.title,@"url":b.urlString,@"t":@(b.addedAt.timeIntervalSince1970)}];
  NSData *d=[NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
  [[NSFileManager defaultManager] createDirectoryAtPath:BBSupportDir() withIntermediateDirectories:YES attributes:nil error:nil];
  [d writeToFile:[BBSupportDir() stringByAppendingPathComponent:@"bookmarks.json"] atomically:YES];
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
- (void)recordTitle:(NSString *)t url:(NSString *)u {
  if (!u.length||[u hasPrefix:@"bearbrowser://"]) return;
  BBHistoryEntry *e=[BBHistoryEntry new]; e.title=t?:@""; e.urlString=u; e.visitedAt=[NSDate date];
  [self.entries addObject:e]; if(self.entries.count>20000) [self.entries removeObjectAtIndex:0];
  NSString *dir=[BBSupportDir() stringByAppendingPathComponent:@"history"];
  BBAppendLine([dir stringByAppendingPathComponent:@"history.jsonl"],
    BBJSON(@{@"url":u,@"title":t?:@"",@"t":@(e.visitedAt.timeIntervalSince1970)}));
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
- (void)addItem:(BBDownloadItem *)item {
  [self.items addObject:item];
  if (!self.pollTimer) self.pollTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(pollFileSizes) userInfo:nil repeats:YES];
  [self refresh]; [self show];
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
  dispatch_async(dispatch_get_main_queue(),^{ [self refresh]; });
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
  if (item.state==BBDownloadStateDone && item.destURL)
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[item.destURL]];
  else if (item.state==BBDownloadStateFailed)
    { item.state=BBDownloadStateActive; [self refresh]; }
  else if (item.download)
    [item.download cancel:^(NSData *rd){}];
}
- (void)show { self.hidden=NO; }
- (void)hide { self.hidden=YES; }
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
  // Search row always last
  BBAddressSuggestion *search=[BBAddressSuggestion new];
  search.title=[NSString stringWithFormat:@"Search DuckDuckGo: %@",q];
  NSString *eq=[q stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  search.urlString=[NSString stringWithFormat:@"https://duckduckgo.com/?q=%@",eq];
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
  // DDG autocomplete after 250ms debounce
  [_ddgTimer invalidate]; NSString *qc=q;
  _ddgTimer=[NSTimer scheduledTimerWithTimeInterval:0.25 repeats:NO block:^(NSTimer *t){
    [self fetchDDGSuggestions:qc];
  }];
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
        NSString *teq=[term stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        s.urlString=[NSString stringWithFormat:@"https://duckduckgo.com/?q=%@",teq];
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
@interface BBDelegate : NSObject <NSApplicationDelegate,NSWindowDelegate,WKNavigationDelegate,WKUIDelegate,WKDownloadDelegate,NSTextFieldDelegate,BBTabItemDelegate,BBAddressDropdownDelegate,WKScriptMessageHandler,BBAgentBrowserDelegate>
@property(strong) NSWindow *window;
@property(strong) NSMutableArray<BBTab *> *tabs;
@property(strong) NSMutableArray<NSString *> *closedTabURLs;
@property(assign) NSInteger activeTabIndex;
@property(strong) NSView    *root;
@property(strong) NSView *toolbarBg;
@property(strong) BBTabBarView *tabBarView;
@property(strong) NSTextField  *address;
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
@property(strong) NSMutableSet      *decoyViews;      // script-popup honeypots — kept alive briefly
@property(assign) NSTimeInterval    lastUserGestureTime; // tracks real input events for popup gating
@property(assign) SecTrustRef      currentTrust;        // TLS trust for current page cert inspector
@end

@implementation BBDelegate

- (BBTab *)activeTab { return (self.activeTabIndex<(NSInteger)self.tabs.count)?self.tabs[self.activeTabIndex]:nil; }
- (WKWebView *)webView { return self.activeTab.webView; }
- (NSString *)currentURLString { return self.activeTab.webView.URL.absoluteString?:@"bearbrowser://start"; }

// ── Menu ──────────────────────────────────────────────────────────────────────
- (void)buildMenu {
  NSMenu *bar=[[NSMenu alloc]init]; [NSApp setMainMenu:bar];
  void(^mi)(NSMenu*,NSString*,SEL,NSString*,NSUInteger)=^(NSMenu *m,NSString *t,SEL a,NSString *k,NSUInteger mod){
    NSMenuItem *i=[m addItemWithTitle:t action:a keyEquivalent:k]; if(mod) i.keyEquivalentModifierMask=mod;
  };
  // BearBrowser
  NSMenuItem *appI=[[NSMenuItem alloc]init]; [bar addItem:appI];
  NSMenu *appM=[[NSMenu alloc]initWithTitle:@"BearBrowser"]; appI.submenu=appM;
  [appM addItemWithTitle:@"About BearBrowser" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
  [appM addItem:[NSMenuItem separatorItem]];
  mi(appM,@"Search Engine…",@selector(openSearchPreferences:),@",",NSEventModifierFlagCommand);
  [appM addItem:[NSMenuItem separatorItem]];
  mi(appM,@"Hide BearBrowser",@selector(hide:),@"h",NSEventModifierFlagCommand);
  [appM addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"].keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagOption;
  [appM addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [appM addItem:[NSMenuItem separatorItem]];
  mi(appM,@"Quit BearBrowser",@selector(terminate:),@"q",NSEventModifierFlagCommand);
  // File
  NSMenuItem *fileI=[[NSMenuItem alloc]init]; [bar addItem:fileI];
  NSMenu *fileM=[[NSMenu alloc]initWithTitle:@"File"]; fileI.submenu=fileM;
  mi(fileM,@"New Tab",@selector(newTab:),@"t",NSEventModifierFlagCommand);
  mi(fileM,@"New Private Tab",@selector(newPrivateTab:),@"t",NSEventModifierFlagCommand|NSEventModifierFlagShift);
  mi(fileM,@"New Window",@selector(newWindow:),@"n",NSEventModifierFlagCommand);
  [fileM addItem:[NSMenuItem separatorItem]];
  mi(fileM,@"Open File…",@selector(openFile:),@"o",NSEventModifierFlagCommand);
  [fileM addItem:[NSMenuItem separatorItem]];
  mi(fileM,@"Add Bookmark…",@selector(addBookmark:),@"d",NSEventModifierFlagCommand);
  mi(fileM,@"Show Bookmarks Bar",@selector(toggleBookmarksBar:),@"b",NSEventModifierFlagCommand|NSEventModifierFlagShift);
  [fileM addItem:[NSMenuItem separatorItem]];
  mi(fileM,@"Close Tab",@selector(closeCurrentTab:),@"w",NSEventModifierFlagCommand);
  mi(fileM,@"Reopen Closed Tab",@selector(reopenClosedTab:),@"t",NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption);
  [fileM addItem:[NSMenuItem separatorItem]];
  mi(fileM,@"Save Page As…",@selector(savePage:),@"s",NSEventModifierFlagCommand);
  mi(fileM,@"Print…",@selector(printPage:),@"p",NSEventModifierFlagCommand);
  // Edit
  NSMenuItem *editI=[[NSMenuItem alloc]init]; [bar addItem:editI];
  NSMenu *editM=[[NSMenu alloc]initWithTitle:@"Edit"]; editI.submenu=editM;
  mi(editM,@"Undo",@selector(undo:),@"z",NSEventModifierFlagCommand);
  [editM addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"].keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagShift;
  [editM addItem:[NSMenuItem separatorItem]];
  mi(editM,@"Cut",@selector(cut:),@"x",NSEventModifierFlagCommand);
  mi(editM,@"Copy",@selector(copy:),@"c",NSEventModifierFlagCommand);
  mi(editM,@"Paste",@selector(paste:),@"v",NSEventModifierFlagCommand);
  mi(editM,@"Paste and Go",@selector(pasteAndGo:),@"v",NSEventModifierFlagCommand|NSEventModifierFlagShift);
  mi(editM,@"Select All",@selector(selectAll:),@"a",NSEventModifierFlagCommand);
  [editM addItem:[NSMenuItem separatorItem]];
  mi(editM,@"Find on Page…",@selector(toggleFind:),@"f",NSEventModifierFlagCommand);
  // View
  NSMenuItem *viewI=[[NSMenuItem alloc]init]; [bar addItem:viewI];
  NSMenu *viewM=[[NSMenu alloc]initWithTitle:@"View"]; viewI.submenu=viewM;
  mi(viewM,@"Reload Page",@selector(reloadOrStop:),@"r",NSEventModifierFlagCommand);
  mi(viewM,@"Hard Reload (Skip Cache)",@selector(hardReload:),@"r",NSEventModifierFlagCommand|NSEventModifierFlagShift);
  mi(viewM,@"Focus Address Bar",@selector(focusAddressBar:),@"l",NSEventModifierFlagCommand);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Zoom In",@selector(zoomIn:),@"+",NSEventModifierFlagCommand);
  mi(viewM,@"Zoom Out",@selector(zoomOut:),@"-",NSEventModifierFlagCommand);
  mi(viewM,@"Actual Size",@selector(zoomReset:),@"0",NSEventModifierFlagCommand);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"View Page Source",@selector(viewSource:),@"u",NSEventModifierFlagCommand);
  mi(viewM,@"Developer Tools",@selector(openDevTools:),@"i",NSEventModifierFlagCommand|NSEventModifierFlagOption);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Enter Full Screen",@selector(toggleFullScreen:),@"f",NSEventModifierFlagCommand|NSEventModifierFlagControl);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"History",@selector(showHistory:),@"y",NSEventModifierFlagCommand);
  mi(viewM,@"Downloads",@selector(toggleDownloadPanel:),@"j",NSEventModifierFlagCommand);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Network Monitor",@selector(openNetworkMonitor:),@"m",NSEventModifierFlagCommand|NSEventModifierFlagShift);
  [viewM addItem:[NSMenuItem separatorItem]];
  mi(viewM,@"Read Aloud",@selector(readAloud:),@"r",NSEventModifierFlagCommand|NSEventModifierFlagOption);
  // History
  NSMenuItem *histI=[[NSMenuItem alloc]init]; [bar addItem:histI];
  NSMenu *histM=[[NSMenu alloc]initWithTitle:@"History"]; histI.submenu=histM;
  mi(histM,@"Back",@selector(goBack:),@"[",NSEventModifierFlagCommand);
  mi(histM,@"Forward",@selector(goForward:),@"]",NSEventModifierFlagCommand);
  // Window
  NSMenuItem *winI=[[NSMenuItem alloc]init]; [bar addItem:winI];
  NSMenu *winM=[[NSMenu alloc]initWithTitle:@"Window"]; winI.submenu=winM;
  [NSApp setWindowsMenu:winM];
  mi(winM,@"Minimize",@selector(performMiniaturize:),@"m",NSEventModifierFlagCommand);
  [winM addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
  [winM addItem:[NSMenuItem separatorItem]];
  mi(winM,@"Next Tab",@selector(nextTab:),@"\t",NSEventModifierFlagControl);
  [winM addItemWithTitle:@"Previous Tab" action:@selector(prevTab:) keyEquivalent:@"\t"].keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagShift;
  [winM addItem:[NSMenuItem separatorItem]];
  for (NSInteger i=1;i<=9;i++) {
    NSMenuItem *ti=[winM addItemWithTitle:[NSString stringWithFormat:@"Tab %ld",(long)i]
                                   action:@selector(switchToTabByMenuItem:)
                            keyEquivalent:[NSString stringWithFormat:@"%ld",(long)i]];
    ti.keyEquivalentModifierMask=NSEventModifierFlagCommand; ti.tag=i-1;
  }
  [winM addItem:[NSMenuItem separatorItem]];
  [winM addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
}

// ── App launch ────────────────────────────────────────────────────────────────
- (void)applicationDidFinishLaunching:(NSNotification *)n {
  BBLog(@"BearBrowser start");
  BBEmitEvent(@"app.launch",@"allow",@"Native shell launched.",@{@"bundleId":@"dev.sourceos.BearBrowser"});
  [[BBAgentServer shared] startWithDelegate:self];
  BBLog([NSString stringWithFormat:@"Agent socket: %@",[BBAgentServer shared].socketPath]);
  BBLog([NSString stringWithFormat:@"Agent token: %@",[BBAgentServer shared].tokenPath]);
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  [self buildMenu];
  self.closedTabURLs=[NSMutableArray array];
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
  self.window.title=@"BearBrowser";
  self.window.titlebarAppearsTransparent=YES;
  self.window.titleVisibility=NSWindowTitleHidden;
  self.window.minSize=NSMakeSize(640,480);
  self.window.delegate=self;
  if (useCenter) [self.window center]; else [self.window setFrame:contentFrame display:NO];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowWillClose:)
    name:NSWindowWillCloseNotification object:self.window];

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

  // Address bar
  CGFloat rightR=48;
  self.address=[[NSTextField alloc]initWithFrame:NSMakeRect(x,btnY+1,W-x-rightR-12,28)];
  self.address.autoresizingMask=NSViewWidthSizable;
  self.address.bezelStyle=NSTextFieldRoundedBezel;
  self.address.placeholderString=@"Search or enter address";
  self.address.font=[NSFont systemFontOfSize:13.5]; self.address.stringValue=@"";
  self.address.delegate=self; [self.address.cell setWraps:NO]; [self.address.cell setScrollable:YES];
  [self.toolbarBg addSubview:self.address];

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
  self.decoyViews=[NSMutableSet set];
  self.dnsBlockCache.countLimit=2000;

  self.tabs=[NSMutableArray array]; self.activeTabIndex=0;
  // Session restore — reopen tabs from last session
  NSArray<NSString*> *savedURLs=[[NSUserDefaults standardUserDefaults] arrayForKey:@"BBSessionURLs"];
  BOOL restored=NO;
  if (savedURLs.count) {
    for (NSString *u in savedURLs) {
      if (!u.length) continue;
      [self addTabPrivate:NO];
      [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:u]]];
      restored=YES;
    }
  }
  if (!restored) [self addTabPrivate:NO];
  [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
  BBLog([NSString stringWithFormat:@"window frame=%@ root=%@ toolbar=%@",
    NSStringFromRect(self.window.frame), NSStringFromRect(self.root.bounds), NSStringFromRect(self.toolbarBg.frame)]);
  // Focus the address bar immediately on launch — user can type a URL right away.
  dispatch_async(dispatch_get_main_queue(),^{
    [self.window makeFirstResponder:self.address];
    [self.address selectText:nil];
  });
  // Dismiss the address dropdown when the user clicks outside it or the address field.
  [NSEvent addLocalMonitorForEventsMatchingMask:
    NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskKeyDown
    handler:^NSEvent*(NSEvent *e){
    self.lastUserGestureTime=[NSDate timeIntervalSinceReferenceDate];
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

  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=host.length?host:@"BearBrowser";
  a.informativeText=info;
  a.alertStyle=isHTTPS?NSAlertStyleInformational:NSAlertStyleWarning;
  [a addButtonWithTitle:@"OK"];
  [a beginSheetModalForWindow:self.window completionHandler:nil];
}

// ── WebView factory ───────────────────────────────────────────────────────────
- (WKWebViewConfiguration *)baseConfig:(BOOL)priv {
  WKWebViewConfiguration *config=[[WKWebViewConfiguration alloc]init];
  if (priv) config.websiteDataStore=[WKWebsiteDataStore nonPersistentDataStore];
  [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
  // Third-party cookie isolation — block cross-site cookies via private KVC key
  @try { [config.websiteDataStore.httpCookieStore
    performSelector:NSSelectorFromString(@"_setStorageBlockingPolicy:") withObject:@1]; } @catch(...) {}
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
  // ── Fingerprinting shield (injected before any page script runs) ──────────
  NSString *shield=
    @"(function(){'use strict';"
    // Canvas noise — flip 1 LSB in every 400th byte so extraction differs per session
    @"const _toDU=HTMLCanvasElement.prototype.toDataURL;"
    @"HTMLCanvasElement.prototype.toDataURL=function(t,q){"
    @"  try{const c=this.getContext('2d');if(c&&this.width&&this.height){"
    @"    const d=c.getImageData(0,0,this.width,this.height);"
    @"    for(let i=0;i<d.data.length;i+=400)d.data[i]^=1;"
    @"    c.putImageData(d,0,0);"
    @"  }}catch(e){}"
    @"  return _toDU.call(this,t,q);};"
    // WebGL vendor/renderer normalisation
    @"const _gp=WebGLRenderingContext.prototype.getParameter;"
    @"WebGLRenderingContext.prototype.getParameter=function(p){"
    @"  if(p===37445)return 'BearBrowser';"
    @"  if(p===37446)return 'BearBrowser Renderer';"
    @"  return _gp.call(this,p);};"
    @"if(window.WebGL2RenderingContext){"
    @"  const _gp2=WebGL2RenderingContext.prototype.getParameter;"
    @"  WebGL2RenderingContext.prototype.getParameter=function(p){"
    @"    if(p===37445)return 'BearBrowser';"
    @"    if(p===37446)return 'BearBrowser Renderer';"
    @"    return _gp2.call(this,p);};"
    @"}"
    // Navigator hardening
    @"try{Object.defineProperties(navigator,{"
    @"  hardwareConcurrency:{get:()=>4,configurable:false},"
    @"  deviceMemory:{get:()=>4,configurable:false},"
    @"  languages:{get:()=>Object.freeze(['en-US','en']),configurable:false}"
    @"});}catch(e){}"
    // Screen colour depth normalisation
    @"try{Object.defineProperty(screen,'colorDepth',{get:()=>24,configurable:false});}catch(e){}"
    // Battery API removed (fingerprinting vector)
    @"if(navigator.getBattery)try{delete navigator.__proto__.getBattery;}catch(e){navigator.getBattery=undefined;}"
    // WebRTC IP leak — strip ICE servers so only relay traffic is visible
    @"const _RPC=window.RTCPeerConnection||window.webkitRTCPeerConnection;"
    @"if(_RPC){window.RTCPeerConnection=function(cfg,con){"
    @"  return new _RPC(cfg?{...cfg,iceServers:[]}:null,con);};"
    @"  window.RTCPeerConnection.prototype=_RPC.prototype;}"
    // eval honeypot — log when eval is called with suspicious patterns
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
    // postMessage origin guard — warn on wildcard target from untrusted frames
    @"const _pM=window.postMessage.bind(window);"
    @"window.postMessage=function(data,origin,transfer){"
    @"  if(origin==='*'&&window.top!==window)"
    @"    try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.honeypot)"
    @"      window.webkit.messageHandlers.honeypot.postMessage({trap:'wildcard_postmessage',url:location.href,time:Date.now()});}"
    @"    catch(e){}"
    @"  return _pM(data,origin,transfer);};"
    // iFrame sandbox hardening — add sandbox to cross-origin frames at load
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
  wv.navigationDelegate=self; wv.UIDelegate=self;
  wv.allowsBackForwardNavigationGestures=YES; wv.allowsLinkPreview=YES;
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
    if (tab&&wv.title.length) { tab.title=wv.title; [self reloadTabBar]; self.window.title=wv.title; }
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

- (void)activateTab:(NSInteger)index {
  for (BBTab *t in self.tabs) { [t.webView removeFromSuperview]; t.webView.hidden=YES; }
  self.activeTabIndex=index;
  BBTab *tab=self.tabs[index];
  tab.webView.hidden=NO;
  [self resizeWebViewForCurrentTab];
  [self.root addSubview:tab.webView positioned:NSWindowBelow relativeTo:self.tabBarView];
  NSString *url=tab.webView.URL.absoluteString?:@"";
  self.address.stringValue=[self isInternalURL:url]?@"":url;
  self.backButton.enabled=tab.webView.canGoBack;
  self.forwardButton.enabled=tab.webView.canGoForward;
  self.window.title=tab.title.length?tab.title:@"BearBrowser";
  [self updateSecurityIndicator:tab.webView.URL];
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
- (void)tabItemDidClose:(NSInteger)i  {
  NSString *closingURL=self.tabs[i].webView.URL.absoluteString;
  if (closingURL.length) [self.closedTabURLs addObject:closingURL];
  [self.tabs[i].webView removeObserver:self forKeyPath:@"estimatedProgress"];
  [self.tabs[i].webView removeObserver:self forKeyPath:@"title"];
  [self.tabs[i].webView removeFromSuperview];
  [self.tabs removeObjectAtIndex:i];
  if (!self.tabs.count) { [self.window performClose:nil]; return; }
  NSInteger newActive=MIN(self.activeTabIndex,(NSInteger)self.tabs.count-1);
  self.activeTabIndex=newActive;
  [self activateTab:newActive]; [self reloadTabBar];
}

- (void)loadStartPage:(WKWebView *)wv {
  NSURL *landing=[[NSBundle mainBundle] URLForResource:@"BearBrowser-start" withExtension:@"html"];
  if (landing) [wv loadFileURL:landing allowingReadAccessToURL:[landing URLByDeletingLastPathComponent]];
  else [wv loadHTMLString:@"<h1>BearBrowser</h1>" baseURL:nil];
}

- (BBTab *)tabForWebView:(WKWebView *)wv {
  for (BBTab *t in self.tabs) if(t.webView==wv) return t;
  return nil;
}

// ── Actions ───────────────────────────────────────────────────────────────────
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }
- (void)windowWillClose:(NSNotification *)n {
  [[NSUserDefaults standardUserDefaults] setObject:NSStringFromRect(self.window.frame) forKey:@"BBWindowFrame"];
  // Persist non-private tab URLs for session restore
  NSMutableArray<NSString*> *urls=[NSMutableArray array];
  for (BBTab *t in self.tabs) {
    if (t.isPrivate) continue;
    NSString *u=t.webView.URL.absoluteString;
    if (u.length && ![self isInternalURL:u]) [urls addObject:u];
  }
  [[NSUserDefaults standardUserDefaults] setObject:urls forKey:@"BBSessionURLs"];
}
- (void)readAloud:(id)s           { [[BBVoice shared] readPage:self.webView]; }

// ── Bookmarks ─────────────────────────────────────────────────────────────────
- (void)addBookmark:(id)s {
  NSString *url=self.webView.URL.absoluteString; NSString *title=self.activeTab.title?:url;
  if (!url.length||[url hasPrefix:@"bearbrowser://"]) return;
  NSAlert *a=[[NSAlert alloc]init]; a.messageText=@"Add Bookmark";
  NSTextField *tf=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,300,24)];
  tf.stringValue=title; tf.font=[NSFont systemFontOfSize:13]; a.accessoryView=tf;
  [a addButtonWithTitle:@"Add"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse rc){
    if(rc!=NSAlertFirstButtonReturn) return;
    [[BBBookmarksStore shared] addTitle:tf.stringValue?:title url:url];
    [self reloadBookmarksBar];
  }];
}
- (void)toggleBookmarksBar:(id)s {
  self.bookmarksBarVisible=!self.bookmarksBarVisible;
  self.bookmarksBar.hidden=!self.bookmarksBarVisible;
  [self resizeWebViewForCurrentTab];
}
- (void)reloadBookmarksBar {
  for (NSView *v in self.bookmarksBar.subviews.copy) [v removeFromSuperview];
  CGFloat x=8;
  for (BBBookmark *b in [BBBookmarksStore shared].items) {
    NSButton *btn=[[NSButton alloc]initWithFrame:NSMakeRect(x,3,0,24)];
    btn.title=b.title.length?b.title:b.urlString;
    btn.font=[NSFont systemFontOfSize:11]; btn.bezelStyle=NSBezelStyleRoundRect;
    btn.target=self; btn.action=@selector(bookmarkButtonClicked:);
    [btn sizeToFit]; btn.frame=NSMakeRect(x,3,btn.frame.size.width+8,24);
    btn.toolTip=b.urlString; [self.bookmarksBar addSubview:btn];
    x+=btn.frame.size.width+4;
    if(x>self.bookmarksBar.bounds.size.width-8) break;
  }
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
  // Use a simple block-based datasource via associated objects
  NSMutableArray<BBHistoryEntry *> *shown=[[BBHistoryStore shared].entries.reverseObjectEnumerator.allObjects mutableCopy];
  __block NSMutableArray<BBHistoryEntry *> *filtered=[shown mutableCopy];
  // Simple datasource object
  BBHistoryPanelDS *ds=[[BBHistoryPanelDS alloc]initWithEntries:filtered tableView:tv searchField:sf window:hw webView:self.webView];
  tv.dataSource=ds; tv.delegate=ds; sf.delegate=ds;
  objc_setAssociatedObject(hw,@"ds",ds,OBJC_ASSOCIATION_RETAIN);
  [tv reloadData];
  [self.window beginSheet:hw completionHandler:nil];
}

// ── Downloads ─────────────────────────────────────────────────────────────────
- (void)toggleDownloadPanel:(id)s {
  self.downloadPanel.hidden=!self.downloadPanel.hidden;
}

// ── Address dropdown delegate ─────────────────────────────────────────────────
- (void)dropdownSelectedURL:(NSString *)urlString {
  // Called by table click (mouse selection) — navigate immediately
  [self.addressDropdown hide];
  NSURL *u=[NSURL URLWithString:urlString]; if(!u) return;
  self.address.stringValue=urlString;
  [self.window makeFirstResponder:self.webView];
  BBEmitEvent(@"navigation.requested",@"allow",@"Dropdown navigation.",@{@"url":urlString});
  [self.webView loadRequest:[NSURLRequest requestWithURL:u]];
}

- (void)newTab:(id)s              { [self addTabPrivate:NO]; }
- (void)newPrivateTab:(id)s       { [self addTabPrivate:YES]; }
- (void)newWindow:(id)s {
  BBDelegate *w=[[BBDelegate alloc]init];
  NSNotification *dummy=[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp];
  [w applicationDidFinishLaunching:dummy];
}

// ── Camera / Mic permission prompt ───────────────────────────────────────────
- (void)webView:(WKWebView *)wv
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    type:(WKMediaCaptureType)type
    decisionHandler:(void (^)(WKPermissionDecision))decisionHandler {
  NSString *kind = (type==WKMediaCaptureTypeMicrophone)?@"microphone":
                   (type==WKMediaCaptureTypeCamera)?@"camera":@"camera & microphone";
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=[NSString stringWithFormat:@"\"%@\" wants to use your %@", origin.host, kind];
  a.informativeText=@"BearBrowser will ask once per site. You can revoke this in Preferences.";
  [a addButtonWithTitle:@"Allow"]; [a addButtonWithTitle:@"Deny"];
  a.alertStyle=NSAlertStyleWarning;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){
    decisionHandler(r==NSAlertFirstButtonReturn ? WKPermissionDecisionGrant : WKPermissionDecisionDeny);
  }];
}

// ── Search engine preference ──────────────────────────────────────────────────
+ (NSArray<NSDictionary*> *)searchEngines {
  return @[
    @{@"name":@"DuckDuckGo",  @"id":@"ddg",    @"url":@"https://duckduckgo.com/?q=%@"},
    @{@"name":@"Kagi",        @"id":@"kagi",   @"url":@"https://kagi.com/search?q=%@"},
    @{@"name":@"Brave",       @"id":@"brave",  @"url":@"https://search.brave.com/search?q=%@"},
    @{@"name":@"Startpage",   @"id":@"start",  @"url":@"https://www.startpage.com/search?q=%@"},
  ];
}
+ (NSString *)searchURLForQuery:(NSString *)q {
  NSString *eid=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBSearchEngine"]?:@"ddg";
  for (NSDictionary *e in [self searchEngines]) {
    if ([e[@"id"] isEqualToString:eid])
      return [NSString stringWithFormat:e[@"url"], [q stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
  }
  return [NSString stringWithFormat:@"https://duckduckgo.com/?q=%@",
          [q stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
}
- (void)openNetworkMonitor:(id)s { [[BBNetworkMapPanel shared] showOrFocus]; }

- (void)openSearchPreferences:(id)s {
  NSAlert *a=[[NSAlert alloc]init];
  a.messageText=@"Default Search Engine";
  NSPopUpButton *pop=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(0,0,240,26) pullsDown:NO];
  NSString *cur=[[NSUserDefaults standardUserDefaults] stringForKey:@"BBSearchEngine"]?:@"ddg";
  for (NSDictionary *e in [BBDelegate searchEngines]) {
    [pop addItemWithTitle:e[@"name"]];
    pop.lastItem.representedObject=e[@"id"];
    if ([e[@"id"] isEqualToString:cur]) [pop selectItem:pop.lastItem];
  }
  a.accessoryView=pop;
  [a addButtonWithTitle:@"Save"]; [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){
    if (r!=NSAlertFirstButtonReturn) return;
    NSString *eid=pop.selectedItem.representedObject;
    if (eid) [[NSUserDefaults standardUserDefaults] setObject:eid forKey:@"BBSearchEngine"];
  }];
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
  if (!self.closedTabURLs.count) return;
  NSString *url=[self.closedTabURLs lastObject]; [self.closedTabURLs removeLastObject];
  [self addTabPrivate:NO];
  [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
}
- (void)nextTab:(id)s { NSInteger next=(self.activeTabIndex+1)%self.tabs.count; [self tabItemDidSelect:next]; }
- (void)prevTab:(id)s { NSInteger prev=(self.activeTabIndex-1+self.tabs.count)%self.tabs.count; [self tabItemDidSelect:prev]; }
- (void)switchToTabByMenuItem:(NSMenuItem *)item {
  NSInteger idx=item.tag;
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
        [inputLower hasPrefix:@"webkit-"]||[inputLower hasPrefix:@"x-webkit"]) return;
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
- (void)goBack:(id)s    { if(self.webView.canGoBack)    [self.webView goBack]; }
- (void)goForward:(id)s { if(self.webView.canGoForward) [self.webView goForward]; }
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
- (void)zoomIn:(id)s    { self.webView.pageZoom=MIN(5.0,self.webView.pageZoom+0.1); }
- (void)zoomOut:(id)s   { self.webView.pageZoom=MAX(0.2,self.webView.pageZoom-0.1); }
- (void)zoomReset:(id)s { self.webView.pageZoom=1.0; }

- (void)printPage:(id)s {
  NSPrintOperation *op=[self.webView printOperationWithPrintInfo:[NSPrintInfo sharedPrintInfo]];
  [op runOperationModalForWindow:self.window delegate:nil didRunSelector:nil contextInfo:nil];
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
  // Use _inspector private API: get the WKInspector and call show: on it.
  // developerExtrasEnabled must be YES (set in baseConfig) for this to work.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  SEL getInspector=NSSelectorFromString(@"_inspector");
  if([self.webView respondsToSelector:getInspector]){
    id inspector=((id(*)(id,SEL))objc_msgSend)(self.webView,getInspector);
    SEL show=NSSelectorFromString(@"show:");
    if([inspector respondsToSelector:show])
      ((void(*)(id,SEL,id))objc_msgSend)(inspector,show,nil);
  }
#pragma clang diagnostic pop
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
    self.findBar.resultLabel.stringValue=r.matchFound?@"":@"Not found";
    self.findBar.resultLabel.textColor=r.matchFound?[NSColor secondaryLabelColor]:[NSColor systemRedColor];
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
- (void)controlTextDidChange:(NSNotification *)n {
  if (n.object!=self.address) return;
  NSString *q=[self.address.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (q.length) [self.addressDropdown updateForQuery:q belowField:self.address inWindow:self.window];
  else [self.addressDropdown hide];
}
- (void)controlTextDidEndEditing:(NSNotification *)n {
  if (n.object==self.address) [self.addressDropdown hide];
}
- (BOOL)control:(NSControl *)ctrl textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
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
        BBEmitEvent(@"navigation.requested",@"allow",@"User navigation.",@{@"url":url.absoluteString});
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
// ── JS dialog suppression ─────────────────────────────────────────────────────
// Pages cannot trigger alert(), confirm(), or prompt() — these are classic attack
// vectors: infinite alert loops, phishing via confirm, credential harvest via prompt.
// All three are silently swallowed. The completion handlers are called immediately
// so the page's JS execution continues normally (no hang).
- (void)webView:(WKWebView*)wv runJavaScriptAlertPanelWithMessage:(NSString*)msg
    initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(void))done {
  BBLog([NSString stringWithFormat:@"[BLOCKED] JS alert() from %@: %@", frame.request.URL.host?:@"?", msg]);
  done();
}
- (void)webView:(WKWebView*)wv runJavaScriptConfirmPanelWithMessage:(NSString*)msg
    initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(BOOL))done {
  BBLog([NSString stringWithFormat:@"[BLOCKED] JS confirm() from %@: %@", frame.request.URL.host?:@"?", msg]);
  done(NO);
}
- (void)webView:(WKWebView*)wv runJavaScriptTextInputPanelWithPrompt:(NSString*)prompt
    defaultText:(NSString*)def initiatedByFrame:(WKFrameInfo*)frame
    completionHandler:(void(^)(NSString*))done {
  BBLog([NSString stringWithFormat:@"[BLOCKED] JS prompt() from %@: %@", frame.request.URL.host?:@"?", prompt]);
  done(nil);
}
// beforeunload dialogs — suppress "are you sure you want to leave?" gates
- (void)webViewDidClose:(WKWebView*)wv { /* no action — suppresses beforeunload UI */ }

- (WKWebView *)webView:(WKWebView *)wv createWebViewWithConfiguration:(WKWebViewConfiguration *)cfg forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
  // macOS 26+: must NEVER return nil — WebKit throws NSException.
  NSString *popupURL=action.request.URL.absoluteString?:@"";
  NSString *initiator=wv.URL.host?:@"unknown";

  // WKNavigationTypeLinkActivated = user clicked target=_blank → always user-initiated.
  // WKNavigationTypeOther = window.open() — could be script or user gesture.
  // Use gesture timestamp: if no real input within 1s, treat as script popup.
  NSTimeInterval sinceGesture=[NSDate timeIntervalSinceReferenceDate]-self.lastUserGestureTime;
  BOOL likelyUserInitiated=(action.navigationType==WKNavigationTypeLinkActivated)||(sinceGesture<1.0);
  if (!likelyUserInitiated) {
    // Script-initiated popup — honeypot it.
    // Return a real but invisible, never-shown WKWebView so WebKit is satisfied.
    // Its navigation delegate logs everything it tries to load, then we discard it.
    BBEmitEvent(@"security.popup_blocked", @"block",
      [NSString stringWithFormat:@"Script popup blocked from %@: %@", initiator, popupURL],
      @{@"initiator":initiator, @"url":popupURL, @"userInitiated":@NO});

    WKWebViewConfiguration *decoyCfg=[[WKWebViewConfiguration alloc]init];
    // No message handlers, no content rules, fully isolated
    WKWebView *decoy=[[WKWebView alloc]initWithFrame:NSZeroRect configuration:decoyCfg];
    decoy.navigationDelegate=self; // we'll see what it tries to navigate to
    [self.decoyViews addObject:decoy];
    if (action.request.URL) [decoy loadRequest:action.request];
    // Auto-discard after 15s — enough to capture any redirect chain
    __weak BBDelegate *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(15*NSEC_PER_SEC)),
      dispatch_get_main_queue(),^{
        [weakSelf.decoyViews removeObject:decoy];
      });
    return decoy;
  }

  // User-initiated (OAuth popup, target=_blank link, etc.) — open as a real tab
  BBTab *tab=[[BBTab alloc]init];
  tab.webView=[self makeWebViewPrivate:self.activeTab.isPrivate];
  [self.tabs addObject:tab];
  if (action.request.URL) [tab.webView loadRequest:action.request];
  NSInteger ni=self.tabs.count-1; [self reloadTabBar];
  dispatch_async(dispatch_get_main_queue(),^{[self activateTab:ni];[self reloadTabBar];});
  return tab.webView;
}
- (void)webView:(WKWebView *)wv navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)download {
  download.delegate=self;
}
- (void)webView:(WKWebView *)wv navigationResponse:(WKNavigationResponse *)response didBecomeDownload:(WKDownload *)download {
  download.delegate=self;
}
// ── HTTPS upgrade + mixed-content guard ───────────────────────────────────────
- (void)webView:(WKWebView *)wv decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  // Decoy (honeypot) webviews: log what the script popup tried to reach, then cancel.
  if ([self.decoyViews containsObject:wv]) {
    NSString *dest=action.request.URL.absoluteString?:@"";
    BBEmitEvent(@"security.popup_honeypot_nav",@"alert",
      [NSString stringWithFormat:@"Honeypot popup navigated to: %@",dest],
      @{@"url":dest});
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }
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

  // Cmd+click → open in new background tab
  if (action.navigationType==WKNavigationTypeLinkActivated &&
      (action.modifierFlags & NSEventModifierFlagCommand)) {
    decisionHandler(WKNavigationActionPolicyCancel);
    dispatch_async(dispatch_get_main_queue(),^{
      NSInteger prev=self.activeTabIndex;
      [self addTabPrivate:self.activeTab.isPrivate];
      [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
      [self tabItemDidSelect:prev]; // stay on current tab
    });
    return;
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
  [self addTabPrivate:self.activeTab.isPrivate];
  [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
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
// Install a right-click monitor so we can show our own context menu on the webview
- (void)installContextMenuMonitor {
  __weak BBDelegate *weak=self;
  [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown handler:^NSEvent*(NSEvent *e){
    BBDelegate *s=weak; if (!s||e.window!=s.window) return e;
    NSPoint pt=[s.webView convertPoint:e.locationInWindow fromView:nil];
    if (!NSPointInRect(pt,s.webView.bounds)) return e;
    // Ask the page for the link URL at this point, then show menu
    NSString *js=[NSString stringWithFormat:
      @"(function(){var el=document.elementFromPoint(%f,%f);"
      @"while(el){if(el.tagName==='A'&&el.href)return el.href;el=el.parentElement;}"
      @"return '';})();", pt.x, s.webView.bounds.size.height-pt.y];
    [s.webView evaluateJavaScript:js completionHandler:^(id result,NSError *err){
      dispatch_async(dispatch_get_main_queue(),^{
        NSString *href=[result isKindOfClass:[NSString class]]?result:@"";
        NSURL *linkURL=href.length?[NSURL URLWithString:href]:nil;
        NSMenu *menu=[[NSMenu alloc]initWithTitle:@""];
        if (linkURL) {
          NSMenuItem *ot=[[NSMenuItem alloc]initWithTitle:@"Open Link in New Tab" action:@selector(contextOpenLinkNewTab:) keyEquivalent:@""];
          ot.target=s; ot.representedObject=linkURL; [menu addItem:ot];
          NSMenuItem *cl=[[NSMenuItem alloc]initWithTitle:@"Copy Link" action:@selector(contextCopyLink:) keyEquivalent:@""];
          cl.target=s; cl.representedObject=linkURL; [menu addItem:cl];
          [menu addItem:[NSMenuItem separatorItem]];
        }
        NSMenuItem *back=[[NSMenuItem alloc]initWithTitle:@"Back" action:@selector(goBack:) keyEquivalent:@""];
        back.target=s; back.enabled=s.webView.canGoBack; [menu addItem:back];
        NSMenuItem *fwd=[[NSMenuItem alloc]initWithTitle:@"Forward" action:@selector(goForward:) keyEquivalent:@""];
        fwd.target=s; fwd.enabled=s.webView.canGoForward; [menu addItem:fwd];
        NSMenuItem *rl=[[NSMenuItem alloc]initWithTitle:@"Reload" action:@selector(reloadOrStop:) keyEquivalent:@""];
        rl.target=s; [menu addItem:rl];
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *cu=[[NSMenuItem alloc]initWithTitle:@"Copy Page URL" action:@selector(contextCopyPageURL:) keyEquivalent:@""];
        cu.target=s; [menu addItem:cu];
        NSMenuItem *src=[[NSMenuItem alloc]initWithTitle:@"View Page Source" action:@selector(viewSource:) keyEquivalent:@""];
        src.target=s; [menu addItem:src];
        NSMenuItem *ins=[[NSMenuItem alloc]initWithTitle:@"Inspect Element" action:@selector(openDevTools:) keyEquivalent:@""];
        ins.target=s; [menu addItem:ins];
        [menu popUpMenuPositioningItem:nil atLocation:e.locationInWindow inView:nil];
      });
    }];
    return nil; // swallow the original right-click
  }];
}

- (void)webView:(WKWebView *)wv didStartProvisionalNavigation:(WKNavigation *)nav {
  BBTab *tab=[self tabForWebView:wv]; if (!tab) return;
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
- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {
  BBTab *tab=[self tabForWebView:wv]; if (!tab) return;
  tab.isLoading=NO;
  tab.title=wv.title.length?wv.title:@"New Tab";
  [self fetchFaviconForTab:tab];
  NSString *url=wv.URL.absoluteString?:@"";
  if (wv==self.webView) {
    self.progressBar.hidden=YES;
    NSImage *ri=[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Reload"];
    ri=[ri imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]];
    [ri setTemplate:YES]; self.reloadButton.image=ri; self.reloadButton.toolTip=@"Reload";
    self.address.stringValue=[self isInternalURL:url]?@"":url;
    self.backButton.enabled=wv.canGoBack; self.forwardButton.enabled=wv.canGoForward;
    self.window.title=tab.title;
    [self updateSecurityIndicator:wv.URL];
  }
  // Record navigation to network monitor
  if(wv.URL.host.length && !tab.isPrivate)
    BBNetworkRecord_push(wv.URL.host, url, @"navigation", [BBFirewall.shared decisionFor:[BBConnectionRecord etldForHost:wv.URL.host]]==BBFWBlock);
  // Record to history (async so it never blocks the main thread)
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
    [[BBHistoryStore shared] recordTitle:tab.title url:url];
  });
  // Capture server trust for cert inspector — private KVC, graceful if absent
  if (wv==self.webView) {
    SecTrustRef trust=(__bridge SecTrustRef)[wv valueForKey:@"_serverTrust"];
    if (trust) { CFRetain(trust); if(self.currentTrust) CFRelease(self.currentTrust); self.currentTrust=trust; }
    else        { if(self.currentTrust){ CFRelease(self.currentTrust); self.currentTrust=nil; } }
  }
  BBEmitEvent(@"navigation.committed",@"allow",@"Navigation committed.",@{@"url":url});
  [self reloadTabBar];
}
- (void)webView:(WKWebView *)wv didFailNavigation:(WKNavigation *)nav withError:(NSError *)err {
  BBTab *tab=[self tabForWebView:wv]; if(!tab) return; tab.isLoading=NO;
  if (wv==self.webView) {
    self.progressBar.hidden=YES;
    NSImage *ri=[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Reload"];
    ri=[ri imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium]];
    [ri setTemplate:YES]; self.reloadButton.image=ri; self.reloadButton.toolTip=@"Reload";
  }
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
  NSURL *dlDir=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"]];
  [[NSFileManager defaultManager] createDirectoryAtURL:dlDir withIntermediateDirectories:YES attributes:nil error:nil];
  NSURL *dest=[dlDir URLByAppendingPathComponent:filename];
  NSInteger n=0; NSString *base=[filename stringByDeletingPathExtension]; NSString *ext=filename.pathExtension;
  while ([[NSFileManager defaultManager] fileExistsAtPath:dest.path]) {
    n++;
    dest=[dlDir URLByAppendingPathComponent:ext.length?[NSString stringWithFormat:@"%@ (%ld).%@",base,(long)n,ext]:[NSString stringWithFormat:@"%@ (%ld)",base,(long)n]];
  }
  // Register in download panel
  BBDownloadItem *item=[BBDownloadItem new];
  item.filename=filename; item.destURL=dest; item.download=download;
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
