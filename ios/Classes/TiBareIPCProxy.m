#import "TiBareIPCProxy.h"
#import "TiBase.h"
#import "TiHost.h"
#import "TiUtils.h"
#import "TiBlob.h"
#import "KrollCallback.h"

@implementation TiBareIPCProxy

- (void)attachToWorkletProxy:(TiBareWorkletProxy *)workletProxy {
  _ipc = [[BareIPC alloc] initWithWorklet:[workletProxy bareWorklet]];
}

- (void)setReadable:(KrollCallback *)cb {
  _readableCb = cb;
  __weak TiBareIPCProxy *weakSelf = self;
  _ipc.readable = ^(BareIPC *ipc) {
    __strong TiBareIPCProxy *strong = weakSelf;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (strong->_readableCb) {
        [strong->_readableCb call:@[strong] thisObject:strong];
      }
    });
  };
}

- (void)setWritable:(KrollCallback *)cb {
  _writableCb = cb;
  __weak TiBareIPCProxy *weakSelf = self;
  _ipc.writable = ^(BareIPC *ipc) {
    __strong TiBareIPCProxy *strong = weakSelf;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (strong->_writableCb) {
        [strong->_writableCb call:@[strong] thisObject:strong];
      }
    });
  };
}

- (id)read:(id)args {
  if ([args isKindOfClass:[NSArray class]] && [(NSArray *)args count] > 0 &&
      [[(NSArray *)args firstObject] isKindOfClass:[KrollCallback class]]) {
    KrollCallback *cb = [(NSArray *)args firstObject];
    [_ipc read:^(NSData *data, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *result;
        if (error) {
          result = @{ @"error": error.localizedDescription };
        } else if (data) {
          TiBlob *blob = [[TiBlob alloc] initWithData:data mimetype:@"application/octet-stream"];
          result = @{ @"data": blob };
        } else {
          result = @{};
        }
        [cb call:@[ result ] thisObject:nil];
      });
    }];
    return [NSNull null];
  }
  // Synchronous read
  NSData *data = [_ipc read];
  if (!data) return [NSNull null];
  return [[TiBlob alloc] initWithData:data mimetype:@"application/octet-stream"];
}

- (id)write:(id)args {
  NSArray *arr = [args isKindOfClass:[NSArray class]] ? args : @[];
  if (arr.count == 0) return @0;
  id payload = arr[0];
  NSData *data = nil;
  if ([payload isKindOfClass:[NSString class]]) {
    data = [(NSString *)payload dataUsingEncoding:NSUTF8StringEncoding];
  } else if ([payload isKindOfClass:[TiBlob class]]) {
    data = [(TiBlob *)payload data];
  }
  if (!data) return @0;

  if (arr.count > 1 && [arr[1] isKindOfClass:[KrollCallback class]]) {
    KrollCallback *cb = arr[1];
    [_ipc write:data completion:^(NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *result = error ? @{ @"error": error.localizedDescription } : @{};
        [cb call:@[ result ] thisObject:nil];
      });
    }];
    return [NSNull null];
  }
  return @([_ipc write:data]);
}

- (void)close:(id)args {
  [_ipc close];
}

@end