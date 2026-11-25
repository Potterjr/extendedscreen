#import "FastTouch.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

// Private XCTest classes, declared by hand (as WebDriverAgent does).
@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end

@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name
        interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(XCPointerEventPath *)path;
@end

@interface FastTouch ()
@end

@implementation FastTouch

/// Whoever can synthesize: XCUIDevice's eventSynthesizer (recent Xcode), else
/// the runner's daemon session.
+ (nullable id)synthesizer {
  XCUIDevice *device = XCUIDevice.sharedDevice;
  SEL es = NSSelectorFromString(@"eventSynthesizer");
  if ([device respondsToSelector:es]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id s = [device performSelector:es];
#pragma clang diagnostic pop
    if (s) return s;
  }
  Class session = NSClassFromString(@"XCTRunnerDaemonSession");
  SEL shared = NSSelectorFromString(@"sharedSession");
  if (session && [session respondsToSelector:shared]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [session performSelector:shared];
#pragma clang diagnostic pop
  }
  return nil;
}

+ (BOOL)available {
  return NSClassFromString(@"XCPointerEventPath") != nil &&
         NSClassFromString(@"XCSynthesizedEventRecord") != nil &&
         [self synthesizer] != nil;
}

static SEL displayIDInit(void) {
  return NSSelectorFromString(@"initWithName:displayID:interfaceOrientation:");
}

+ (BOOL)recordTakesDisplayID {
  Class cls = NSClassFromString(@"XCSynthesizedEventRecord");
  return cls != nil && [cls instancesRespondToSelector:displayIDInit()];
}

/// An empty record, portrait (every point given here is in portrait). Made
/// with the display-ID initializer where XCTest has it (display 0, the main
/// one, as WebDriverAgent does), else the older one.
+ (XCSynthesizedEventRecord *)recordNamed:(NSString *)name {
  Class cls = NSClassFromString(@"XCSynthesizedEventRecord");
  if ([self recordTakesDisplayID]) {
    id blank = [cls alloc];
    id record = ((id (*)(id, SEL, id, unsigned long long, long long))objc_msgSend)(
        blank, displayIDInit(), name, 0ULL, (long long)UIInterfaceOrientationPortrait);
    if (record) return record;
  }
  return [[cls alloc] initWithName:name
              interfaceOrientation:UIInterfaceOrientationPortrait];
}

+ (XCPointerEventPath *)pathAt:(CGPoint)point {
  return [[NSClassFromString(@"XCPointerEventPath") alloc] initForTouchAtPoint:point
                                                                         offset:0];
}

static NSError *noSynthesizer(void) {
  return [NSError errorWithDomain:@"FastTouch" code:1
      userInfo:@{NSLocalizedDescriptionKey: @"no event synthesizer"}];
}

/// Hands [record] to the synthesizer; [completion] is called once, with
/// whatever it reports, or at once (code 1) when there is none.
+ (BOOL)hand:(id)record completion:(void (^)(BOOL, NSError *))completion {
  id synth = [self synthesizer];
  SEL sel = NSSelectorFromString(@"synthesizeEvent:completion:");
  if (!synth || ![synth respondsToSelector:sel]) {
    completion(NO, noSynthesizer());
    return NO;
  }
  NSMethodSignature *sig = [synth methodSignatureForSelector:sel];
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  inv.target = synth;
  inv.selector = sel;
  void (^block)(BOOL, NSError *) = [completion copy];
  [inv setArgument:&record atIndex:2];
  [inv setArgument:&block atIndex:3];
  [inv retainArguments];
  [inv invoke];
  return YES;
}

/// Hands [record] to the synthesizer and waits up to [seconds] for it to
/// report (a gesture's own length plus a margin, so a long one is not taken
/// for a failure while it still runs).
+ (BOOL)send:(XCSynthesizedEventRecord *)record
      within:(double)seconds
       error:(NSError **)error {
  __block BOOL done = NO;
  __block NSError *failure = nil;
  BOOL handed = [self hand:record completion:^(BOOL ok, NSError *e) {
    if (!ok) failure = e ?: [NSError errorWithDomain:@"FastTouch" code:2
        userInfo:@{NSLocalizedDescriptionKey: @"synthesis refused"}];
    done = YES;
  }];
  if (!handed) {
    if (error) *error = failure;
    return NO;
  }
  // The completion may come on this (main) thread: spin its run loop.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!done && deadline.timeIntervalSinceNow > 0) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
  }
  if (!done && !failure) {
    failure = [NSError errorWithDomain:@"FastTouch" code:3
        userInfo:@{NSLocalizedDescriptionKey: @"no completion in time"}];
  }
  if (failure && error) *error = failure;
  return failure == nil;
}

