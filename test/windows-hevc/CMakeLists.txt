# kit-hevc-decode.exe: see inject.cmake (added to FreeRDP's build tree, never on its own)
add_executable(kit-hevc-decode kit-hevc-decode.c)
target_link_libraries(kit-hevc-decode PRIVATE freerdp winpr)
set_target_properties(kit-hevc-decode PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
