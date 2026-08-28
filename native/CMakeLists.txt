cmake_minimum_required(VERSION 3.21)
project(KCDMP_Native CXX)

# The game is MSVC x64. Build with the same toolchain so the C++ ABI matches --
# we call into exported, mangled C++ symbols in CrySystem.dll, and a different
# ABI would misplace class-type arguments and returns.
if(NOT MSVC)
    message(FATAL_ERROR "Must be built with MSVC: this links against the game's C++ ABI.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_subdirectory(KCDMP)
add_subdirectory(KCDMP_LauncherInjector)

# --- WO-72 experiment (NOT product) -------------------------------------
# A throwaway probe DLL used to measure which IRenderer methods a headless boot
# actually calls (docs/WO-72-*). Nothing installs or ships it; turn it off with
# -DKCDMP_BUILD_EXPERIMENTS=OFF if it ever gets in the way.
option(KCDMP_BUILD_EXPERIMENTS "Build native/experiments/* probe targets" ON)
if(KCDMP_BUILD_EXPERIMENTS)
    add_subdirectory(experiments/wo72_nullrenderer)
endif()
