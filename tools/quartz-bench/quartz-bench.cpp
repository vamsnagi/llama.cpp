#include "arg.h"
#include "common.h"
#include "llama.h"
#include "sampling.h"

#include <quartz/Quartz.h>
#include <quartz/FrequencyReadback.h>
#include <quartz/platform/device_setup.h>

#include <algorithm>
#include <chrono>
#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

using namespace quartz;

namespace {

struct options {
    std::string plan;
    std::string nspPowerMode;
    std::string result = "quartz_result.csv";
    std::string samples = "quartz_samples.csv";
    std::string trace = "quartz_trace.csv";
    std::string pivots = "quartz_pivots.csv";
};

static void print_usage(int, char ** argv) {
    std::fprintf(stderr,
        "usage: %s [--nsp-power-mode MODE] [--plan PLAN.csv] [-m MODEL] [-p PROMPT] [-n TOKENS]\n"
        "       [--result PATH] [--samples PATH] [--trace PATH] [--pivots PATH]\n"
        "  --plan installs Quartz's checkpoint-ID frequency plan; when it contains\n"
        "  nsp_power_mode rows, its initial mode and updates own NSP HAP voting.\n",
        argv[0]);
}

static bool take_option(std::vector<char *> & args, const char * name, std::string & value) {
    for (size_t i = 1; i + 1 < args.size(); ++i) {
        if (std::strcmp(args[i], name) == 0) {
            value = args[i + 1];
            args.erase(args.begin() + i, args.begin() + i + 2);
            return true;
        }
    }
    return false;
}

static bool set_external_hexagon_power_mode() {
#if defined(_WIN32)
    return _putenv_s("GGML_HEXAGON_POWER_MODE", "external") == 0;
#else
    return setenv("GGML_HEXAGON_POWER_MODE", "external", 1) == 0;
#endif
}

// HAP_power_get() exposes the observed Q6 core and HMX rates plus DCVS state.
// SDK 6.7 has no matching getters for HVX, Q6 bus, or CENG, so Quartz leaves
// those fields unset instead of presenting the requested vote as a frequency.
static void print_nsp_hap_state(QuartzSession& session, const char* phase) {
    const auto read = session.readNspPowerState();
    if (!read.result.ok()) {
        std::fprintf(stderr,
                     "[quartz-bench] NSP HAP readback phase=%s failed: %s\n",
                     phase, read.result.detail.c_str());
        return;
    }

    const auto to_mhz = [](const std::optional<uint32_t>& hz) {
        return hz ? static_cast<double>(*hz) / 1000000.0 : -1.0;
    };
    const char* dcvs = !read.state.dcvsEnabled ? "unavailable"
                       : (*read.state.dcvsEnabled ? "enabled" : "disabled");
    std::fprintf(stderr,
                 "[quartz-bench] NSP HAP readback phase=%s core=%.3f MHz "
                 "hmx=%.3f MHz dcvs=%s; hvx=unavailable bus=unavailable "
                 "ceng=unavailable\n",
                 phase, to_mhz(read.state.coreHz), to_mhz(read.state.hmxHz), dcvs);
}

// The client is already open, so this measures only method-3 marshalling,
// FastRPC, DSP HAP_power_set(), and the synchronous response. It does not
// measure physical clock-settling time.
static bool apply_nsp_power_mode(QuartzSession& session, NspPowerMode mode,
                                 const char* phase) {
    const auto applyBegin = std::chrono::steady_clock::now();
    const auto result = session.setNspPowerMode(mode);
    const auto applyEnd = std::chrono::steady_clock::now();
    const auto applyUs = std::chrono::duration_cast<std::chrono::microseconds>(
        applyEnd - applyBegin).count();
    if (!result.ok()) {
        std::fprintf(stderr,
                     "failed to apply NSP mode %s for %s HAP_rc=%d after %lld us: %s\n",
                     toString(mode), phase, result.backendStatus.value_or(-1),
                     static_cast<long long>(applyUs), result.detail.c_str());
        return false;
    }
    std::fprintf(stderr,
                 "[quartz-bench] NSP phase=%s mode=%s HAP_rc=%d RPC=%lld us "
                 "\n",
                 phase, toString(mode), result.backendStatus.value_or(-1),
                 static_cast<long long>(applyUs));
    // print_nsp_hap_state(session, phase);
    return true;
}

static std::vector<llama_token> make_prompt_tokens(
        llama_model * model, llama_context * ctx, const std::string & prompt) {
    const llama_vocab * vocab = llama_model_get_vocab(model);
    const bool add_bos = llama_vocab_get_add_bos(vocab);

    size_t parsed = 0;
    int count = 0;
    try {
        count = std::stoi(prompt, &parsed);
    } catch (...) {
        parsed = 0;
    }

    if (parsed == prompt.size() && count > 0) {
        const int32_t n_vocab = llama_vocab_n_tokens(vocab);
        std::vector<llama_token> tokens(count);
        for (int i = 0; i < count; ++i) {
            tokens[i] = (i == 0 && add_bos)
                ? llama_vocab_bos(vocab)
                : std::rand() % n_vocab;
        }
        return tokens;
    }

    return common_tokenize(ctx, prompt, add_bos, true);
}

} // namespace

