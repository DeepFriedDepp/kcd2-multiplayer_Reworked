add_library(KCDMP SHARED
    dllmain.cpp
    rttr_probe.cpp
    rttr_abi.cpp
    combat_playanim.cpp
    combat_construct.cpp
    main_thread.cpp
    pipe_server.cpp
    dice_hook.cpp
    lua_closure.cpp
)

target_include_directories(KCDMP PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(KCDMP PROPERTIES OUTPUT_NAME "KCDMP")
