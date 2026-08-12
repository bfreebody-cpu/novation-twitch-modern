cmake_minimum_required(VERSION 3.24)

project(NovationTwitchModernAudioExperimental VERSION 0.1.0 LANGUAGES CXX)

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

add_library(${DRIVER_NAME} MODULE Driver.cpp)
target_link_libraries(${DRIVER_NAME} PRIVATE libASPL)
target_compile_options(${DRIVER_NAME} PRIVATE
  -Wall
  -Wextra
  # Warnings originate in the pinned libASPL public headers under Xcode 26.
  -Wno-reorder-init-list
  -Wno-unused-parameter
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
