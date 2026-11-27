#import "XMPlusAudioStream.h"
#import <dlfcn.h>

// libmpv stream_cb ABI (include/mpv/stream_cb.h), API >= 1.106.
// No callbacks call mpv APIs. Only decoder threads wait; main and Dart stay free.
typedef struct {
    void *cookie;
    int64_t (*read_fn)(void *, char *, uint64_t);
    int64_t (*seek_fn)(void *, int64_t);
    int64_t (*size_fn)(void *);
    void (*close_fn)(void *);
    void (*cancel_fn)(void *);
} XMStreamInfo;
typedef int (*XMOpen)(void *, char *, XMStreamInfo *);
typedef int (*XMAddStream)(void *, const char *, void *, XMOpen);

@class XMStream;
@interface XMPlusAudioStream ()
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMutableSet<NSString *> *mounts;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *handles;
@property(nonatomic, strong) NSMutableSet<XMStream *> *streams;
@end

@interface XMStream : NSObject
@property(nonatomic, strong) XMPlusAudioStream *owner;
@property(nonatomic, copy) NSString *uri;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) int64_t offset;
@property(nonatomic) int64_t length;
- (NSDictionary *)fetch:(int64_t)offset count:(uint64_t)count;
- (void)cancel;
@end

@implementation XMStream
- (NSDictionary *)fetch:(int64_t)offset count:(uint64_t)count {
    if ([NSThread isMainThread]) return nil;
    // The response lives in this block's retained scope. A late result cannot
    // touch a decoder-owned buffer that has already been freed by cancellation.
    __block BOOL finished = NO;
    __block NSDictionary *response = nil;
    [self.condition lock];
    if (self.cancelled) { [self.condition unlock]; return nil; }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.condition lock];
        BOOL cancelled = self.cancelled;
        [self.condition unlock];
        if (cancelled) return;
        [self.owner.channel invokeMethod:@"read" arguments:@{
            @"id": self.identifier, @"uri": self.uri,
            @"offset": @(offset), @"count": @(MIN(count, 256 * 1024))
        } result:^(id result) {
            [self.condition lock];
            if ([result isKindOfClass:NSDictionary.class]) response = result;
            finished = YES;
            [self.condition broadcast];
            [self.condition unlock];
        }];
    });
    while (!finished && !self.cancelled) [self.condition wait];
    NSDictionary *value = !self.cancelled && finished ? response : nil;
    [self.condition unlock];
    return value;
}
- (void)cancel {
    [self.condition lock];
    BOOL notify = !self.cancelled;
    self.cancelled = YES;
    [self.condition broadcast];
    [self.condition unlock];
    if (notify) dispatch_async(dispatch_get_main_queue(), ^{
        [self.owner.channel invokeMethod:@"cancel" arguments:@{@"id": self.identifier}];
    });
}
@end

static int64_t XMRead(void *cookie, char *buffer, uint64_t count) {
    @autoreleasepool {
        XMStream *stream = (__bridge XMStream *)cookie;
        if (count == 0) return 0;
        NSDictionary *result = [stream fetch:stream.offset count:count];
        FlutterStandardTypedData *bytes = result[@"bytes"];
        if (![bytes isKindOfClass:FlutterStandardTypedData.class] || bytes.data.length > count) return -1;
        NSNumber *length = result[@"length"];
        if ([length isKindOfClass:NSNumber.class]) stream.length = length.longLongValue;
        memcpy(buffer, bytes.data.bytes, bytes.data.length);
        stream.offset += bytes.data.length;
        return (int64_t)bytes.data.length;
    }
}
static int64_t XMSeek(void *cookie, int64_t offset) {
    XMStream *stream = (__bridge XMStream *)cookie;
    [stream.condition lock];
    BOOL cancelled = stream.cancelled;
    [stream.condition unlock];
    if (cancelled || offset < 0 || (stream.length >= 0 && offset > stream.length)) return -1;
    stream.offset = offset;
    return offset;
}
static int64_t XMSize(void *cookie) {
    @autoreleasepool {
        XMStream *stream = (__bridge XMStream *)cookie;
        if (stream.length < 0) {
            NSDictionary *result = [stream fetch:0 count:1];
            NSNumber *length = result[@"length"];
            if ([length isKindOfClass:NSNumber.class]) stream.length = length.longLongValue;
        }
        return stream.length >= 0 ? stream.length : -2; // MPV_ERROR_UNSUPPORTED
    }
}
static void XMCancel(void *cookie) {
    @autoreleasepool { [(__bridge XMStream *)cookie cancel]; }
}
static void XMClose(void *cookie) {
    @autoreleasepool {
        XMStream *stream = (__bridge_transfer XMStream *)cookie;
        [stream cancel];
        [stream.owner.lock lock];
        [stream.owner.streams removeObject:stream];
        [stream.owner.lock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            [stream.owner.channel invokeMethod:@"closed" arguments:@{@"id": stream.identifier}];
        });
    }
}
static int XMOpenStream(void *context, char *uri, XMStreamInfo *info) {
    @autoreleasepool {
        XMPlusAudioStream *owner = (__bridge XMPlusAudioStream *)context;
        NSString *key = uri ? [NSString stringWithUTF8String:uri] : nil;
        [owner.lock lock];
        if (!key || ![owner.mounts containsObject:key]) { [owner.lock unlock]; return -13; }
        XMStream *stream = [XMStream new];
        stream.owner = owner;
        stream.uri = key;
        stream.identifier = NSUUID.UUID.UUIDString;
        stream.condition = [NSCondition new];
        stream.length = -1;
        [owner.streams addObject:stream];
        [owner.lock unlock];
        info->cookie = (__bridge_retained void *)stream;
        info->read_fn = XMRead;
        info->seek_fn = XMSeek;
        info->size_fn = XMSize;
        info->close_fn = XMClose;
        info->cancel_fn = XMCancel;
        return 0;
    }
}

