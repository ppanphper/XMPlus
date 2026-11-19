#import <Flutter/Flutter.h>

/// Bridges libmpv's read/seek callbacks to the existing Dart AudioCache.
@interface XMPlusAudioStream : NSObject
+ (void)registerWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;
@end
