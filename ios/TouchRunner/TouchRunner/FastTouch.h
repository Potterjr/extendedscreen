#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Called once a record handed over without waiting has been synthesized
/// (ok), refused, or could not be handed over at all (error code 1). It can
/// come on any thread.
typedef void (^FastTouchDone)(BOOL ok, NSError *_Nullable error);

/// Touches synthesized straight through XCTest's event synthesizer (private
/// API, as WebDriverAgent does), without XCUICoordinate's wait for the app
/// to go idle. Points are in screen points, portrait. Every call must be
/// made on the main thread.
@interface FastTouch : NSObject
+ (BOOL)available;

/// Whether records are made with initWithName:displayID:interfaceOrientation:
/// (recent XCTest) rather than initWithName:interfaceOrientation:.
+ (BOOL)recordTakesDisplayID;

/// A tap. Fails with code 1 when the synthesizer was never handed the touch
/// (nothing happened: the caller may try another way), 2 when it refused
/// it, 3 when it did not report in time (the touch may still be landing).
+ (BOOL)tapAt:(CGPoint)point error:(NSError *_Nullable *_Nullable)error;

/// The same, handed to the synthesizer without waiting for it to report;
/// [completion] hears when it has.
+ (void)tapAtAsync:(CGPoint)point
              hold:(double)seconds
        completion:(nullable FastTouchDone)completion;

/// A swipe (or, from a point to itself, a press held for [seconds]), after
/// [hold] seconds held at [from], then [endHold] seconds held still at [to]
/// before the lift, handed to the synthesizer without waiting for it.
+ (void)swipeAsyncFrom:(CGPoint)from
                    to:(CGPoint)to
              duration:(double)seconds
                  hold:(double)hold
               endHold:(double)endHold
            completion:(nullable FastTouchDone)completion;

/// The same, waiting for the synthesizer (errors as for tapAt).
+ (BOOL)swipeFrom:(CGPoint)from
               to:(CGPoint)to
         duration:(double)seconds
             hold:(double)hold
          endHold:(double)endHold
            error:(NSError *_Nullable *_Nullable)error;

// Experimental (plan spikes E1/E2), for finding out what XCTest does.

/// A record with a finger put down at [point] and no lift.
+ (void)fingerDownAt:(CGPoint)point completion:(nullable FastTouchDone)completion;

/// A record with a finger put down at [from], moved to [to], and no lift.
+ (void)fingerFrom:(CGPoint)from
            moveTo:(CGPoint)to
        completion:(nullable FastTouchDone)completion;

/// A mouse-path scroll of ([dx], [dy]) at [point]. NO (error code 1) when
/// this XCTest has no mouse-path initializer or scroll method.
+ (BOOL)scrollAt:(CGPoint)point
              dx:(double)dx
              dy:(double)dy
      completion:(nullable FastTouchDone)completion
           error:(NSError *_Nullable *_Nullable)error;

/// The frontmost application's interface orientation (a UIInterfaceOrientation
/// raw value, 1 to 4, which equals the UIDeviceOrientation raw value of the
/// same turn), read through private accessibility calls where they exist; 0
/// when it cannot be read. [pid] is the application's process id.
+ (NSInteger)activeInterfaceOrientation:(int *_Nullable)pid;

/// The same, passing over the application of process [excluded] (SpringBoard,
/// which is active beside the app in front and reports portrait on an
/// iPhone); 0 when no other one can be read. [excluded] 0 passes over none.
+ (NSInteger)activeInterfaceOrientation:(int *_Nullable)pid
                           excludingPID:(int)excluded;

/// The process id of [application] (an XCUIApplication, through XCTest's
/// private `processID`), 0 when it cannot be read.
+ (int)processIDOf:(id)application;

/// The XCUIApplication for process [pid], made through XCTest's private
/// initializer; nil where there is none.
+ (nullable id)applicationWithPID:(int)pid;

/// The interface orientation of [application] (an XCUIApplication), 0 when
/// it cannot be read.
+ (NSInteger)interfaceOrientationOf:(id)application;
@end

NS_ASSUME_NONNULL_END
