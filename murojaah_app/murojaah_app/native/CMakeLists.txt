cmake_minimum_required(VERSION 3.18)
project(murojaah_core)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(murojaah_core SHARED murojaah_core.cpp)

# ---- ONNX Runtime (Android prebuilt) ----------------------------------------
# Download onnxruntime-android (AAR or prebuilt) and point ORT_DIR at it.
# set(ORT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/onnxruntime-android)
# target_include_directories(murojaah_core PRIVATE ${ORT_DIR}/headers)
# target_link_libraries(murojaah_core
#     ${ORT_DIR}/jni/${ANDROID_ABI}/libonnxruntime.so)

find_library(log-lib log)
target_link_libraries(murojaah_core ${log-lib})

# Wire this file into the Flutter Android module by adding to
# android/app/build.gradle:
#
#   android {
#     externalNativeBuild {
#       cmake { path = "../../native/CMakeLists.txt" }
#     }
#   }
