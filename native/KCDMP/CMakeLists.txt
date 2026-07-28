add_library(KCDMP SHARED
    dllmain.cpp
    rttr_probe.cpp
)

target_include_directories(KCDMP PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(KCDMP PROPERTIES OUTPUT_NAME "KCDMP")
