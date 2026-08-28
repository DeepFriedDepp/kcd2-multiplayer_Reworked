# WO-72 experiment target. Not part of the shipped product; nothing installs
# this DLL. Built alongside the real targets only so it uses the same toolchain
# and runtime as the plugin it borrows conventions from.
add_library(WO72NullRenderer SHARED main.cpp)
target_link_libraries(WO72NullRenderer PRIVATE psapi)
set_target_properties(WO72NullRenderer PROPERTIES OUTPUT_NAME "WO72NullRenderer")
