cmake_minimum_required(VERSION 3.13)
project(SimpleNES CXX C)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE "Release" CACHE STRING
      "Choose the type of build, options are: Debug Release."
      FORCE)
endif(NOT CMAKE_BUILD_TYPE)

set(BUILD_STATIC FALSE CACHE STRING "Set this to link external libraries statically")

if(CMAKE_COMPILER_IS_GNUCXX OR "${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang" OR "${CMAKE_CXX_COMPILER_ID}" STREQUAL "AppleClang")
        set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -Wall -Wextra -g")
        set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O2")
        #set (CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -fno-omit-frame-pointer -fsanitize=address")
        #set (CMAKE_LINKER_FLAGS_DEBUG "${CMAKE_LINKER_FLAGS_DEBUG} -fno-omit-frame-pointer -fsanitize=address")
endif()

# Add directory containing FindSFML.cmake to module path
set(CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake/Modules/;${CMAKE_MODULE_PATH};${CMAKE_SOURCE_DIR}")

# Detect iOS toolchain — leetal/ios-cmake sets CMAKE_SYSTEM_NAME to iOS. When building for iOS we
# skip the desktop app entirely (no SFML, no miniaudio) and only produce libSimpleNESCore.a.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(SN_IS_IOS TRUE)
else()
    set(SN_IS_IOS FALSE)
endif()

option(SN_BUILD_DESKTOP "Build the SFML desktop application" ON)
if(SN_IS_IOS)
    set(SN_BUILD_DESKTOP OFF CACHE BOOL "Build the SFML desktop application" FORCE)
endif()

# generate compile commands for clangd
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ---------------------------------------------------------------------------
# Core library — headless, no SFML or miniaudio. Everything a non-desktop host
# (iOS, tests, alternate frontends) needs is here.
# ---------------------------------------------------------------------------
set(CORE_SOURCES
    src/CPU.cpp
    src/PPU.cpp
    src/PictureBus.cpp
    src/MainBus.cpp
    src/Cartridge.cpp
    src/Controller.cpp
    src/VirtualScreen.cpp
    src/Mapper.cpp
    src/MapperNROM.cpp
    src/MapperSxROM.cpp
    src/MapperUxROM.cpp
    src/MapperCNROM.cpp
    src/MapperMMC3.cpp
    src/MapperAxROM.cpp
    src/MapperColorDreams.cpp
    src/MapperGxROM.cpp
    src/Log.cpp
    src/LastError.cpp
    src/CoreEmulator.cpp
    src/simplenes_core.cpp
    src/APU/APU.cpp
    src/APU/DMC.cpp
    src/APU/FrameCounter.cpp
    src/APU/Noise.cpp
    src/APU/Pulse.cpp
    src/APU/Triangle.cpp
    src/APU/Units.cpp
)

add_library(SimpleNESCore STATIC ${CORE_SOURCES})
target_include_directories(SimpleNESCore PUBLIC
    "${PROJECT_SOURCE_DIR}/include"
)
target_compile_features(SimpleNESCore PUBLIC cxx_std_11)
set_property(TARGET SimpleNESCore PROPERTY CXX_STANDARD 11)
set_property(TARGET SimpleNESCore PROPERTY CXX_STANDARD_REQUIRED ON)

# Injects __FILENAME__ into each source file for the Log macros — kept identical to the pre-refactor
# behavior so log output looks the same.
function(define_file_basename_for_sources targetname)
    get_target_property(source_files "${targetname}" SOURCES)
    foreach(sourcefile ${source_files})
        get_property(defs SOURCE "${sourcefile}"
            PROPERTY COMPILE_DEFINITIONS)
        get_filename_component(basename "${sourcefile}" NAME)
        list(APPEND defs "__FILENAME__=\"${basename}\"")
        set_property(
            SOURCE "${sourcefile}"
            PROPERTY COMPILE_DEFINITIONS ${defs})
    endforeach()
endfunction()

define_file_basename_for_sources(SimpleNESCore)

# ---------------------------------------------------------------------------
# Desktop SFML executable — the only piece that actually depends on SFML and
# miniaudio. Skipped entirely on iOS builds.
# ---------------------------------------------------------------------------
if(SN_BUILD_DESKTOP)
    # Copy keybindings.conf next to the binary at configure time.
    file(COPY keybindings.conf DESTINATION .)

    # Set static if BUILD_STATIC is set
    if (BUILD_STATIC)
        set(SFML_STATIC_LIBRARIES TRUE)
        if(CMAKE_COMPILER_IS_GNUCXX)
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -static-libstdc++ -static-libgcc")
        endif()
    endif()

    if (SFML_OS_WINDOWS AND SFML_COMPILER_MSVC)
        find_package(SFML 2 COMPONENTS main audio graphics window system REQUIRED)
    else()
        find_package(SFML 2 COMPONENTS audio graphics window system REQUIRED)
    endif()

    if(SFML_FOUND)
        include_directories(${SFML_INCLUDE_DIR})
    else()
        set(SFML_ROOT "" CACHE PATH "SFML top-level directory")
        message("\nSFML directory not found. Set SFML_ROOT to SFML's top-level path (containing \"include\" and \"lib\" directories).")
        message("Make sure the SFML libraries with the same configuration (Release/Debug, Static/Dynamic) exist.\n")
    endif()

    set(DESKTOP_SOURCES
        main.cpp
        src/Emulator.cpp
        src/AudioPlayer.cpp
        src/KeybindingsParser.cpp
    )

    set(VENDOR_SOURCES
        vendor/miniaudio/miniaudio.c
    )

    add_executable(SimpleNES ${DESKTOP_SOURCES} ${VENDOR_SOURCES})
    target_include_directories(SimpleNES PRIVATE
        "${PROJECT_SOURCE_DIR}/vendor/miniaudio/"
    )
    target_link_libraries(SimpleNES PRIVATE SimpleNESCore ${SFML_LIBRARIES} ${SFML_DEPENDENCIES})

    set_property(TARGET SimpleNES PROPERTY CXX_STANDARD 11)
    set_property(TARGET SimpleNES PROPERTY CXX_STANDARD_REQUIRED ON)

    define_file_basename_for_sources(SimpleNES)

    install(TARGETS SimpleNES RUNTIME DESTINATION bin)
endif()

install(TARGETS SimpleNESCore ARCHIVE DESTINATION lib)
install(FILES include/simplenes_core.h DESTINATION include)
