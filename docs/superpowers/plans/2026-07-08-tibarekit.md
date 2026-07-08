# TiBareKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap the prebuilt bare-kit native libraries (iOS `BareKit.xcframework`, Android `bare-kit.aar`) in a Titanium module `ti.barekit` exposing `Worklet` and `IPC` classes to JS.

**Architecture:** Three layers per platform: (1) prebuilt native lib checked into `ios/platform/` and `android/lib/`; (2) native bridge proxies (`TiBareWorkletProxy`, `TiBareIPCProxy`) wrapping `BareWorklet`/`BareIPC` (iOS) and `to.holepunch.bare.kit.Worklet`/`IPC` (Android), marshalling Ti.Blob↔NSData/ByteBuffer and dispatching all callbacks on the main thread; (3) a CommonJS wrapper `assets/ti.barekit.js` exposing class-style `new Worklet`/`new IPC` over native factories.

**Tech Stack:** Titanium SDK 14.0.0, Objective-C/UIKit, Java/Kroll, CMake 4.0+ + NDK 28.x (only for the manual prebuild), bare-kit 2.3.0 with bare@1.29.4.

## Global Constraints

- Module id: `ti.barekit`; version: `1.0.0` (already in both manifests — do not change).
- Titanium SDK version pin: `14.0.0` in `ios/titanium.xcconfig` and `android/manifest` (`minsdk: 14.0.0`).
- No CMake/NDK in the module build path — native binaries are prebuilt and checked in.
- All native→JS callbacks MUST be dispatched on the platform main thread.
- JS data types: IPC `read`/`write`/`push` use Ti.Blob; Strings are accepted and UTF-8-encoded on the bridge.
- No `Co-Authored-By` trailer on commits (user preference).
- Commits use the Conventional-Commits-style prefix (`feat:`, `build:`, `docs:`, `chore:`).

---

## File Structure

### iOS
- **Modify** `ios/module.xcconfig` — add `FRAMEWORK_SEARCH_PATHS` and `-framework BareKit` linker flag.
- **Modify** `ios/TiBareKit.xcodeproj/project.pbxproj` — add file references + build-phase entries for new proxy classes and the `BareKit.xcframework`.
- **Modify** `ios/Classes/TiBarekitModule.h` — declare `createWorklet:`/`createIPC:`.
- **Modify** `ios/Classes/TiBarekitModule.m` — implement factories returning proxies.
- **Create** `ios/Classes/TiBareWorkletProxy.{h,m}` — `KrollProxy` wrapping `BareWorklet`.
- **Create** `ios/Classes/TiBareIPCProxy.{h,m}` — `KrollProxy` wrapping `BareIPC`.
- **Create** `ios/platform/BareKit.xcframework` — prebuilt, checked in (Task 1).

### Android
- **Modify** `android/build.gradle` — add `flatDir`-style AAR dependency on `lib/bare-kit.aar`.
- **Modify** `android/src/ti/barekit/TiBareKitModule.java` — add `createWorklet`/`createIPC` factories.
- **Create** `android/src/ti/barekit/TiBareWorkletProxy.java` — `KrollProxy` wrapping `to.holepunch.bare.kit.Worklet`.
- **Create** `android/src/ti/barekit/TiBareIPCProxy.java` — `KrollProxy` wrapping `to.holepunch.bare.kit.IPC`.
- **Create** `android/lib/bare-kit.aar` — prebuilt, checked in (Task 1).

### Shared
- **Create** `assets/ti.barekit.js` — CommonJS wrapper exporting `{ Worklet, IPC }` with `new`-style constructors.
- **Modify** `example/app.js` — replace skeleton with the demo from the spec.
- **Modify** `documentation/index.md` — full API documentation.
- **Modify** `README.md` — add prebuild instructions.

---

## Task 1: Prebuild native binaries

**Files:**
- Create: `ios/platform/BareKit.xcframework` (directory tree)
- Create: `android/lib/bare-kit.aar`
- Modify: `README.md` (prebuild section)

**Interfaces:** None. This task produces the binaries consumed by all later tasks.

- [ ] **Step 1: Verify bare-kit source is present and buildable**

```bash
ls /Users/marcbender/bare-kit/CMakeLists.txt
ls /Users/marcbender/bare-kit/prebuilds/Makefile
```

Expected: both paths exist.

- [ ] **Step 2: Prebuild iOS xcframework**

```bash
cd /Users/marcbender/bare-kit
make ios/BareKit.xcframework
```

Expected: produces `/Users/marcbender/bare-kit/ios/BareKit.xcframework` containing `ios-arm64` and `ios-arm64-simulator` (and/or `ios-x64-simulator`) slices.

- [ ] **Step 3: Copy xcframework into the module**

