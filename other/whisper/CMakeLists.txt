cmake_minimum_required(VERSION 3.19)
project(iina_whisper C CXX)

if (NOT WHISPER_SRC)
  message(FATAL_ERROR "WHISPER_SRC must point at a whisper.cpp checkout")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_SDL2 OFF CACHE BOOL "" FORCE)
set(WHISPER_FFMPEG OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_METAL_USE_BF16 OFF CACHE BOOL "" FORCE)

if (IINA_GGML_METAL)
  set(GGML_METAL ON CACHE BOOL "" FORCE)
  set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
else()
  set(GGML_METAL OFF CACHE BOOL "" FORCE)
endif()

if (IINA_WHISPER_COREML)
  set(WHISPER_COREML ON CACHE BOOL "" FORCE)
  set(WHISPER_COREML_ALLOW_FALLBACK ON CACHE BOOL "" FORCE)
else()
  set(WHISPER_COREML OFF CACHE BOOL "" FORCE)
endif()

set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_subdirectory("${WHISPER_SRC}" "${CMAKE_BINARY_DIR}/whisper-src")

add_library(iina_whisper SHARED iina_whisper.c)
target_link_libraries(iina_whisper PRIVATE whisper)

foreach(extra ggml ggml-base ggml-cpu ggml-metal ggml-blas whisper.coreml)
  if (TARGET ${extra})
    target_link_libraries(iina_whisper PRIVATE ${extra})
  endif()
endforeach()

find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
target_link_libraries(iina_whisper PRIVATE ${ACCELERATE_FRAMEWORK} ${FOUNDATION_FRAMEWORK})

if (IINA_GGML_METAL)
  find_library(METAL_FRAMEWORK Metal REQUIRED)
  target_link_libraries(iina_whisper PRIVATE ${METAL_FRAMEWORK})
  find_library(MPS_FRAMEWORK MetalPerformanceShaders)
  if (MPS_FRAMEWORK)
    target_link_libraries(iina_whisper PRIVATE ${MPS_FRAMEWORK})
  endif()
endif()

if (IINA_WHISPER_COREML)
  find_library(COREML_FRAMEWORK CoreML REQUIRED)
  target_link_libraries(iina_whisper PRIVATE ${COREML_FRAMEWORK})
endif()

target_include_directories(iina_whisper PRIVATE
  "${WHISPER_SRC}/include"
  "${WHISPER_SRC}/ggml/include"
)

if (IINA_GGML_METAL)
  target_compile_definitions(iina_whisper PRIVATE IINA_WHISPER_METAL=1)
else()
  target_compile_definitions(iina_whisper PRIVATE IINA_WHISPER_METAL=0)
endif()

if (IINA_WHISPER_COREML)
  target_compile_definitions(iina_whisper PRIVATE IINA_WHISPER_COREML=1)
else()
  target_compile_definitions(iina_whisper PRIVATE IINA_WHISPER_COREML=0)
endif()

set_target_properties(iina_whisper PROPERTIES
  LINKER_LANGUAGE CXX
  OUTPUT_NAME "iina_whisper"
  C_VISIBILITY_PRESET default
  MACOSX_RPATH ON
  BUILD_RPATH "@loader_path"
  INSTALL_RPATH "@loader_path"
  INSTALL_NAME_DIR "@rpath"
)

target_compile_options(iina_whisper PRIVATE -fvisibility=default)
