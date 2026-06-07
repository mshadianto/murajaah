cmake_minimum_required(VERSION 3.18)
project(murojaah_core CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_library(murojaah_core SHARED
  murojaah_core.cpp
  dsp.cpp
  vad.cpp
  ctc_decode.cpp
)

target_compile_options(murojaah_core PRIVATE
  -O3 -ffast-math -fvisibility=hidden
)

# ─── ONNX Runtime (Android prebuilt) ──────────────────────────────────────────
# Download onnxruntime-android (AAR or prebuilt) and point ORT_DIR at it.
#
#   set(ORT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime-android)
#   target_include_directories(murojaah_core PRIVATE ${ORT_DIR}/headers)
#   target_link_libraries(murojaah_core
#       ${ORT_DIR}/jni/${ANDROID_ABI}/libonnxruntime.so)
#
# Then in android/app/build.gradle add:
#   android {
#     externalNativeBuild { cmake { path = "../../native/CMakeLists.txt" } }
#     defaultConfig { externalNativeBuild { cmake { cppFlags "-std=c++17" } } }
#   }

find_library(log-lib log)
target_link_libraries(murojaah_core PRIVATE ${log-lib})

# ─── iOS notes ────────────────────────────────────────────────────────────────
# On iOS the symbols must live in the runner process (Dart uses
# DynamicLibrary.process()). Add all .cpp here to the Runner target in Xcode
# and link onnxruntime.xcframework. Set `-fvisibility=default` for mj_* symbols
# via an exported header, or export them via the linker:
#   OTHER_LDFLAGS += -Wl,-exported_symbol,_mj_create
#                    -Wl,-exported_symbol,_mj_destroy
#                    -Wl,-exported_symbol,_mj_push_pcm
#                    -Wl,-exported_symbol,_mj_infer_hop