```bash
mkdir -p /Users/marcbender/Titanium-Modules/TiBareKit/ios/platform
cp -R /Users/marcbender/bare-kit/ios/BareKit.xcframework \
      /Users/marcbender/Titanium-Modules/TiBareKit/ios/platform/BareKit.xcframework
```

Verify: `ls /Users/marcbender/Titanium-Modules/TiBareKit/ios/platform/BareKit.xcframework` shows `Info.plist` and at least one `.framework` slice.

- [ ] **Step 4: Prebuild Android AAR**

```bash
cd /Users/marcbender/bare-kit
./gradlew :bare-kit:assembleRelease
# Output at android/build/outputs/aar/bare-kit-release.aar (path may differ — find with:)
find . -name "*bare-kit*.aar" -path "*/outputs/*"
```

If the make target is preferred instead:

```bash
make android/bare-kit   # extracts the AAR into prebuilds/android/bare-kit/
```

Expected: a `bare-kit-release.aar` (or unpacked `bare-kit/` dir with `jni/` ABIs).

- [ ] **Step 5: Copy AAR into the module**

```bash
mkdir -p /Users/marcbender/Titanium-Modules/TiBareKit/android/lib
cp <path-from-step-4>/bare-kit-release.aar \
   /Users/marcbender/Titanium-Modules/TiBareKit/android/lib/bare-kit.aar
```

Verify: `unzip -l /Users/marcbender/Titanium-Modules/TiBareKit/android/lib/bare-kit.aar` lists `classes.jar`, `jni/arm64-v8a/libbare-kit.so`, `jni/armeabi-v7a/libbare-kit.so`, `jni/x86/libbare-kit.so`, `jni/x86_64/libbare-kit.so`.

- [ ] **Step 6: Document the prebuild step in README.md**

Append to `README.md` under a new `## Prebuild (maintainers)` section:

```markdown
## Prebuild (maintainers)

Native binaries are checked in. Rebuild them when upgrading bare-kit:

### iOS
```bash
cd /path/to/bare-kit
make ios/BareKit.xcframework
cp -R ios/BareKit.xcframework /path/to/TiBareKit/ios/platform/BareKit.xcframework
```

### Android
```bash
cd /path/to/bare-kit
./gradlew :bare-kit:assembleRelease
cp android/build/outputs/aar/bare-kit-release.aar \
   /path/to/TiBareKit/android/lib/bare-kit.aar
```
```

- [ ] **Step 7: Commit**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
git add ios/platform/BareKit.xcframework android/lib/bare-kit.aar README.md
git commit -m "build: check in prebuilt BareKit.xcframework and bare-kit.aar"
```

---

## Task 2: iOS — link BareKit framework

**Files:**
- Modify: `ios/module.xcconfig`
- Modify: `ios/TiBareKit.xcodeproj/project.pbxproj`

**Interfaces:** None visible to JS; later iOS proxy tasks rely on `BareKit/BareKit.h` being importable and `BareKit` being linked.

- [ ] **Step 1: Append framework search path + linker flag to module.xcconfig**

Edit `ios/module.xcconfig`. Add at the bottom:

```
FRAMEWORK_SEARCH_PATHS = $(inherited) "$(SRCROOT)/platform"
OTHER_LDFLAGS = $(inherited) -framework BareKit
```

- [ ] **Step 2: Add the xcframework file reference to project.pbxproj**

In `ios/TiBareKit.xcodeproj/project.pbxproj`, add a new UUID (e.g. `BARE00001000000000000000A`) to the **PBXFileReference** section (copy the `TitaniumKit.xcframework` line as a template):

```
		BARE00001000000000000000A /* BareKit.xcframework */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; name = BareKit.xcframework; path = platform/BareKit.xcframework; sourceTree = "<group>"; };
```

Add a corresponding **PBXBuildFile** entry (UUID `BARE00002000000000000000B`):

```
		BARE00002000000000000000B /* BareKit.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = BARE00001000000000000000A /* BareKit.xcframework */; };
```

- [ ] **Step 3: Add the file reference to the Frameworks group + Link Binary With Libraries build phase**

In the **Group** containing `TitaniumKit.xcframework` (the Frameworks group), add the new fileRef line:

```
				BARE00001000000000000000A /* BareKit.xcframework */,
```

In the **PBXFrameworksBuildPhase** section (the "Link Binary With Libraries" phase), add the build-file entry:

```
				BARE00002000000000000000B /* BareKit.xcframework in Frameworks */,
```

(Use `grep -n "PBXFrameworksBuildPhase\|TitaniumKit.xcframework in Frameworks" ios/TiBareKit.xcodeproj/project.pbxproj` to locate the exact lines.)

- [ ] **Step 4: Verify build links BareKit**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p ios --build-only
```

