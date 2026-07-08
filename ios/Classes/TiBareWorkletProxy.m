#import "TiBareWorkletProxy.h"
#import "TiBase.h"
#import "TiHost.h"
#import "TiUtils.h"
#import "TiBlob.h"
#import "KrollCallback.h"

@implementation TiBareWorkletProxy

- (void)configureWithOptions:(id)options {
  BareWorkletConfiguration *cfg = [BareWorkletConfiguration defaultWorkletConfiguration];
  if (options && [options isKindOfClass:[NSDictionary class]]) {
    id memLimit = [options objectForKey:@"memoryLimit"];
    if (memLimit) {
      cfg.memoryLimit = (NSUInteger)[TiUtils intValue:memLimit];
    }
    id assets = [options objectForKey:@"assets"];
    if (assets) {
      cfg.assets = [TiUtils stringValue:assets];
    }
  }
  _worklet = [[BareWorklet alloc] initWithConfiguration:cfg];
}

- (BareWorklet *)bareWorklet { return _worklet; }

- (void)start:(id)args {
  // args is an array-like: [filename, source?, arguments?]
  NSArray *arr = [args isKindOfClass:[NSArray class]] ? args : [NSArray array];
  NSString *filename = arr.count > 0 ? [TiUtils stringValue:arr[0]] : @"";
  id sourceArg = arr.count > 1 ? arr[1] : nil;
  NSArray *arguments = arr.count > 2 && [arr[2] isKindOfClass:[NSArray class]] ? arr[2] : @[];

  // Bundle loader: source null/absent and filename ends in .bundle
  BOOL isBundle = [filename hasSuffix:@".bundle"];
  if ((sourceArg == nil || sourceArg == [NSNull null]) && isBundle) {
    NSString *name = [filename stringByDeletingPathExtension];
    [_worklet start:name ofType:@"bundle" arguments:arguments];
    return;
  }

  NSData *sourceData = nil;
  if ([sourceArg isKindOfClass:[NSString class]]) {
    sourceData = [(NSString *)sourceArg dataUsingEncoding:NSUTF8StringEncoding];
  } else if ([sourceArg isKindOfClass:[TiBlob class]]) {
    sourceData = [(TiBlob *)sourceArg data];
  }

  if (sourceData) {
    [_worklet start:filename source:sourceData arguments:arguments];
  } else {
    [_worklet start:filename arguments:arguments];
  }
}

- (void)suspend:(id)args {
  if ([args isKindOfClass:[NSArray class]] && [(NSArray *)args count] > 0) {
    int linger = [TiUtils intValue:((NSArray *)args)[0]];
    [_worklet suspendWithLinger:linger];
  } else {
    [_worklet suspend];
  }
}

- (void)resume:(id)args {
  [_worklet resume];
}

- (void)terminate:(id)args {
  [_worklet terminate];
}

- (void)push:(id)args {
  // args: [payload, callback]
  NSArray *arr = [args isKindOfClass:[NSArray class]] ? args : [NSArray array];
  if (arr.count < 2) return;
  id payload = arr[0];
  KrollCallback *callback = [arr[1] isKindOfClass:[KrollCallback class]] ? arr[1] : nil;
  NSData *data = nil;
  if ([payload isKindOfClass:[NSString class]]) {
    data = [(NSString *)payload dataUsingEncoding:NSUTF8StringEncoding];
  } else if ([payload isKindOfClass:[TiBlob class]]) {
    data = [(TiBlob *)payload data];
  }
  if (!data || !callback) return;

  [_worklet push:data queue:[NSOperationQueue mainQueue] completion:^(NSData *reply, NSError *error) {
    NSDictionary *result;
    if (error) {
      result = @{ @"error": error.localizedDescription };
    } else if (reply) {
      TiBlob *blob = [[TiBlob alloc] initWithData:reply mimetype:@"application/octet-stream"];
      result = @{ @"reply": blob };
    } else {
      result = @{};
    }
    [callback call:@[ result ] thisObject:self];
  }];
}

@end