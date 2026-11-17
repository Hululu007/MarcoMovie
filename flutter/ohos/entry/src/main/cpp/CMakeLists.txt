cmake_minimum_required(VERSION 3.10)

project(marco_movie_ohos_native LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

get_filename_component(
  QJS_CXX_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../packages/quickjs_engine/native/cxx"
  ABSOLUTE
)

set(QJS_SOURCES
  "${QJS_CXX_DIR}/quickjs/quickjs.c"
  "${QJS_CXX_DIR}/quickjs/libregexp.c"
  "${QJS_CXX_DIR}/quickjs/libunicode.c"
  "${QJS_CXX_DIR}/quickjs/dtoa.c"
)

set(BRIDGE_SOURCES
  "${QJS_CXX_DIR}/libfastdev_quickjs_runtime.cpp"
)

add_library(quickjs_c_bridge_plugin SHARED
  ${BRIDGE_SOURCES}
  ${QJS_SOURCES}
)

target_include_directories(quickjs_c_bridge_plugin PRIVATE
  "${QJS_CXX_DIR}"
  "${QJS_CXX_DIR}/quickjs"
)

target_compile_definitions(quickjs_c_bridge_plugin PRIVATE
  _GNU_SOURCE
  CONFIG_VERSION="ng-0.14.0"
)

target_compile_options(quickjs_c_bridge_plugin PRIVATE
  -fvisibility=default
)

set_target_properties(quickjs_c_bridge_plugin PROPERTIES
  OUTPUT_NAME quickjs_c_bridge_plugin
)

target_link_libraries(quickjs_c_bridge_plugin PRIVATE
  pthread
  m
  dl
)

if(COMMAND target_link_options)
  target_link_options(quickjs_c_bridge_plugin PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384"
  )
endif()
