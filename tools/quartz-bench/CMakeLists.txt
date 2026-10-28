add_executable(llama-quartz-bench quartz-bench.cpp)

target_link_libraries(llama-quartz-bench
    PRIVATE
        llama-common
        llama
        Threads::Threads
)

target_compile_features(llama-quartz-bench PRIVATE cxx_std_17)
if (BUILD_WITH_QUARTZ)
    target_link_libraries(llama-quartz-bench PRIVATE quartz::quartz)
    target_compile_definitions(llama-quartz-bench PRIVATE BUILD_WITH_QUARTZ=1)
endif()

if (LLAMA_TOOLS_INSTALL)
    install(TARGETS llama-quartz-bench RUNTIME)
    if (BUILD_WITH_QUARTZ)
        if (QUARTZ_SRC_ROOT AND TARGET nsp_freq_skel)
            install(PROGRAMS "${CMAKE_BINARY_DIR}/quartz/libnsp_freq_skel.so"
                TYPE LIB COMPONENT quartz-runtime)
        elseif (QUARTZ_SDK_ROOT)
            get_filename_component(_quartz_sdk_libdir "${quartz_DIR}/../.." ABSOLUTE)
            if (EXISTS "${_quartz_sdk_libdir}/libnsp_freq_skel.so")
                install(PROGRAMS "${_quartz_sdk_libdir}/libnsp_freq_skel.so"
                    TYPE LIB COMPONENT quartz-runtime)
            endif()
        endif()
    endif()
endif()