@implementation XMPlusAudioStream
+ (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
    XMPlusAudioStream *bridge = [XMPlusAudioStream new];
    bridge.lock = [NSLock new];
    bridge.mounts = [NSMutableSet new];
    bridge.handles = [NSMutableSet new];
    bridge.streams = [NSMutableSet new];
    bridge.channel = [FlutterMethodChannel methodChannelWithName:@"teikengstudio.xmplus/audio-stream" binaryMessenger:messenger];
    // The engine owns the handler; each open cookie also retains the bridge.
    [bridge.channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
        NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
        if ([call.method isEqualToString:@"attach"]) {
            NSNumber *handle = args[@"handle"];
            if (![handle isKindOfClass:NSNumber.class] || handle.unsignedLongLongValue == 0) {
                result([FlutterError errorWithCode:@"audio_handle" message:@"播放器尚未初始化" details:nil]); return;
            }
            if ([bridge.handles containsObject:handle]) { result(nil); return; }
            // Reuse the shipped media_kit binary, including inside LiveContainer.
            NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"Mpv.framework/Mpv"];
            void *library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            XMAddStream add = library ? (XMAddStream)dlsym(library, "mpv_stream_cb_add_ro") : NULL;
            unsigned long (*version)(void) = library ? dlsym(library, "mpv_client_api_version") : NULL;
            unsigned long api = version ? version() : 0;
            BOOL supported = (api >> 16) >= 2 || ((api >> 16) == 1 && (api & 0xffff) >= 106);
            int status = add && supported ? add((void *)(uintptr_t)handle.unsignedLongLongValue, "xmpluscache", (__bridge void *)bridge, XMOpenStream) : -1;
            if (library) dlclose(library); // media_kit owns the original load.
            if (status < 0) {
                result([FlutterError errorWithCode:@"audio_stream_unavailable" message:@"音频读取初始化失败" details:@(status)]); return;
            }
            [bridge.handles addObject:handle];
            result(nil);
        } else if ([call.method isEqualToString:@"detach"]) {
            [bridge.handles removeObject:args[@"handle"]]; result(nil);
        } else if ([call.method isEqualToString:@"mount"] || [call.method isEqualToString:@"unmount"]) {
            NSString *uri = args[@"uri"];
            if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:@"xmpluscache://"]) {
                result([FlutterError errorWithCode:@"audio_uri" message:@"音频缓存无效" details:nil]); return;
            }
            [bridge.lock lock];
            if ([call.method isEqualToString:@"mount"]) {
                [bridge.mounts addObject:uri];
                [bridge.lock unlock];
            } else {
                [bridge.mounts removeObject:uri];
                NSArray<XMStream *> *streams = bridge.streams.allObjects;
                [bridge.lock unlock];
                for (XMStream *stream in streams) if ([stream.uri isEqualToString:uri]) [stream cancel];
            }
            result(nil);
        } else { result(FlutterMethodNotImplemented); }
    }];
}
@end
