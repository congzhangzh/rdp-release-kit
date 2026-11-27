# The CI's HEVC decode test (kit-hevc-decode.c), added to the Windows client's own FreeRDP build
# tree: build/build-windows-client.sh passes this file as CMAKE_PROJECT_FreeRDP_INCLUDE, so CMake
# reads it right after FreeRDP's project() and, through the deferred call, adds this directory once
# FreeRDP's own CMakeLists.txt is done, when the freerdp and winpr targets exist. The test links
# them as the client does, with FFmpeg's libraries and the same compiler and flags; it is outside
# "all", so the client, its build and its zip do not change. Only the client's build reads it.
set(KIT_HEVC_DECODE_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "test/windows-hevc in the kit")
function(kit_hevc_decode_add)
  add_subdirectory("${KIT_HEVC_DECODE_DIR}" "${CMAKE_BINARY_DIR}/kit-hevc-decode" EXCLUDE_FROM_ALL)
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL kit_hevc_decode_add)
