cmake_minimum_required(VERSION 3.18)
project(murojaah_core CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Core sources (DSP + VAD + greedy + beam + lexicon + orchestrator)
set(MJ_CORE_SOURCES
  murojaah_core.cpp
  dsp.cpp
  vad.cpp
  ctc_decode.cpp
  beam_decode.cpp
  lexicon.cpp
)

# Android adds Oboe-backed mic capture in the same .so.
if(ANDROID)
  list(APPEND MJ_CORE_SOURCES audio_capture_oboe.cpp)
endif()

add_library(murojaah_core SHARED ${MJ_CORE_SOURCES})

target_compile_options(murojaah_core PRIVATE
  -O3 -ffast-math -fvisibility=hidden
)

# ─── ONNX Runtime (Android prebuilt) ──────────────────────────────────────────
# Download onnxruntime-android (AAR or prebuilt) and point ORT_DIR at it:
#
#   set(ORT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime-android)
#   target_include_directories(murojaah_core PRIVATE ${ORT_DIR}/headers)
#   target_link_libraries(murojaah_core
#       ${ORT_DIR}/jni/${ANDROID_ABI}/libonnxruntime.so)

# ─── Oboe (Android low-latency audio) ─────────────────────────────────────────
# NDK r21+ ships Oboe as a prefab:
#
#   find_package(oboe REQUIRED CONFIG)
#   target_link_libraries(murojaah_core PRIVATE oboe::oboe)
#
# Also enable prefab in android/app/build.gradle:
#
#   android {
#     buildFeatures { prefab = true }
#     dependencies { implementation 'com.google.oboe:oboe:1.9.0' }
#   }

find_library(log-lib log)
target_link_libraries(murojaah_core PRIVATE ${log-lib})

# Symbols Dart calls via dart:ffi must be exported even with visibility=hidden.
# Mark them at the source level (extern "C" in the headers) and they remain
# visible to the dynamic linker via the function-default visibility on Android.

# ─── iOS notes ────────────────────────────────────────────────────────────────
# On iOS add all .cpp + audio_capture.mm to the Runner target in Xcode and
# link AVFoundation + onnxruntime.xcframework. Use Dart's
# DynamicLibrary.process() to resolve the symbols.
