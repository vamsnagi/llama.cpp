add_executable(llama-quartz-bench quartz-bench.cpp)

target_link_libraries(llama-quartz-bench
    PRIVATE
        quartz
        llama-common
        llama
        Threads::Threads
)

target_compile_features(llama-quartz-bench PRIVATE cxx_std_17)

if (LLAMA_TOOLS_INSTALL)
    install(TARGETS llama-quartz-bench RUNTIME)
endif()
