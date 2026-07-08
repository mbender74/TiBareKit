#import <Foundation/Foundation.h>
#import "TiProxy.h"
#import "TiBareWorkletProxy.h"
#import <BareKit/BareKit.h>

@interface TiBareIPCProxy : TiProxy {
  BareIPC *_ipc;
  KrollCallback *_readableCb;
  KrollCallback *_writableCb;
}
- (void)attachToWorkletProxy:(TiBareWorkletProxy *)workletProxy;
@end