cmake_minimum_required(VERSION 3.24)

project(NovationTwitchModernAudioExperimental VERSION 0.3.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum supported macOS")

# libASPL 3.1.2 predates CMake's stricter CMP0175 validation. Keep the
# dependency's historical add_custom_command behavior without patching it.
if(POLICY CMP0175)
  cmake_policy(SET CMP0175 OLD)
  set(CMAKE_POLICY_DEFAULT_CMP0175 OLD CACHE STRING
      "Compatibility default for pinned libASPL" FORCE)
endif()

include(FetchContent)

FetchContent_Declare(
  libASPL
  GIT_REPOSITORY https://github.com/gavv/libASPL.git
  GIT_TAG 633e0f70203edd87d320fc5a3cae901e1363aac5
  GIT_SHALLOW FALSE
  GIT_PROGRESS TRUE
  UPDATE_DISCONNECTED TRUE
)
set(BUILD_TESTING OFF CACHE BOOL "Disable dependency tests" FORCE)
set(BUILD_DOCUMENTATION OFF CACHE BOOL "Disable dependency docs" FORCE)
FetchContent_MakeAvailable(libASPL)

set(DRIVER_NAME NovationTwitchModernAudioExperimental)
set(DRIVER_IDENTIFIER com.twitchmodern.NovationTwitchModernAudioExperimental)
set(DRIVER_UID 2353DB3F-EC93-48E7-B926-F2988B45F5EB)
set(DRIVER_ENTRYPOINT NovationTwitchModernAudioExperimental_Create)

add_library(TwitchSharedAudio STATIC ../shared/SharedAudioRing.cpp)
target_include_directories(TwitchSharedAudio PUBLIC ../shared)
target_compile_options(TwitchSharedAudio PRIVATE -Wall -Wextra -Werror)

add_library(TwitchXPCClient STATIC ../shared/XPCClient.cpp)
target_include_directories(TwitchXPCClient PUBLIC ../shared)
target_link_libraries(TwitchXPCClient PUBLIC TwitchSharedAudio)
target_compile_options(TwitchXPCClient PRIVATE
  -Wall -Wextra -Werror -fblocks)

add_library(${DRIVER_NAME} MODULE Driver.cpp)
target_link_libraries(${DRIVER_NAME} PRIVATE libASPL TwitchSharedAudio TwitchXPCClient)
target_compile_options(${DRIVER_NAME} PRIVATE
  -Wall
  -Wextra
  # Warnings originate in the pinned libASPL public headers under Xcode 26.
  -Wno-reorder-init-list
  -Wno-unused-parameter
  -fblocks
)

set_target_properties(${DRIVER_NAME} PROPERTIES
  OUTPUT_NAME "${DRIVER_NAME}"
  BUNDLE TRUE
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "Copyright 2026 Novation Twitch Modern contributors"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
)

add_custom_command(
  TARGET ${DRIVER_NAME}
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory
          "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>/Contents/Resources"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/../licenses/libASPL-LICENSE.txt"
          "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>/Contents/Resources/libASPL-LICENSE.txt"
  COMMENT "Embedding libASPL license notice"
  VERBATIM
)

add_executable(TwitchAudioXPCService ../usb-bridge/XPCDiscardService.cpp)
target_link_libraries(TwitchAudioXPCService PRIVATE
  TwitchSharedAudio)
target_compile_options(TwitchAudioXPCService PRIVATE
  -Wall -Wextra -Werror -fblocks)
add_dependencies(${DRIVER_NAME} TwitchAudioXPCService)
add_custom_command(
  TARGET ${DRIVER_NAME}
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "$<TARGET_FILE:TwitchAudioXPCService>"
          "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>/Contents/Resources/TwitchAudioXPCService"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${CMAKE_CURRENT_SOURCE_DIR}/../xpc-service/com.twitchmodern.NovationTwitchModernAudioExperimental.bridge.plist"
          "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>/Contents/Resources/com.twitchmodern.NovationTwitchModernAudioExperimental.bridge.plist"
  COMMENT "Embedding the USB-independent XPC bridge service"
  VERBATIM
)

set(CODESIGN_ID "-" CACHE STRING "Signing identity; '-' means ad-hoc")
if(NOT CODESIGN_ID STREQUAL "")
  add_custom_command(
    TARGET ${DRIVER_NAME}
    POST_BUILD
    COMMAND codesign --force --sign "${CODESIGN_ID}" --timestamp=none
            "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>"
    COMMENT "Signing ${DRIVER_NAME}.driver with identity '${CODESIGN_ID}'"
    VERBATIM
  )
endif()

enable_testing()
find_library(CORE_FOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
find_library(CORE_AUDIO_FRAMEWORK CoreAudio REQUIRED)
add_executable(HalProbeFactoryTest ../tests/HalProbeFactoryTest.cpp)
target_link_libraries(HalProbeFactoryTest PRIVATE
  ${CORE_FOUNDATION_FRAMEWORK}
  ${CORE_AUDIO_FRAMEWORK}
)
add_dependencies(HalProbeFactoryTest ${DRIVER_NAME})
add_test(
  NAME HalProbeFactoryTest
  COMMAND HalProbeFactoryTest "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>"
)

add_executable(HalLiveProbe ../tests/HalLiveProbe.cpp)
target_link_libraries(HalLiveProbe PRIVATE
  ${CORE_FOUNDATION_FRAMEWORK}
  ${CORE_AUDIO_FRAMEWORK}
)

add_executable(TwitchAudioDiscardHelper ../usb-bridge/DiscardHelper.cpp)
target_link_libraries(TwitchAudioDiscardHelper PRIVATE TwitchSharedAudio)
target_compile_options(TwitchAudioDiscardHelper PRIVATE -Wall -Wextra -Werror)

add_executable(SharedAudioRingTests ../tests/SharedAudioRingTests.cpp)
target_link_libraries(SharedAudioRingTests PRIVATE TwitchSharedAudio)
target_compile_options(SharedAudioRingTests PRIVATE -Wall -Wextra -Werror)
add_test(NAME SharedAudioRingTests COMMAND SharedAudioRingTests)

add_executable(SharedAudioSyntheticProducer
  ../tests/SharedAudioSyntheticProducer.cpp)
target_link_libraries(SharedAudioSyntheticProducer PRIVATE TwitchSharedAudio)
target_compile_options(SharedAudioSyntheticProducer PRIVATE
  -Wall -Wextra -Werror)

add_executable(XPCSyntheticProducer ../tests/XPCSyntheticProducer.cpp)
target_link_libraries(XPCSyntheticProducer PRIVATE TwitchXPCClient)
target_compile_options(XPCSyntheticProducer PRIVATE
  -Wall -Wextra -Werror -fblocks)

execute_process(
  COMMAND /usr/bin/id -u
  OUTPUT_VARIABLE XPC_TEST_UID
  OUTPUT_STRIP_TRAILING_WHITESPACE
  COMMAND_ERROR_IS_FATAL ANY
)
set(XPC_SERVICE_EXECUTABLE "${CMAKE_BINARY_DIR}/TwitchAudioXPCService")
set(XPC_TEST_STDOUT "${CMAKE_BINARY_DIR}/xpc-service.stdout")
set(XPC_TEST_STDERR "${CMAKE_BINARY_DIR}/xpc-service.stderr")
set(XPC_ALLOWED_UID "${XPC_TEST_UID}")
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/../xpc-service/local-test.plist.in"
  "${CMAKE_BINARY_DIR}/xpc-local-test.plist"
  @ONLY
)
set(XPC_ALLOWED_UID "4294967294")
set(XPC_TEST_STDOUT "${CMAKE_BINARY_DIR}/xpc-rejection.stdout")
set(XPC_TEST_STDERR "${CMAKE_BINARY_DIR}/xpc-rejection.stderr")
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/../xpc-service/local-test.plist.in"
  "${CMAKE_BINARY_DIR}/xpc-local-rejection-test.plist"
  @ONLY
)
