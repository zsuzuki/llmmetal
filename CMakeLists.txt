cmake_minimum_required(VERSION 3.28)

project(llmmetal VERSION 0.1.0 LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(CMAKE_GENERATOR STREQUAL "")
  message(STATUS "Configure with -G Ninja to use Ninja")
endif()

if(NOT CMAKE_CXX_COMPILER MATCHES "^/opt/homebrew/opt/llvm/")
  message(WARNING
    "Homebrew LLVM is recommended. Configure with:\n"
    "  cmake --preset default\n"
    "or pass:\n"
    "  -DCMAKE_C_COMPILER=/opt/homebrew/opt/llvm/bin/clang\n"
    "  -DCMAKE_CXX_COMPILER=/opt/homebrew/opt/llvm/bin/clang++")
endif()

add_library(llmmetal STATIC
  src/llmmetal.mm
)

target_include_directories(llmmetal
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(llmmetal
  PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wextra -Wpedantic>
    $<$<COMPILE_LANGUAGE:OBJCXX>:-Wall -Wextra -Wpedantic -fobjc-arc>
)

target_link_libraries(llmmetal
  PUBLIC
    "-framework AppKit"
    "-framework QuartzCore"
    "-framework Metal"
    "-framework MetalKit"
    "-framework CoreText"
    "-framework CoreGraphics"
    "-framework ImageIO"
    "-framework GameController"
)

function(llmmetal_add_sample name)
  add_executable(${name} samples/${name}.cpp)
  target_link_libraries(${name} PRIVATE llmmetal)
  target_compile_options(${name} PRIVATE -Wall -Wextra -Wpedantic)
endfunction()

llmmetal_add_sample(sample_lines)
llmmetal_add_sample(sample_texture)
llmmetal_add_sample(sample_input_text)

file(COPY ${CMAKE_CURRENT_SOURCE_DIR}/resources DESTINATION ${CMAKE_CURRENT_BINARY_DIR})
