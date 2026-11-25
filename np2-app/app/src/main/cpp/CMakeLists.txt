cmake_minimum_required(VERSION 3.22.1)
project(np2front CXX)

# libretro.h は Actions が NP2kai のソースからコピーして置く
add_library(np2front SHARED np2front.cpp)
target_include_directories(np2front PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(np2front PRIVATE -O2 -Wall)
target_link_libraries(np2front android log aaudio)