int main(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");
    log::setLevel(log::Level::Info);

    std::vector<char *> llama_args(argv, argv + argc);
    options opt;
    take_option(llama_args, "--plan", opt.plan);
    const bool nspPowerModeRequested =
        take_option(llama_args, "--nsp-power-mode", opt.nspPowerMode) ||
        take_option(llama_args, "--nsp-powermode", opt.nspPowerMode); // compatibility alias
    take_option(llama_args, "--result", opt.result);
    take_option(llama_args, "--samples", opt.samples);
    take_option(llama_args, "--trace", opt.trace);
    take_option(llama_args, "--pivots", opt.pivots);

    // Only Quartz-owned NSP policy needs to prevent llama from making its
    // own HAP vote.  In the no-NSP-options case, leave both HAP and llama's
    // environment entirely untouched.
    const bool quartzNspControlRequested = nspPowerModeRequested || !opt.plan.empty();

    if (quartzNspControlRequested) {
        if (set_external_hexagon_power_mode()) {
            std::fprintf(stderr,
                        "[quartz-bench] set GGML_HEXAGON_POWER_MODE=external "
                        "(Quartz owns NSP HAP voting)\n");
        } else {
            std::fprintf(stderr,
                        "[quartz-bench] failed to set "
                        "GGML_HEXAGON_POWER_MODE=external\n");
            return 1;
        }
    } else {
        std::fprintf(stderr,
                    "[quartz-bench] GGML_HEXAGON_POWER_MODE left unchanged "
                    "(Quartz NSP HAP control disabled)\n");
    }

    common_params params;
    common_init();
    if (!common_params_parse(static_cast<int>(llama_args.size()), llama_args.data(),
                             params, LLAMA_EXAMPLE_CLI, print_usage)) {
        return 1;
    }
    if (params.prompt.empty()) {
        params.prompt = "2500";
    }
    params.warmup = false;

    const auto nspPowerMode = nspPowerModeRequested
        ? nspPowerModeFromString(opt.nspPowerMode)
        : std::optional<NspPowerMode>{};
    if (nspPowerModeRequested && !nspPowerMode) {
        std::fprintf(stderr,
                     "invalid --nsp-power-mode '%s'; expected one of: "
                     "low_power_saver, power_saver, high_power_saver, low_balanced, "
                     "balanced, high_performance, sustained_high_performance, burst\n",
                     opt.nspPowerMode.c_str());
        return 1;
    }

    SessionConfig session_config;
    QuartzSession session(nullptr, session_config);

    if (quartzNspControlRequested) {
        const auto openBegin = std::chrono::steady_clock::now();
        const auto openResult = session.openNspPowerClient();
        const auto openEnd = std::chrono::steady_clock::now();
        const auto openUs = std::chrono::duration_cast<std::chrono::microseconds>(
            openEnd - openBegin).count();
        if (!openResult.ok()) {
            std::fprintf(stderr, "failed to open NSP FastRPC client after %lld us: %s\n",
                         static_cast<long long>(openUs), openResult.detail.c_str());
            return 1;
        }
        std::fprintf(stderr, "[quartz-bench] NSP FastRPC open=%lld us\n",
                     static_cast<long long>(openUs));
        if (opt.plan.empty()) {
            if (!apply_nsp_power_mode(session, *nspPowerMode, "init")) return 1;
        } else {
            try {
                // FrequencyPlan::initial is applied by session.start().  Each
                // update is then matched against both its checkpoint site ID and
                // visit count, making phase changes deterministic across runs.
                session.setFrequencyPlanFromCsv(opt.plan);
            } catch (const std::exception & e) {
                std::fprintf(stderr, "failed to load Quartz frequency plan '%s': %s\n",
                             opt.plan.c_str(), e.what());
                return 1;
            }
            std::fprintf(stderr,
                         "[quartz-bench] NSP policy is controlled by checkpoint plan: %s\n",
                         opt.plan.c_str());
        }
    } else {
        std::fprintf(stderr,
                     "[quartz-bench] NSP HAP control disabled (no --nsp-power-mode or --plan)\n");
    }

    const auto rail_names = session.rails().names();
    if (rail_names.empty()) {
        std::fprintf(stderr,
                     "[quartz-bench] no readable powercap rails were discovered under "
                     "/sys/class/powercap. Run Quartz device setup with root before "
                     "benchmarking, then verify the energy_uj nodes are readable.\n");
        return 1;
    }

    for (const auto & name : rail_names) {
        std::fprintf(stderr, " %s", name.c_str());
    }
    std::fprintf(stderr, "\n");
    
    if (!session.rails().has("soc")) {
        std::fprintf(stderr, "[quartz-bench] required telemetry rail 'soc' was not discovered; available rails:");
        return 1;
    }

    session.selectRails({"soc"});
    std::fprintf(stderr, "[quartz-bench] selected telemetry rail: soc\n");

    // Checkpoint IDs intentionally remain compatible with existing benchmark
    // traces.  They hash __builtin_FUNCTION() and __builtin_LINE(), and the
    // plan-loading branch above added source lines before these checkpoints.
    // Keep their logical line numbers at the prior values so a plan generated
    // from the supplied low_balanced trace still matches at runtime.

    session.start();

    // A plan applies its initial NSP mode during start().  The direct-mode
    // path prints readback in apply_nsp_power_mode() above.
    // if (quartzNspControlRequested && !opt.plan.empty()) {
    //     print_nsp_hap_state(session, "plan-initial");
    // }

    session.checkpoint();

    llama_backend_init();
    llama_numa_init(params.numa);
    auto llama_init = common_init_from_params(params);

    session.checkpoint();
    llama_model * model = llama_init->model();

    session.checkpoint();

    llama_context * ctx = llama_init->context();
    if (model == nullptr || ctx == nullptr) {
        std::fprintf(stderr, "failed to initialize llama\n");
        llama_init.reset();
        llama_backend_free();
        session.stop();
        return 1;
    }
    session.checkpoint();

    std::vector<llama_token> prompt_tokens = make_prompt_tokens(model, ctx, params.prompt);
    if (prompt_tokens.empty()) {
        std::fprintf(stderr, "prompt produced no tokens\n");
        llama_init.reset();
        llama_backend_free();
        session.stop();
        return 1;
    }
    session.checkpoint();
    common_sampler * sampler = common_sampler_init(model, params.sampling);
    if (sampler == nullptr) {
        std::fprintf(stderr, "failed to initialize sampler\n");
        llama_init.reset();
        llama_backend_free();
        session.stop();
        return 1;
    }
    session.checkpoint();
    const int n_batch = static_cast<int>(llama_n_batch(ctx));
    const int n_predict = params.n_predict < 0 ? 32 : params.n_predict;

    // Capture the governor's state after model/context setup but immediately
    // before the first inference decode.  Do this once, rather than per
    // token, so measurement itself does not perturb decode timing.
    // if (quartzNspControlRequested) {
    //     print_nsp_hap_state(session, "before-decode");
    // }

    for (int pos = 0; pos < static_cast<int>(prompt_tokens.size()); ) {
        const int n_tokens = std::min(n_batch, static_cast<int>(prompt_tokens.size()) - pos);
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + pos, n_tokens);
        if (llama_decode(ctx, batch) != 0) {
            std::fprintf(stderr, "prompt decode failed\n");
            common_sampler_free(sampler);
            llama_init.reset();
            llama_backend_free();
            session.stop();
            return 1;
        }
        session.checkpoint();
        pos += n_tokens;
    }

    llama_token next = common_sampler_sample(sampler, ctx, -1);
    for (int i = 0; i < n_predict; ++i) {
        llama_batch batch = llama_batch_get_one(&next, 1);
        if (llama_decode(ctx, batch) != 0) {
            std::fprintf(stderr, "decode failed\n");
            common_sampler_free(sampler);
            llama_init.reset();
            llama_backend_free();
            session.stop();
            return 1;
        }
        next = common_sampler_sample(sampler, ctx, -1);
        session.checkpoint();
    }

    session.stop();
    // Use the same public unified segmentation API exposed to applications.
    // Keep only workload-relevant rails, reject sub-second control phases,
    // and merge adjacent phases with nearly identical rail-power profiles.
    
    // analysis::PhaseOptions phaseOptions;
    // phaseOptions.metric = DistanceMetric::Manhattan;
    // phaseOptions.marginWatts = 0.05;
    // phaseOptions.cutoff = 0.15;
    // phaseOptions.minDurationUs = 200000;
    // const auto phaseResult = session.assignPhases(phaseOptions);
    // std::fprintf(stderr,
    //              "[quartz-bench] phases=%zu null_boundaries_removed=%zu "
    //              "merged_boundaries_removed=%zu iterations=%zu\n",
    //              phaseResult.finalPhaseCount,
    //              phaseResult.nullBoundariesRemoved,
    //              phaseResult.mergedBoundariesRemoved,
    //              phaseResult.iterationsRun);

    const auto & trace = session.checkpointTrace();
    if (trace.size() < 2) {
        std::fprintf(stderr, "Quartz returned too few checkpoints\n");
        common_sampler_free(sampler);
        llama_init.reset();
        llama_backend_free();
        return 1;
    }

    int64_t prev_TS_us = 0;
    int64_t curr_TS_us;
    double energy_j;
    std::vector<std::pair<double, double>> pivot_energy_duration;
    pivot_energy_duration.reserve(trace.size());

    for (size_t i = 0; i < trace.size(); ++i) {
        const auto & cp = trace[i];
        if (cp.pivot) {
            curr_TS_us = cp.timestamp_us;
            energy_j = session.energyBetween(prev_TS_us, curr_TS_us);
            pivot_energy_duration.emplace_back(energy_j, (curr_TS_us - prev_TS_us) / 1000000.0);
            prev_TS_us = curr_TS_us;
        }
    }
    for (size_t i = 0; i < pivot_energy_duration.size(); ++i) {
        std::fprintf(stderr, "[quartz-bench] pivot[%zu] energy_j=%.9f duration_s=%.6f\n",
                     i, pivot_energy_duration[i].first, pivot_energy_duration[i].second);
    }

    const int64_t begin_us_ = trace.front().timestamp_us;
    const int64_t end_us_ = trace.back().timestamp_us;
    const double duration_ms_ = (end_us_ - begin_us_) / 1000.0;
    const double energy_j_ = session.energyBetween(begin_us_, end_us_);
    std::fprintf(stderr, "[quartz-bench] total energy_j=%.9f duration_ms=%.3f\n",
                 energy_j_, duration_ms_);

    session.exportSamplesCsv(opt.samples);
    session.exportCheckpointsCsv(opt.trace, CheckpointExport::All);
    session.exportCheckpointsCsv(opt.pivots, CheckpointExport::Pivots);

    common_sampler_free(sampler);
    llama_init.reset(); 
    llama_backend_free();
    return 0;
}
