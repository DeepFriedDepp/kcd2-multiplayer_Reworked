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