+ (void)sendAsync:(XCSynthesizedEventRecord *)record
       completion:(nullable FastTouchDone)completion {
  [self hand:record completion:^(BOOL ok, NSError *e) {
    if (!completion) return;
    if (!ok && !e) {
      e = [NSError errorWithDomain:@"FastTouch" code:2
          userInfo:@{NSLocalizedDescriptionKey: @"synthesis refused"}];
    }
    completion(ok, e);
  }];
}

/// A path that stays at [from] for [hold] s, then moves to [to] over
/// [seconds], stays there [endHold] s and lifts.
+ (XCSynthesizedEventRecord *)swipeRecordFrom:(CGPoint)from
                                           to:(CGPoint)to
                                     duration:(double)seconds
                                         hold:(double)hold
                                      endHold:(double)endHold {
  XCPointerEventPath *path = [self pathAt:from];
  double h = MAX(hold, 0);
  double d = MAX(seconds, 0.02);
  double e = MAX(endHold, 0);
  if (h > 0) [path moveToPoint:from atOffset:h];
  [path moveToPoint:to atOffset:h + d];
  if (e > 0) [path moveToPoint:to atOffset:h + d + e];
  [path liftUpAtOffset:h + d + e + 0.01];
  XCSynthesizedEventRecord *record = [self recordNamed:@"swipe"];
  [record addPointerEventPath:path];
  return record;
}

+ (void)swipeAsyncFrom:(CGPoint)from
                    to:(CGPoint)to
              duration:(double)seconds
                  hold:(double)hold
               endHold:(double)endHold
            completion:(nullable FastTouchDone)completion {
  [self sendAsync:[self swipeRecordFrom:from to:to duration:seconds hold:hold
                                endHold:endHold]
       completion:completion];
}

+ (void)tapAtAsync:(CGPoint)point
              hold:(double)seconds
        completion:(nullable FastTouchDone)completion {
  XCPointerEventPath *path = [self pathAt:point];
  [path liftUpAtOffset:seconds];
  XCSynthesizedEventRecord *record = [self recordNamed:@"tap"];
  [record addPointerEventPath:path];
  [self sendAsync:record completion:completion];
}

+ (BOOL)tapAt:(CGPoint)point error:(NSError **)error {
  XCPointerEventPath *path = [self pathAt:point];
  [path liftUpAtOffset:0.01];
  XCSynthesizedEventRecord *record = [self recordNamed:@"tap"];
  [record addPointerEventPath:path];
  return [self send:record within:5 error:error];
}

+ (BOOL)swipeFrom:(CGPoint)from
               to:(CGPoint)to
         duration:(double)seconds
             hold:(double)hold
          endHold:(double)endHold
            error:(NSError **)error {
  XCSynthesizedEventRecord *record =
      [self swipeRecordFrom:from to:to duration:MAX(seconds, 0.05) hold:hold
                    endHold:endHold];
  double lasts = MAX(hold, 0) + MAX(seconds, 0.05) + MAX(endHold, 0);
  return [self send:record within:lasts + 5 error:error];
}

// MARK: Spikes (E1, E2)

+ (void)fingerDownAt:(CGPoint)point completion:(nullable FastTouchDone)completion {
  XCPointerEventPath *path = [self pathAt:point];
  XCSynthesizedEventRecord *record = [self recordNamed:@"pdown"];
  [record addPointerEventPath:path];
  [self sendAsync:record completion:completion];
}

+ (void)fingerFrom:(CGPoint)from
            moveTo:(CGPoint)to
        completion:(nullable FastTouchDone)completion {
  XCPointerEventPath *path = [self pathAt:from];
  [path moveToPoint:to atOffset:0.016];
  XCSynthesizedEventRecord *record = [self recordNamed:@"pmove"];
  [record addPointerEventPath:path];
  [self sendAsync:record completion:completion];
}

