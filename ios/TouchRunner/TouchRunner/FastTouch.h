#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Touches synthesized straight through XCTest's event synthesizer (private
/// API, as WebDriverAgent does), without XCUICoordinate's wait for the app
/// to go idle. Points are in screen points, portrait. Each call returns once
/// the event has been delivered, or NO (with the reason in [error]) when the
/// private API is missing or refuses.
@interface FastTouch : NSObject
+ (BOOL)available;
/// A tap. Fails with code 1 when the synthesizer was never handed the touch
/// (nothing happened: the caller may try another way), 2 when it refused
/// it, 3 when it did not report in time (the touch may still be landing).
+ (BOOL)tapAt:(CGPoint)point error:(NSError *_Nullable *_Nullable)error;
/// The same, handed to the synthesizer without waiting for it to report.
+ (void)tapAtAsync:(CGPoint)point hold:(double)seconds;
/// A swipe (or, from a point to itself, a press held for [seconds]), after
/// [hold] seconds held at [from], handed to the synthesizer without waiting
/// for it to report.
+ (void)swipeAsyncFrom:(CGPoint)from to:(CGPoint)to duration:(double)seconds
                  hold:(double)hold;
/// The same, waiting for the synthesizer (errors as for tapAt).
+ (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(double)seconds
             hold:(double)hold
            error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
