# Mac Catalyst toolchain for arm64. Model on cmake-toolchains/ios-arm64.cmake.
# Substitute <BARE_MAKE_CMAKE_TOOLCHAINS> with the path to the cmake-toolchains
#   dir shipped with bare-make, e.g. $(npm root -g)/bare-make/node_modules/cmake-toolchains
# Substitute <MACOSX_SDK> with your MacOSX SDK path, e.g. $(xcrun --sdk macosx --show-sdk-path)
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

include("<BARE_MAKE_CMAKE_TOOLCHAINS>/apple/find-clang.cmake")

set(target arm64-apple-ios14.0-macabi)

set(CMAKE_C_COMPILER ${clang})
set(CMAKE_C_COMPILER_TARGET ${target})

set(CMAKE_CXX_COMPILER ${clang++})
set(CMAKE_CXX_COMPILER_TARGET ${target})
set(CMAKE_CXX_COMPILER_CLANG_SCAN_DEPS ${clang-scan-deps})

set(CMAKE_ASM_COMPILER ${clang})
set(CMAKE_ASM_COMPILER_TARGET ${target})

set(CMAKE_OBJC_COMPILER ${clang})
set(CMAKE_OBJC_COMPILER_TARGET ${target})

set(CMAKE_OBJCXX_COMPILER ${clang++})
set(CMAKE_OBJCXX_COMPILER_TARGET ${target})

set(CMAKE_OSX_SYSROOT macosx)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
set(CMAKE_OSX_ARCHITECTURES arm64)

set(macosx_sdk "<MACOSX_SDK>")
set(iossupport_fw "${macosx_sdk}/System/iOSSupport/System/Library/Frameworks")
set(extra_flags "-iframework ${iossupport_fw} -Wno-incompatible-sysroot")
set(link_extra_flags "-iframework ${iossupport_fw} -Wno-incompatible-sysroot -Wl,-undefined,dynamic_lookup")

set(CMAKE_C_FLAGS_INIT "${extra_flags}")
set(CMAKE_CXX_FLAGS_INIT "${extra_flags}")
set(CMAKE_OBJC_FLAGS_INIT "${extra_flags}")
set(CMAKE_OBJCXX_FLAGS_INIT "${extra_flags}")
set(CMAKE_ASM_FLAGS_INIT "${extra_flags}")

set(CMAKE_SHARED_LINKER_FLAGS_INIT "${link_extra_flags}")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "${link_extra_flags}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${link_extra_flags}")

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_MACOSX_BUNDLE OFF)