Expected: build succeeds; the link log references `BareKit.framework`. If it fails with "framework not found", recheck `FRAMEWORK_SEARCH_PATHS` and the pbxproj entries.

- [ ] **Step 5: Commit**

```bash
git add ios/module.xcconfig ios/TiBareKit.xcodeproj/project.pbxproj
git commit -m "build(ios): link BareKit.xcframework"
```

---

## Task 3: Android — link bare-kit AAR

**Files:**
- Modify: `android/build.gradle`

**Interfaces:** None visible to JS yet; later Android proxy tasks rely on `to.holepunch.bare.kit.Worklet`/`IPC` being resolvable at compile + runtime.

- [ ] **Step 1: Add the AAR as a local dependency**

Replace the contents of `android/build.gradle` with:

```groovy
dependencies {
    releaseImplementation files('lib/bare-kit.aar')
}
```

- [ ] **Step 2: Verify the AAR is resolvable**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p android --build-only
```

Expected: build proceeds past dependency resolution. (It may fail later in Java compilation because the proxies don't reference `to.holepunch.bare.kit.*` yet — that's fine; the goal here is "AAR is on the classpath".) If it fails with "Could not find :bare-kit:", the `files('lib/bare-kit.aar')` path is wrong — confirm the file exists at `android/lib/bare-kit.aar`.

- [ ] **Step 3: Commit**

```bash
git add android/build.gradle
git commit -m "build(android): depend on local bare-kit.aar"
```

---

## Task 4: iOS — TiBareWorkletProxy + createWorklet factory

**Files:**
- Create: `ios/Classes/TiBareWorkletProxy.h`
- Create: `ios/Classes/TiBareWorkletProxy.m`
- Modify: `ios/Classes/TiBarekitModule.h`
- Modify: `ios/Classes/TiBarekitModule.m`
- Modify: `ios/TiBareKit.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces JS-callable: `TiBarekit.createWorklet({ memoryLimit?:int, assets?:string }) -> TiBareWorkletProxy`.
- The proxy exposes: `start(filename, source?, arguments?)`, `suspend()`, `suspend(lingerMs)`, `resume()`, `terminate()`, `push(payload, callback)`.

- [ ] **Step 1: Write the proxy header**

`ios/Classes/TiBareWorkletProxy.h`:

```objc
#import <Foundation/Foundation.h>
#import "TiProxy.h"
#import <BareKit/BareKit.h>

@interface TiBareWorkletProxy : TiProxy {
  BareWorklet *_worklet;
}
- (void)configureWithOptions:(id)options;
- (BareWorklet *)bareWorklet;
@end
```

- [ ] **Step 2: Write the proxy implementation**

`ios/Classes/TiBareWorkletProxy.m`:

```objc
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
    [callback call:@[ result ] this:self];
  }];
}

@end
```

- [ ] **Step 3: Declare the factory on the module header**

Replace `ios/Classes/TiBarekitModule.h` with:

```objc
#import "TiModule.h"

@interface TiBarekitModule : TiModule
- (id)createWorklet:(id)args;
- (id)createIPC:(id)args;
@end
```

(`createIPC:` is implemented in Task 5 — declaring it now avoids a second header edit.)

- [ ] **Step 4: Implement createWorklet in the module**

In `ios/Classes/TiBarekitModule.m`, add above `@end`:

```objc
- (id)createWorklet:(id)args {
  id options = nil;
  if ([args isKindOfClass:[NSArray class]] && [(NSArray *)args count] > 0) {
    options = [(NSArray *)args firstObject];
  }
  TiBareWorkletProxy *proxy = [[TiBareWorkletProxy alloc] initWithContext:[self pageContext]];
  [proxy configureWithOptions:options];
  return proxy;
}

- (id)createIPC:(id)args {
  // Implemented in Task 5.
  return [NSNull null];
}
```

Add `#import "TiBareWorkletProxy.h"` at the top of the file.

- [ ] **Step 5: Add the new source files to project.pbxproj**

Generate two fresh UUIDs (e.g. `BARE100000000000000000001A` / `BARE100000000000000000001B` for the .h, `BARE200000000000000000001A` / `BARE200000000000000000001B` for the .m) and add entries following the `TiBarekitModule` pattern:

