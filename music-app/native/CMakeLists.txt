cmake_minimum_required(VERSION 3.10)
project(pmdwav C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# 古いコードなので警告は全部黙らせる
set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} -O2 -w -fvisibility=hidden")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -w -fvisibility=hidden -Wno-c++11-narrowing -Wno-error")

set(PM ${CMAKE_CURRENT_SOURCE_DIR}/pmdmini)

add_library(pmdwav SHARED
    pmd_wav.c
    mdrv2.cpp
    ${PM}/pmdmini.c
    ${PM}/fmgen/file.cpp
    ${PM}/fmgen/fmtimer.cpp
    ${PM}/fmgen/opna.cpp
    ${PM}/fmgen/fmgen.cpp
    ${PM}/fmgen/opm.cpp
    ${PM}/fmgen/psg.cpp
    ${PM}/pmdwin/opnaw.cpp
    ${PM}/pmdwin/p86drv.cpp
    ${PM}/pmdwin/pmdwin.cpp
    ${PM}/pmdwin/ppsdrv.cpp
    ${PM}/pmdwin/ppz8l.cpp
    ${PM}/pmdwin/table.cpp
    ${PM}/pmdwin/util.cpp
)

target_include_directories(pmdwav PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${PM}
    ${PM}/fmgen
    ${PM}/pmdwin
)

# Android 15 以降の16KBページ端末でも読み込めるようにする
target_link_options(pmdwav PRIVATE -Wl,-z,max-page-size=16384)
