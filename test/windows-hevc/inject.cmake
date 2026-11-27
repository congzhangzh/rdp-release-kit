# The CI's HEVC decode test (kit-hevc-decode.c), added to the Windows client's own FreeRDP build
# tree: build/build-windows-client.sh passes this file as CMAKE_PROJECT_FreeRDP_INCLUDE, so CMake
# reads it right after FreeRDP's project() and, through the deferred call, defines the test once
# FreeRDP's own CMakeLists.txt is done, when the freerdp and winpr targets exist. The target is
# defined in the call itself: a deferred call may not add a subdirectory ("Subdirectories may not
# be created during deferred execution", kit probe run 46027568715). The test links freerdp and
# winpr as the client does, with FFmpeg's libraries and the same compiler and flags; it is outside
# "all", so the client, its build and its zip do not change. Only the client's build reads it.
set(KIT_HEVC_DECODE_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "test/windows-hevc in the kit")
function(kit_hevc_decode_add)
  add_executable(kit-hevc-decode EXCLUDE_FROM_ALL "${KIT_HEVC_DECODE_DIR}/kit-hevc-decode.c")
  target_link_libraries(kit-hevc-decode PRIVATE freerdp winpr)
  set_target_properties(kit-hevc-decode PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/kit-hevc-decode")
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL kit_hevc_decode_add)