- **PBXFileReference**:
```
		BARE100000000000000000001A /* TiBareWorkletProxy.h */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.h; name = "TiBareWorkletProxy.h"; path = "Classes/TiBareWorkletProxy.h"; sourceTree = "<group>"; };
		BARE200000000000000000001A /* TiBareWorkletProxy.m */ = {isa = PBXFileReference; fileEncoding = 4; lastKnownFileType = sourcecode.c.objc; name = "TiBareWorkletProxy.m"; path = "Classes/TiBareWorkletProxy.m"; sourceTree = "<group>"; };
```
- **PBXBuildFile**:
```
		BARE100000000000000000001B /* TiBareWorkletProxy.h in Headers */ = {isa = PBXBuildFile; fileRef = BARE100000000000000000001A /* TiBareWorkletProxy.h */; };
		BARE200000000000000000001B /* TiBareWorkletProxy.m in Sources */ = {isa = PBXBuildFile; fileRef = BARE200000000000000000001A /* TiBareWorkletProxy.m */; };
```
- Add `BARE100000000000000000001A` and `BARE200000000000000000001A` to the Classes **group children** (next to `TiBarekitModule.h`).
- Add `BARE100000000000000000001B` to **PBXHeadersBuildPhase** and `BARE200000000000000000001B` to **PBXSourcesBuildPhase**.

- [ ] **Step 6: Build to verify compilation**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p ios --build-only
```

Expected: compiles cleanly. If it fails with "use of undeclared identifier 'KrollCallback'", add `#import "KrollCallback.h"` to the proxy .m. If "no type or protocol named 'TiBlob'", confirm `#import "TiBlob.h"`.

- [ ] **Step 7: Commit**

```bash
git add ios/Classes/TiBareWorkletProxy.h ios/Classes/TiBareWorkletProxy.m \
        ios/Classes/TiBarekitModule.h ios/Classes/TiBarekitModule.m \
        ios/TiBareKit.xcodeproj/project.pbxproj
git commit -m "feat(ios): add TiBareWorkletProxy wrapping BareWorklet"
```

---

## Task 5: iOS — TiBareIPCProxy + createIPC factory

**Files:**
- Create: `ios/Classes/TiBareIPCProxy.h`
- Create: `ios/Classes/TiBareIPCProxy.m`
- Modify: `ios/Classes/TiBarekitModule.m` (replace the stub `createIPC:`)
- Modify: `ios/TiBareKit.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces JS-callable: `TiBarekit.createIPC(workletProxy) -> TiBareIPCProxy`.
- The proxy exposes: `read()` -> Ti.Blob|null, `write(data)` -> int, `read(callback)`, `write(data, callback)`, `close()`, and settable `readable`/`writable` callback properties.

- [ ] **Step 1: Write the proxy header**

`ios/Classes/TiBareIPCProxy.h`:

```objc
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
```

- [ ] **Step 2: Write the proxy implementation**

`ios/Classes/TiBareIPCProxy.m`:

```objc
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
  __weak typeof(self) weakSelf = self;
  _ipc.readable = ^(BareIPC *ipc) {
    __strong typeof(weakSelf) strong = weakSelf;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (strong->_readableCb) {
        [strong->_readableCb call:@[@[strong]] this:strong];
      }
    });
  };
}

