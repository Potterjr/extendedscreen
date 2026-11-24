#import "FastTouch.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

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

/// Hands [record] to the synthesizer and waits up to [seconds] for it to
/// report (a gesture's own length plus a margin, so a long one is not taken
/// for a failure while it still runs).
+ (BOOL)send:(XCSynthesizedEventRecord *)record
      within:(double)seconds
       error:(NSError **)error {
  id synth = [self synthesizer];
  SEL sel = NSSelectorFromString(@"synthesizeEvent:completion:");
  if (!synth || ![synth respondsToSelector:sel]) {
    if (error) {
      *error = [NSError errorWithDomain:@"FastTouch" code:1
          userInfo:@{NSLocalizedDescriptionKey: @"no event synthesizer"}];
    }
    return NO;
  }
  __block BOOL done = NO;
  __block NSError *failure = nil;
  void (^completion)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {
    if (!ok) failure = e ?: [NSError errorWithDomain:@"FastTouch" code:2
        userInfo:@{NSLocalizedDescriptionKey: @"synthesis refused"}];
    done = YES;
  };
  NSMethodSignature *sig = [synth methodSignatureForSelector:sel];
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  inv.target = synth;
  inv.selector = sel;
  [inv setArgument:&record atIndex:2];
  [inv setArgument:&completion atIndex:3];
  [inv retainArguments];
  [inv invoke];
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

+ (void)sendAsync:(XCSynthesizedEventRecord *)record {
  id synth = [self synthesizer];
  SEL sel = NSSelectorFromString(@"synthesizeEvent:completion:");
  if (!synth || ![synth respondsToSelector:sel]) return;
  void (^completion)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {};
  NSMethodSignature *sig = [synth methodSignatureForSelector:sel];
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  inv.target = synth;
  inv.selector = sel;
  [inv setArgument:&record atIndex:2];
  [inv setArgument:&completion atIndex:3];
  [inv retainArguments];
  [inv invoke];
}

/// A path that stays at [from] for [hold] s, then moves to [to] over
/// [seconds] and lifts.
+ (XCSynthesizedEventRecord *)swipeRecordFrom:(CGPoint)from
                                           to:(CGPoint)to
                                     duration:(double)seconds
                                         hold:(double)hold {
  XCPointerEventPath *path =
      [[NSClassFromString(@"XCPointerEventPath") alloc] initForTouchAtPoint:from offset:0];
  double h = MAX(hold, 0);
  double d = MAX(seconds, 0.02);
  if (h > 0) [path moveToPoint:from atOffset:h];
  [path moveToPoint:to atOffset:h + d];
  [path liftUpAtOffset:h + d + 0.01];
  XCSynthesizedEventRecord *record =
      [[NSClassFromString(@"XCSynthesizedEventRecord") alloc]
          initWithName:@"swipe" interfaceOrientation:UIInterfaceOrientationPortrait];
  [record addPointerEventPath:path];
  return record;
}

+ (void)swipeAsyncFrom:(CGPoint)from to:(CGPoint)to duration:(double)seconds
                  hold:(double)hold {
  [self sendAsync:[self swipeRecordFrom:from to:to duration:seconds hold:hold]];
}

+ (void)tapAtAsync:(CGPoint)point hold:(double)seconds {
  XCPointerEventPath *path =
      [[NSClassFromString(@"XCPointerEventPath") alloc] initForTouchAtPoint:point offset:0];
  [path liftUpAtOffset:seconds];
  XCSynthesizedEventRecord *record =
      [[NSClassFromString(@"XCSynthesizedEventRecord") alloc]
          initWithName:@"tap" interfaceOrientation:UIInterfaceOrientationPortrait];
  [record addPointerEventPath:path];
  id synth = [self synthesizer];
  SEL sel = NSSelectorFromString(@"synthesizeEvent:completion:");
  if (!synth || ![synth respondsToSelector:sel]) return;
  void (^completion)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {};
  NSMethodSignature *sig = [synth methodSignatureForSelector:sel];
  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  inv.target = synth;
  inv.selector = sel;
  [inv setArgument:&record atIndex:2];
  [inv setArgument:&completion atIndex:3];
  [inv retainArguments];
  [inv invoke];
}

+ (BOOL)tapAt:(CGPoint)point error:(NSError **)error {
  XCPointerEventPath *path =
      [[NSClassFromString(@"XCPointerEventPath") alloc] initForTouchAtPoint:point offset:0];
  [path liftUpAtOffset:0.01];
  XCSynthesizedEventRecord *record =
      [[NSClassFromString(@"XCSynthesizedEventRecord") alloc]
          initWithName:@"tap" interfaceOrientation:UIInterfaceOrientationPortrait];
  [record addPointerEventPath:path];
  return [self send:record within:5 error:error];
}

+ (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(double)seconds
             hold:(double)hold
            error:(NSError **)error {
  XCSynthesizedEventRecord *record =
      [self swipeRecordFrom:from to:to duration:MAX(seconds, 0.05) hold:hold];
  return [self send:record within:MAX(hold, 0) + MAX(seconds, 0.05) + 5 error:error];
}

@end
