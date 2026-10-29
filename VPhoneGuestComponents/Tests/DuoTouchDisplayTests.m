#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
static BOOL testing;
static const char *testProgname(void) { return testing ? "backboardd" : "test"; }
@interface TestDisplay : NSObject
@property NSString *UUID;
+ (id)mainDisplay;
@end
static TestDisplay *display;
@implementation TestDisplay
+ (id)mainDisplay {return display;}
@end
@interface TestEventDisplay:NSObject
@property NSString *identifier;
@property BOOL builtin;
+ (id)displayWithHardwareIdentifier:(id)identifier;
- (BOOL)_isBuiltinDisplay;
@end
@implementation TestEventDisplay
+ (id)displayWithHardwareIdentifier:(id)identifier {TestEventDisplay *d=[self new];d.identifier=identifier;return d;}
- (BOOL)_isBuiltinDisplay {return self.builtin;}
@end
@interface TestBaseAttributes:NSObject
@property TestEventDisplay *display;
@end
@implementation TestBaseAttributes
@end
@interface TestDigitizerAttributes:TestBaseAttributes
@end
@implementation TestDigitizerAttributes
@end
static id received;

typedef struct { double values[16]; } TestTransform;
typedef struct { CGSize size; CGFloat scale; uint8_t orientation; CGRect bounds; } TestGeometry;
@interface TestController : NSObject
- (uint32_t)hostTargetIDForEmbeddedTargetID:(uint32_t)target displayUUID:(id)uuid;
- (TestTransform)transformFromLayerId:(id)layer contextID:(id)context displayUUID:(id)uuid;
- (TestGeometry)geometryForDisplayUUID:(id)uuid;
- (id)displayForUUID:(id)uuid;
- (CGPoint)convertReferenceLocation:(CGPoint)p toScreenLocationForDisplayUUID:(id)uuid;
- (CGPoint)convertScreenLocation:(CGPoint)p toTargetID:(uint32_t)target displayUUID:(id)uuid;
- (BOOL)targetIDAtScreenLocation:(CGPoint)p displayUUID:(id)uuid options:(id)options securityAnalysis:(id *)analysis results:(void *)results;
- (void)getClientTaskNamePort:(uint32_t *)port clientConnectionIdentifier:(uint64_t *)connection forTargetID:(uint32_t)target displayUUID:(id)uuid;
@end
@implementation TestController
- (uint32_t)hostTargetIDForEmbeddedTargetID:(uint32_t)target displayUUID:(id)uuid {received=uuid;return target+1;}
- (TestTransform)transformFromLayerId:(id)layer contextID:(id)context displayUUID:(id)uuid {assert([layer isEqual:@7]&&[context isEqual:@42]);received=uuid;TestTransform result={0};for(int i=0;i<16;i++)result.values[i]=i+0.5;return result;}

- (TestGeometry)geometryForDisplayUUID:(id)uuid {received=uuid;return (TestGeometry){{669,951},3,2,{{0,0},{669,951}}};}
- (id)displayForUUID:(id)uuid {received=uuid;return uuid;}
- (CGPoint)convertReferenceLocation:(CGPoint)p toScreenLocationForDisplayUUID:(id)uuid {received=uuid;return p;}
- (CGPoint)convertScreenLocation:(CGPoint)p toTargetID:(uint32_t)target displayUUID:(id)uuid {assert(target==42);received=uuid;return p;}
- (BOOL)targetIDAtScreenLocation:(CGPoint)p displayUUID:(id)uuid options:(id)options securityAnalysis:(id *)analysis results:(void *)results {received=uuid;*(uint32_t *)results=42;return YES;}
- (void)getClientTaskNamePort:(uint32_t *)port clientConnectionIdentifier:(uint64_t *)connection forTargetID:(uint32_t)target displayUUID:(id)uuid {received=uuid;*port=target;*connection=1234567890123ULL;}
@end
static Class testClass(NSString *name) {if([name isEqual:@"CADisplay"])return TestDisplay.class;if([name isEqual:@"BKDisplayController"])return TestController.class;if([name isEqual:@"BKSHIDEventDigitizerAttributes"])return TestDigitizerAttributes.class;if([name isEqual:@"BKSHIDEventDisplay"])return TestEventDisplay.class;return NSClassFromString(name);}
#define NSClassFromString testClass
#define getprogname testProgname
#import "../Accelerometer/VPhoneDuoTouchDisplay.m"
#undef NSClassFromString
#undef getprogname
int main(void) {@autoreleasepool{
 display=[TestDisplay new];display.UUID=@"BF0DC480-5EE2-4EC1-B02B-C75E94759832";
 testing=YES;VPhoneDuoTouchDisplayStart();TestController *c=[TestController new];
 TestDigitizerAttributes *attrs=[TestDigitizerAttributes new];
 assert([attrs.display.identifier isEqual:display.UUID]);
 TestEventDisplay *builtin=[TestEventDisplay new];builtin.builtin=YES;attrs.display=builtin;
 assert([attrs.display.identifier isEqual:display.UUID]);
 TestEventDisplay *external=[TestEventDisplay displayWithHardwareIdentifier:@"external"];attrs.display=external;
 assert(attrs.display==external);
 TestBaseAttributes *base=[TestBaseAttributes new];base.display=builtin;assert(base.display==builtin);
 assert([c hostTargetIDForEmbeddedTargetID:42 displayUUID:nil]==43&&[received isEqual:display.UUID]);
 TestTransform transform=[c transformFromLayerId:@7 contextID:@42 displayUUID:nil];for(int i=0;i<16;i++)assert(transform.values[i]==i+0.5);assert([received isEqual:display.UUID]);
 TestGeometry geometry=[c geometryForDisplayUUID:nil];assert(geometry.size.width==669&&geometry.size.height==951&&geometry.scale==3&&geometry.orientation==2&&geometry.bounds.size.height==951&&[received isEqual:display.UUID]);
 assert([[c displayForUUID:nil] isEqual:display.UUID]);
 CGPoint point={123,456};
CGPoint result=[c convertReferenceLocation:point toScreenLocationForDisplayUUID:nil];assert(result.x==123&&result.y==456&&[received isEqual:display.UUID]);
 [c convertReferenceLocation:point toScreenLocationForDisplayUUID:@"other"];assert([received isEqual:@"other"]);
 [c convertScreenLocation:point toTargetID:42 displayUUID:nil];assert([received isEqual:display.UUID]);
 uint32_t target=0;assert([c targetIDAtScreenLocation:point displayUUID:nil options:nil securityAnalysis:nil results:&target]);assert(target==42&&[received isEqual:display.UUID]);
 uint32_t port=0;uint64_t connection=0;[c getClientTaskNamePort:&port clientConnectionIdentifier:&connection forTargetID:42 displayUUID:nil];assert(port==42&&connection==1234567890123ULL&&[received isEqual:display.UUID]);
 display.UUID=@"outer";attrs.display=builtin;assert(attrs.display==builtin);[c convertReferenceLocation:point toScreenLocationForDisplayUUID:nil];assert(!received);
 puts("Duo touch display routing: inner nil mapping, explicit IDs, outer fallback and ABI outputs passed");
}return 0;}
