# WO-129: engine-free native unit tests (no game). Built by Build-Native.ps1,
# run by tools\Build-Installer.ps1 after the native build.
add_executable(KCDMP_NativeTests wo129_gait_tests.cpp)
target_include_directories(KCDMP_NativeTests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../KCDMP)
