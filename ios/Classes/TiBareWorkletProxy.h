#import <Foundation/Foundation.h>
#import "TiProxy.h"
#import <BareKit/BareKit.h>

@interface TiBareWorkletProxy : TiProxy {
  BareWorklet *_worklet;
}
- (void)configureWithOptions:(id)options;
- (BareWorklet *)bareWorklet;
@end