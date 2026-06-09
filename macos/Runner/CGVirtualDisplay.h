//
//  CGVirtualDisplay.h
//  Private CoreGraphics interfaces for creating a virtual display (Extend mode).
//  These symbols live in the CoreGraphics framework but are not in the public
//  SDK headers; declaring them here lets Swift call the real initializers.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) uint32_t width;
@property(readonly, nonatomic) uint32_t height;
@property(readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) uint32_t hiDPI;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(copy, nonatomic) NSString *name;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t serialNum;
@property(copy, nonatomic) void (^terminationHandler)(id _Nullable arg1,
                                                      id _Nullable arg2);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
