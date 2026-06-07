// audio_capture.mm — iOS low-latency mic capture via AVAudioEngine.
//
// Build as Objective-C++ (.mm). The tap block runs on a real-time-class
// audio thread; we down-convert Float32 → Int16 and push straight to
// mj_push_pcm. Same extern "C" ABI as the Android side.

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <vector>

#include "murojaah_core.h"

@interface MJMicSession : NSObject {
 @public
  AVAudioEngine* _engine;
  void* _core;
}
- (instancetype)initWithCore:(void*)core;
- (BOOL)start;
- (void)stop;
@end

@implementation MJMicSession

- (instancetype)initWithCore:(void*)core {
  if ((self = [super init])) {
    _engine = nil;
    _core = core;
  }
  return self;
}

- (BOOL)start {
  NSError* err = nil;
  AVAudioSession* sess = [AVAudioSession sharedInstance];
  // Record category, allow Bluetooth, prefer a short I/O buffer for latency.
  [sess setCategory:AVAudioSessionCategoryPlayAndRecord
        withOptions:(AVAudioSessionCategoryOptionAllowBluetooth |
                     AVAudioSessionCategoryOptionDefaultToSpeaker |
                     AVAudioSessionCategoryOptionAllowBluetoothA2DP)
              error:&err];
  if (err) return NO;
  [sess setMode:AVAudioSessionModeMeasurement error:&err];
  if (err) return NO;
  [sess setPreferredIOBufferDuration:0.010 error:nil];  // 10 ms
  [sess setActive:YES error:&err];
  if (err) return NO;

  _engine = [[AVAudioEngine alloc] init];
  AVAudioInputNode* input = _engine.inputNode;
  AVAudioFormat* fmt = [input inputFormatForBus:0];
  const double sample_rate = fmt.sampleRate;

  void* core = _core;
  [input installTapOnBus:0
              bufferSize:512  // ~10 ms @ 48 kHz
                  format:fmt
                   block:^(AVAudioPCMBuffer* buf, AVAudioTime* /*when*/) {
                     if (!core || buf.frameLength == 0) return;
                     const int n = (int)buf.frameLength;

                     if (buf.format.commonFormat == AVAudioPCMFormatInt16 &&
                         buf.int16ChannelData != nullptr) {
                       mj_push_pcm(core, buf.int16ChannelData[0], n,
                                   (int)sample_rate);
                       return;
                     }
                     if (buf.format.commonFormat == AVAudioPCMFormatFloat32 &&
                         buf.floatChannelData != nullptr) {
                       static thread_local std::vector<int16_t> tmp;
                       tmp.resize(n);
                       const float* src = buf.floatChannelData[0];
                       for (int i = 0; i < n; ++i) {
                         float v = src[i] * 32767.0f;
                         if (v > 32767.0f) v = 32767.0f;
                         else if (v < -32768.0f) v = -32768.0f;
                         tmp[i] = (int16_t)v;
                       }
                       mj_push_pcm(core, tmp.data(), n, (int)sample_rate);
                     }
                   }];

  [_engine prepare];
  return [_engine startAndReturnError:&err] && err == nil;
}

- (void)stop {
  if (_engine) {
    [_engine.inputNode removeTapOnBus:0];
    [_engine stop];
    _engine = nil;
  }
  [[AVAudioSession sharedInstance] setActive:NO
                                 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                       error:nil];
}

@end

extern "C" {

void* mj_mic_create(void* core_handle) {
  if (!core_handle) return nullptr;
  MJMicSession* m = [[MJMicSession alloc] initWithCore:core_handle];
  return (__bridge_retained void*)m;
}

int mj_mic_start(void* mic) {
  if (!mic) return 0;
  MJMicSession* m = (__bridge MJMicSession*)mic;
  return [m start] ? 1 : 0;
}

void mj_mic_stop(void* mic) {
  if (!mic) return;
  MJMicSession* m = (__bridge MJMicSession*)mic;
  [m stop];
}

void mj_mic_destroy(void* mic) {
  if (!mic) return;
  MJMicSession* m = (__bridge_transfer MJMicSession*)mic;
  (void)m;  // ARC releases
}

}  // extern "C"
