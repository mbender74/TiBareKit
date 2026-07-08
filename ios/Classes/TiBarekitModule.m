/**
 * TiBareKit
 *
 * Created by Marc Bender
 * Copyright (c) 2026 Your Company. All rights reserved.
 */

#import "TiBarekitModule.h"
#import "TiBareWorkletProxy.h"
#import "TiBareIPCProxy.h"
#import "TiBase.h"
#import "TiHost.h"
#import "TiUtils.h"

@implementation TiBarekitModule

#pragma mark Internal

// This is generated for your module, please do not change it
- (id)moduleGUID
{
  return @"AF0202EB-6B2F-479E-97C3-FA416542FCE0";
}

// This is generated for your module, please do not change it
- (NSString *)moduleId
{
  return @"ti.barekit";
}

#pragma mark Lifecycle

- (void)startup
{
  // This method is called when the module is first loaded
  // You *must* call the superclass
  [super startup];
  DebugLog(@"[DEBUG] %@ loaded", self);
}

#pragma Public APIs

- (NSString *)example:(id)args
{
  // Example method. 
  // Call with "MyModule.example(args)"
  return @"hello world";
}

- (NSString *)exampleProp
{
  // Example property getter. 
  // Call with "MyModule.exampleProp" or "MyModule.getExampleProp()"
  return @"Titanium rocks!";
}

- (void)setExampleProp:(id)value
{
  // Example property setter.
  // Call with "MyModule.exampleProp = 'newValue'" or "MyModule.setExampleProp('newValue')"
}

- (id)createWorklet:(id)args {
  id options = nil;
  if ([args isKindOfClass:[NSArray class]] && [(NSArray *)args count] > 0) {
    options = [(NSArray *)args firstObject];
  }
  TiBareWorkletProxy *proxy = [[TiBareWorkletProxy alloc] _initWithPageContext:[self pageContext]];
  [proxy configureWithOptions:options];
  return proxy;
}

- (id)createIPC:(id)args {
  TiBareWorkletProxy *workletProxy = nil;
  if ([args isKindOfClass:[NSArray class]] && [(NSArray *)args count] > 0) {
    id first = [(NSArray *)args firstObject];
    if ([first isKindOfClass:[TiBareWorkletProxy class]]) {
      workletProxy = first;
    }
  }
  if (!workletProxy) return [NSNull null];
  TiBareIPCProxy *proxy = [[TiBareIPCProxy alloc] _initWithPageContext:[self pageContext]];
  [proxy attachToWorkletProxy:workletProxy];
  return proxy;
}

@end
