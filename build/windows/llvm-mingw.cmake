# Shared part of the llvm-mingw toolchain files; include it after setting LLVM_MINGW_ARCH
# (x86_64 or aarch64). The toolchain is mounted at /llvm-mingw inside the build container.
#
# CMAKE_SYSTEM_PROCESSOR must be the GNU name: cmake/DetectIntrinsicSupport.cmake only enables
# NEON without -mfpu=neon when it is exactly "aarch64" ("ARM64" is not in its NEON_LIST, so NEON
# would be skipped silently), and SSE/AVX when it is in its SSE_LIST ("x86_64" is).
set(CMAKE_SYSTEM_NAME Windows CACHE STRING "toolchain default")
set(CMAKE_SYSTEM_PROCESSOR ${LLVM_MINGW_ARCH} CACHE STRING "toolchain default")

set(LLVM_MINGW /llvm-mingw)
set(_t ${LLVM_MINGW}/bin/${LLVM_MINGW_ARCH}-w64-mingw32)
set(CMAKE_C_COMPILER ${_t}-clang CACHE STRING "toolchain default")
set(CMAKE_CXX_COMPILER ${_t}-clang++ CACHE STRING "toolchain default")
set(CMAKE_RC_COMPILER ${_t}-windres CACHE STRING "toolchain default")
set(CMAKE_AR ${LLVM_MINGW}/bin/llvm-ar CACHE STRING "toolchain default")
set(CMAKE_RANLIB ${LLVM_MINGW}/bin/llvm-ranlib CACHE STRING "toolchain default")
# the per-language archivers are used for some targets (static libs under IPO); CMake can't derive
# them from the llvm-mingw wrapper scripts and leaves them NOTFOUND
foreach(_l C CXX)
  set(CMAKE_${_l}_COMPILER_AR ${LLVM_MINGW}/bin/llvm-ar CACHE STRING "toolchain default")
  set(CMAKE_${_l}_COMPILER_RANLIB ${LLVM_MINGW}/bin/llvm-ranlib CACHE STRING "toolchain default")
endforeach()
set(CMAKE_NM ${LLVM_MINGW}/bin/llvm-nm CACHE STRING "toolchain default")
set(CMAKE_OBJCOPY ${LLVM_MINGW}/bin/llvm-objcopy CACHE STRING "toolchain default")
set(CMAKE_OBJDUMP ${LLVM_MINGW}/bin/llvm-objdump CACHE STRING "toolchain default")
set(CMAKE_STRIP ${LLVM_MINGW}/bin/llvm-strip CACHE STRING "toolchain default")
set(CMAKE_FIND_ROOT_PATH ${LLVM_MINGW}/${LLVM_MINGW_ARCH}-w64-mingw32)

# the rest mirrors upstream scripts/mingw64.cmake
set(CMAKE_WINDOWS_VERSION "WIN10" CACHE STRING "toolchain default")
set(CMAKE_BUILD_TYPE "RelWithDebInfo" CACHE STRING "toolchain default")
set(CMAKE_SKIP_INSTALL_ALL_DEPENDENCY ON CACHE BOOL "toolchain default")
set(THREADS_PREFER_PTHREAD_FLAG ON CACHE BOOL "toolchain default")
add_compile_definitions(__STDC_NO_THREADS__)
add_compile_definitions(__STDC_NO_ATOMICS__)