- (void)setWritable:(KrollCallback *)cb {
  _writableCb = cb;
  __weak typeof(self) weakSelf = self;
  _ipc.writable = ^(BareIPC *ipc) {
    __strong typeof(weakSelf) strong = weakSelf;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (strong->_writableCb) {
        [strong->_writableCb call:@[@[strong]] this:strong];
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
        [cb call:@[ result ] this:nil];
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
        [cb call:@[ result ] this:nil];
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
```

- [ ] **Step 3: Replace the stub createIPC in the module**

In `ios/Classes/TiBarekitModule.m`, replace the stub body with:

```objc
- (id)createIPC:(id)args {
  TiBareWorkletProxy *workletProxy = nil;
  if ([args isKindOfClass:[NSArray class]] && [(NSArray *)args count] > 0) {
    id first = [(NSArray *)args firstObject];
    if ([first isKindOfClass:[TiBareWorkletProxy class]]) {
      workletProxy = first;
    }
  }
  if (!workletProxy) return [NSNull null];
  TiBareIPCProxy *proxy = [[TiBareIPCProxy alloc] initWithContext:[self pageContext]];
  [proxy attachToWorkletProxy:workletProxy];
  return proxy;
}
```

Add `#import "TiBareIPCProxy.h"` at the top.

- [ ] **Step 4: Add the IPC proxy files to project.pbxproj**

Repeat the pattern from Task 4 Step 5 with new UUIDs (e.g. `BARE300000000000000000001A/B` for the .h, `BARE400000000000000000001A/B` for the .m), updating PBXFileReference, PBXBuildFile, the Classes group, PBXHeadersBuildPhase, and PBXSourcesBuildPhase.

- [ ] **Step 5: Build to verify**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p ios --build-only
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add ios/Classes/TiBareIPCProxy.h ios/Classes/TiBareIPCProxy.m \
        ios/Classes/TiBareWorkletProxy.h ios/Classes/TiBareWorkletProxy.m \
        ios/Classes/TiBarekitModule.m ios/TiBareKit.xcodeproj/project.pbxproj
git commit -m "feat(ios): add TiBareIPCProxy wrapping BareIPC"
```

---

## Task 6: Android — TiBareWorkletProxy + createWorklet factory

**Files:**
- Create: `android/src/ti/barekit/TiBareWorkletProxy.java`
- Modify: `android/src/ti/barekit/TiBareKitModule.java`

**Interfaces:**
- Produces JS-callable: `TiBareKit.createWorklet(options) -> TiBareWorkletProxy`.
- The proxy exposes: `start(filename, source?, arguments?)`, `suspend()`, `suspend(linger)`, `resume()`, `terminate()`, `push(payload, callback)`.

- [ ] **Step 1: Write the proxy**

`android/src/ti/barekit/TiBareWorkletProxy.java`:

```java
package ti.barekit;

import org.appcelerator.kroll.KrollProxy;
import org.appcelerator.kroll.KrollCallback;
import org.appcelerator.kroll.annotations.Kroll;
import org.appcelerator.kroll.common.Log;
import org.appcelerator.titanium.TiBlob;
import org.appcelerator.titanium.io.TiBaseFile;
import org.appcelerator.titanium.TiApplication;
import to.holepunch.bare.kit.Worklet;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.io.InputStream;
import java.io.IOException;

@Kroll.proxy(creatableInModule = TiBareKitModule.class)
public class TiBareWorkletProxy extends KrollProxy {
  private static final String LCAT = "TiBareWorkletProxy";
  private Worklet worklet;

  public TiBareWorkletProxy() {
    super();
  }

  public Worklet getWorklet() { return worklet; }

  @Kroll.method
  public void handleCreationDict(org.appcelerator.kroll.KrollDict options) {
    super.handleCreationDict(options);
    Worklet.Options opts = new Worklet.Options();
    if (options != null) {
      if (options.containsKey("memoryLimit")) {
        opts.memoryLimit(options.getInt("memoryLimit"));
      }
      if (options.containsKey("assets")) {
        opts.assets(options.getString("assets"));
      }
    }
    worklet = new Worklet(opts);
  }

  private ByteBuffer toBuffer(Object payload) {
    if (payload == null) return null;
    if (payload instanceof TiBlob) {
      byte[] bytes = ((TiBlob) payload).getBytes();
      ByteBuffer buf = ByteBuffer.allocateDirect(bytes.length);
      buf.put(bytes);
      buf.flip();
      return buf;
    }
    if (payload instanceof String) {
      byte[] bytes = ((String) payload).getBytes(StandardCharsets.UTF_8);
      ByteBuffer buf = ByteBuffer.allocateDirect(bytes.length);
      buf.put(bytes);
      buf.flip();
      return buf;
    }
    return null;
  }

  @Kroll.method
  public void start(String filename, Object source, String[] arguments) throws IOException {
    if (source == null && filename.endsWith(".bundle")) {
      String name = filename.substring(0, filename.length() - ".bundle".length());
      InputStream is = TiApplication.getAppRootOrCurrentActivity().getAssets().open(name + ".bundle");
      worklet.start(filename, is, arguments);
      return;
    }
    ByteBuffer buf = toBuffer(source);
    if (buf != null) {
      worklet.start(filename, buf, arguments);
    } else {
      worklet.start(filename, arguments);
    }
  }

  @Kroll.method
  public void suspend() { worklet.suspend(); }

  @Kroll.method
  public void suspend(int linger) { worklet.suspend(linger); }

  @Kroll.method
  public void resume() { worklet.resume(); }

  @Kroll.method
  public void terminate() {
    if (worklet != null) { worklet.terminate(); worklet = null; }
  }

  @Kroll.method
  public void push(Object payload, KrollCallback callback) {
    ByteBuffer buf = toBuffer(payload);
    if (buf == null || callback == null) return;
    worklet.push(buf, (reply, error) -> {
      org.appcelerator.kroll.KrollDict result = new org.appcelerator.kroll.KrollDict();
      if (error != null) {
        result.put("error", error.getMessage());
      } else if (reply != null) {
        byte[] bytes = new byte[reply.remaining()];
        reply.get(bytes);
        result.put("reply", TiBlob.blobFromData(bytes));
      }
      callback.call(getKrollObject(), new Object[] { result });
    });
  }
}
```

Note: `TiBlob` lives in `org.appcelerator.titanium.TiBlob` (not `util`). Confirmed API on SDK 14.0.0 (from `titanium_mobile/android/titanium/src/java/org/appcelerator/titanium/TiBlob.java`): `TiBlob.blobFromData(byte[])`, `TiBlob.blobFromData(byte[], String)`, `getBytes()`. Import as `import org.appcelerator.titanium.TiBlob;` (update the import at the top of the file accordingly).

- [ ] **Step 2: Build to verify compilation**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p android --build-only
```

Expected: compiles cleanly (the `to.holepunch.bare.kit.Worklet` import resolves from the AAR). Fix any TiBlob method-name mismatches noted above before proceeding.

- [ ] **Step 3: Commit**

```bash
git add android/src/ti/barekit/TiBareWorkletProxy.java
git commit -m "feat(android): add TiBareWorkletProxy wrapping to.holepunch.bare.kit.Worklet"
```

---

## Task 7: Android — TiBareIPCProxy + createIPC factory

**Files:**
- Create: `android/src/ti/barekit/TiBareIPCProxy.java`
- Modify: `android/src/ti/barekit/TiBareKitModule.java`

**Interfaces:**
- Produces JS-callable: `TiBareKit.createIPC(workletProxy) -> TiBareIPCProxy`.
- The proxy exposes: `read()` -> Ti.Blob|null, `write(data)` -> int, `read(callback)`, `write(data, callback)`, `close()`, settable `readable`/`writable` callbacks.

- [ ] **Step 1: Write the proxy**

`android/src/ti/barekit/TiBareIPCProxy.java`:

```java
package ti.barekit;

import org.appcelerator.kroll.KrollProxy;
import org.appcelerator.kroll.KrollCallback;
import org.appcelerator.kroll.annotations.Kroll;
import org.appcelerator.kroll.common.Log;
import org.appcelerator.titanium.TiBlob;
import to.holepunch.bare.kit.IPC;
import to.holepunch.bare.kit.Worklet;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

@Kroll.proxy(creatableInModule = TiBareKitModule.class)
public class TiBareIPCProxy extends KrollProxy {
  private static final String LCAT = "TiBareIPCProxy";
  private IPC ipc;
  private KrollCallback readableCb;
  private KrollCallback writableCb;

  public TiBareIPCProxy() {
    super();
  }

  @Kroll.method
  public void handleCreationDict(org.appcelerator.kroll.KrollDict options) {
    super.handleCreationDict(options);
    Object workletArg = (options != null) ? options.get("worklet") : null;
    if (workletArg instanceof TiBareWorkletProxy) {
      ipc = new IPC(((TiBareWorkletProxy) workletArg).getWorklet());
    }
  }

  private ByteBuffer toBuffer(Object payload) {
    if (payload == null) return null;
    byte[] bytes;
    if (payload instanceof TiBlob) {
      bytes = ((TiBlob) payload).getBytes();
    } else if (payload instanceof String) {
      bytes = ((String) payload).getBytes(StandardCharsets.UTF_8);
    } else {
      return null;
    }
    ByteBuffer buf = ByteBuffer.allocateDirect(bytes.length);
    buf.put(bytes);
    buf.flip();
    return buf;
  }

  @Kroll.setProperty @Kroll.method
  public void setReadable(KrollCallback cb) {
    readableCb = cb;
    ipc.readable(() -> {
      if (readableCb != null) {
        getActivity().runOnUiThread(() -> readableCb.call(getKrollObject(), new Object[] { this }));
      }
    });
  }

  @Kroll.setProperty @Kroll.method
  public void setWritable(KrollCallback cb) {
    writableCb = cb;
    ipc.writable(() -> {
      if (writableCb != null) {
        getActivity().runOnUiThread(() -> writableCb.call(getKrollObject(), new Object[] { this }));
      }
    });
  }

  @Kroll.method
  public Object read(Object... args) {
    if (args != null && args.length > 0 && args[0] instanceof KrollCallback) {
      KrollCallback cb = (KrollCallback) args[0];
      ipc.read((data, error) -> {
        getActivity().runOnUiThread(() -> {
          org.appcelerator.kroll.KrollDict result = new org.appcelerator.kroll.KrollDict();
          if (error != null) result.put("error", error.getMessage());
          else if (data != null) {
            byte[] bytes = new byte[data.remaining()];
            data.get(bytes);
            result.put("data", TiBlob.blobFromData(bytes));
          }
          cb.call(getKrollObject(), new Object[] { result });
        });
      });
      return null;
    }
    ByteBuffer data = ipc.read();
    if (data == null) return null;
    byte[] bytes = new byte[data.remaining()];
    data.get(bytes);
    return TiBlob.blobFromData(bytes);
  }

  @Kroll.method
  public int write(Object... args) {
    if (args == null || args.length == 0) return 0;
    Object payload = args[0];
    ByteBuffer buf = toBuffer(payload);
    if (buf == null) return 0;
    if (args.length > 1 && args[1] instanceof KrollCallback) {
      KrollCallback cb = (KrollCallback) args[1];
      ipc.write(buf, error -> {
        getActivity().runOnUiThread(() -> {
          org.appcelerator.kroll.KrollDict result = new org.appcelerator.kroll.KrollDict();
          if (error != null) result.put("error", error.getMessage());
          cb.call(getKrollObject(), new Object[] { result });
        });
      });
      return 0;
    }
    return ipc.write(buf);
  }

  @Kroll.method
  public void close() { if (ipc != null) { ipc.close(); } }
}
```

Same TiBlob import/API note as Task 6 Step 1 (`org.appcelerator.titanium.TiBlob`, `blobFromData(byte[])`, `getBytes()`).

- [ ] **Step 2: Wire createWorklet / createIPC on the module**

In `android/src/ti/barekit/TiBareKitModule.java`, add factory methods. Replace the example methods block with:

```java
@Kroll.method
public TiBareWorkletProxy createWorklet(KrollDict options) {
  TiBareWorkletProxy proxy = new TiBareWorkletProxy();
  proxy.handleCreationDict(options != null ? options : new KrollDict());
  return proxy;
}

@Kroll.method
public TiBareIPCProxy createIPC(KrollDict options) {
  TiBareIPCProxy proxy = new TiBareIPCProxy();
  proxy.handleCreationDict(options != null ? options : new KrollDict());
  return proxy;
}
```

Add the imports `KrollDict`, `TiBareWorkletProxy`, `TiBareIPCProxy`.

Note: for `createIPC`, the caller passes `{ worklet: <proxy> }` so the IPC proxy can find the worklet handle. Adjust the JS wrapper in Task 8 to call `createIPC({ worklet })` rather than `createIPC(worklet)` on Android.

- [ ] **Step 3: Build to verify**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p android --build-only
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add android/src/ti/barekit/TiBareIPCProxy.java android/src/ti/barekit/TiBareKitModule.java
git commit -m "feat(android): add TiBareIPCProxy wrapping to.holepunch.bare.kit.IPC"
```

---

## Task 8: JS wrapper — `assets/ti.barekit.js`

**Files:**
- Create: `assets/ti.barekit.js`

**Interfaces:**
- Produces `require('ti.barekit') -> { Worklet, IPC }`.
- `new Worklet(options?)` calls `TiBarekit.createWorklet(options || {})` (iOS) or `TiBarekit.createWorklet({memoryLimit, assets})` (Android).
- `new IPC(worklet)` calls `TiBarekit.createIPC(worklet)` (iOS) or `TiBarekit.createIPC({ worklet })` (Android).
- Proxy methods are called through the returned proxy objects.

- [ ] **Step 1: Write the wrapper**

`assets/ti.barekit.js`:

```js
const tibarekit = require('ti.barekit'); // native module proxy
const isAndroid = Ti.Platform.name === 'android';

class Worklet {
  constructor(options) {
    const opts = options || {};
    if (isAndroid) {
      this._proxy = tibarekit.createWorklet(opts);
    } else {
      this._proxy = tibarekit.createWorklet(opts);
    }
  }

  start(filename, source, arguments_) {
    if (arguments_ === undefined) arguments_ = [];
    if (source === undefined) source = null;
    this._proxy.start(filename, source, arguments_);
  }

  suspend(linger) {
    if (linger === undefined) this._proxy.suspend();
    else this._proxy.suspend(linger);
  }

  resume() { this._proxy.resume(); }
  terminate() { this._proxy.terminate(); }

  push(payload, callback) { this._proxy.push(payload, callback); }
}

class IPC {
  constructor(worklet) {
    if (isAndroid) {
      this._proxy = tibarekit.createIPC({ worklet: worklet._proxy });
    } else {
      this._proxy = tibarekit.createIPC(worklet._proxy);
    }
  }

  set readable(fn) {
    if (isAndroid) this._proxy.setReadable(fn);
    else this._proxy.readable = fn;
  }
  set writable(fn) {
    if (isAndroid) this._proxy.setWritable(fn);
    else this._proxy.writable = fn;
  }

  read(callback) {
    if (callback === undefined) return this._proxy.read();
    return this._proxy.read(callback);
  }

  write(data, callback) {
    if (callback === undefined) return this._proxy.write(data);
    return this._proxy.write(data, callback);
  }

  close() { this._proxy.close(); }
}

module.exports = { Worklet, IPC };
```

- [ ] **Step 2: Verify it loads (build-only smoke test)**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p ios --build-only
ti build -p android --build-only
```

Expected: both succeed (the wrapper is a JS asset, so build-only won't exercise it; this is just to confirm packaging).

- [ ] **Step 3: Commit**

```bash
git add assets/ti.barekit.js
git commit -m "feat: add JS wrapper for Worklet and IPC"
```

---

## Task 9: Example app

**Files:**
- Modify: `example/app.js`

**Interfaces:** Consumes `assets/ti.barekit.js` exports `{ Worklet, IPC }`.

- [ ] **Step 1: Replace example/app.js with the demo**

`example/app.js`:

```js
import { Worklet, IPC } from 'ti.barekit';

const worklet = new Worklet({ memoryLimit: 24 * 1024 * 1024 });
const ipc = new IPC(worklet);

const src = `
  console.log('hello from the worklet');
  Bare.on('uncaughtException', (err) => {
    BareKit.IPC.write('FATAL: ' + err.message);
  });
  BareKit.IPC.on('data', (data) => {
    BareKit.IPC.write('echo: ' + data.toString());
  });
`;

worklet.start('/app.js', src, ['--flag']);

ipc.readable = () => {
  const d = ipc.read();
  if (d) Ti.API.info('[polling] worklet: ' + d.toString());
};
ipc.writable = () => {
  ipc.write('ping from main (polling)');
  ipc.writable = null;
};

ipc.write('async hello', (err) => {
  if (err) return Ti.API.error('write err: ' + err);
  ipc.read((data, err) => {
    if (err) return Ti.API.error('read err: ' + err);
    Ti.API.info('[async] worklet: ' + data.toString());
  });
});

worklet.push('check', (reply, err) => {
  if (err) return Ti.API.error('push err: ' + err);
  Ti.API.info('[push] reply: ' + reply.toString());
});

// Bundle loader (uncomment when app.bundle is present):
// const bundled = new Worklet();
// bundled.start('/app.bundle', null, ['--prod']);

setTimeout(() => { worklet.suspend(); Ti.API.info('suspended'); }, 2000);
setTimeout(() => { worklet.resume();  Ti.API.info('resumed');  }, 4000);
setTimeout(() => { worklet.terminate(); Ti.API.info('terminated'); }, 6000);

const win = Ti.UI.createWindow({ backgroundColor: '#fff' });
win.add(Ti.UI.createLabel({ text: 'TiBareKit — see console for output' }));
win.open();
```

Note: the example uses the `readable`/`writable` property setters and `read`/`write` overloads. The JS wrapper in Task 8 must route those correctly — revisit if the example throws at runtime.

- [ ] **Step 2: Run the example on iOS**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p ios
```

Expected: app launches in the simulator; console shows `hello from the worklet`, `[polling] worklet:`, `[async] worklet:`, `[push] reply:`, then `suspended` / `resumed` / `terminated` at 2s/4s/6s.

- [ ] **Step 3: Run the example on Android**

```bash
ti build -p android
```

Expected: same console sequence in logcat (`adb logcat | grep TiAPI` or the Ti console).

- [ ] **Step 4: Commit**

```bash
git add example/app.js
git commit -m "docs: add full-featured example app"
```

---

## Task 10: Documentation

**Files:**
- Modify: `documentation/index.md`
- Modify: `README.md` (project-usage section, if not already covered)

- [ ] **Step 1: Write documentation/index.md**

Replace the contents of `documentation/index.md` with a full API guide covering: installation (`<modules><module version="1.0.0">ti.barekit</module></modules>`), `require('ti.barekit')` / ES import, `new Worklet({ memoryLimit, assets })`, `start(filename, source?, arguments?)` with bundle-loader note, `suspend`/`suspend(linger)`/`resume`/`terminate`, `push(payload, cb)` with reply/error shape, `new IPC(worklet)`, `readable`/`writable` setters, `read()`/`read(cb)`, `write(data)`/`write(data, cb)`, `close()`, the `memoryLimit`/`assets` configuration, the bundle-loader (`.bundle` + `null` source), and the uncaughtException behavior with the `Bare.on('uncaughtException', …)` snippet copied from the bare-kit README.

- [ ] **Step 2: Append a Project Usage section to README.md if missing**

If `README.md` does not already document `<modules><module version="1.0.0">ti.barekit</module></modules>` and the `require('ti.barekit')` pattern (the existing scaffold README does — confirm and leave as-is, or fix if the skeleton wording is too generic).

- [ ] **Step 3: Commit**

```bash
git add documentation/index.md README.md
git commit -m "docs: write full API documentation"
```

---

## Task 11: Final verification build

**Files:** None (verification only).

- [ ] **Step 1: Clean build both platforms**

```bash
cd /Users/marcbender/Titanium-Modules/TiBareKit
ti build -p ios --build-only
ti build -p android --build-only
```

Expected: both produce a packaged module zip in the module root (e.g. `ti.barekit-iphone-1.0.0.zip` and `ti.barekit-android-1.0.0.zip`).

- [ ] **Step 2: Run the example app on both platforms**

```bash
ti build -p ios
ti build -p android
```

Expected: the full console sequence from Task 9 Step 2/3 on both platforms.

- [ ] **Step 3: Tag the release (optional)**

```bash
git tag v1.0.0
```

No commit — this is just a marker. Skip if tagging isn't part of the workflow yet.