+ (BOOL)scrollAt:(CGPoint)point
              dx:(double)dx
              dy:(double)dy
      completion:(nullable FastTouchDone)completion
           error:(NSError **)error {
  Class cls = NSClassFromString(@"XCPointerEventPath");
  SEL mouse = NSSelectorFromString(@"initForMouseEventsAtLocation:");
  SEL byXY = NSSelectorFromString(@"scrollByDeltaX:deltaY:atOffset:");
  SEL byVector = NSSelectorFromString(@"scrollWithDeltaVector:atOffset:");
  if (!cls || ![cls instancesRespondToSelector:mouse] ||
      !([cls instancesRespondToSelector:byXY] ||
        [cls instancesRespondToSelector:byVector])) {
    if (error) {
      *error = [NSError errorWithDomain:@"FastTouch" code:1
          userInfo:@{NSLocalizedDescriptionKey: @"no mouse-path scroll in this XCTest"}];
    }
    return NO;
  }
  id path = ((id (*)(id, SEL, CGPoint))objc_msgSend)([cls alloc], mouse, point);
  if (!path) {
    if (error) {
      *error = [NSError errorWithDomain:@"FastTouch" code:1
          userInfo:@{NSLocalizedDescriptionKey: @"mouse path refused"}];
    }
    return NO;
  }
  if ([path respondsToSelector:byXY]) {
    ((void (*)(id, SEL, double, double, double))objc_msgSend)(path, byXY, dx, dy, 0.0);
  } else {
    ((void (*)(id, SEL, CGVector, double))objc_msgSend)(
        path, byVector, CGVectorMake(dx, dy), 0.0);
  }
  XCSynthesizedEventRecord *record = [self recordNamed:@"scroll"];
  [record addPointerEventPath:path];
  [self sendAsync:record completion:completion];
  return YES;
}

// MARK: Interface orientation

+ (NSInteger)interfaceOrientationOf:(id)application {
  SEL sel = NSSelectorFromString(@"interfaceOrientation");
  if (!application || ![application respondsToSelector:sel]) return 0;
  NSInteger o = 0;
  @try {
    o = ((NSInteger (*)(id, SEL))objc_msgSend)(application, sel);
  } @catch (NSException *e) {
    return 0;
  }
  return (o >= 1 && o <= 4) ? o : 0;
}

/// The XCUIApplication for [pid], made the private way.
+ (nullable id)applicationWithPID:(int)pid {
  Class app = XCUIApplication.class;
  for (NSString *name in @[@"applicationWithPID:", @"appWithPID:"]) {
    SEL sel = NSSelectorFromString(name);
    if ([app respondsToSelector:sel]) {
      @try {
        return ((id (*)(id, SEL, int))objc_msgSend)(app, sel, pid);
      } @catch (NSException *e) {
        return nil;
      }
    }
  }
  return nil;
}

+ (int)processIDOf:(id)application {
  SEL sel = NSSelectorFromString(@"processID");
  if (!application || ![application respondsToSelector:sel]) return 0;
  @try {
    return ((int (*)(id, SEL))objc_msgSend)(application, sel);
  } @catch (NSException *e) {
    return 0;
  }
}

+ (NSInteger)activeInterfaceOrientation:(int *)pidOut {
  return [self activeInterfaceOrientation:pidOut excludingPID:0];
}

+ (NSInteger)activeInterfaceOrientation:(int *)pidOut excludingPID:(int)excluded {
  Class client = NSClassFromString(@"XCAXClient_iOS");
  SEL shared = NSSelectorFromString(@"sharedClient");
  SEL active = NSSelectorFromString(@"activeApplications");
  SEL pidSel = NSSelectorFromString(@"processIdentifier");
  if (!client || ![client respondsToSelector:shared]) return 0;
  NSArray *apps = nil;
  @try {
    id c = ((id (*)(id, SEL))objc_msgSend)(client, shared);
    if (![c respondsToSelector:active]) return 0;
    apps = ((id (*)(id, SEL))objc_msgSend)(c, active);
  } @catch (NSException *e) {
    return 0;
  }
  if (![apps isKindOfClass:NSArray.class]) return 0;
  for (id element in apps) {
    if (![element respondsToSelector:pidSel]) continue;
    int pid = ((int (*)(id, SEL))objc_msgSend)(element, pidSel);
    // SpringBoard is among the active applications beside the app in
    // front, in no set order, and on an iPhone it reports portrait.
    if (pid <= 0 || pid == excluded) continue;
    NSInteger o = [self interfaceOrientationOf:[self applicationWithPID:pid]];
    if (o != 0) {
      if (pidOut) *pidOut = pid;
      return o;
    }
  }
  return 0;
}

@end
