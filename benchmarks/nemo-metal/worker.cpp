// Local benchmark adapter for NVIDIA's pinned native C ABI. Not shipped in the app.
#include <nemo_speech/asr.h>
#include <nlohmann/json.hpp>
#include "wav_reader.h"
#include <chrono>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

using Clock = std::chrono::steady_clock;
using Json = nlohmann::json;
static double seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
static void check(nemo_speech_asr_status status) {
    if (status != NEMO_SPEECH_ASR_OK) throw std::runtime_error(nemo_speech_asr_last_error());
}

int main(int argc, char** argv) {
    try {
        if (argc < 3 || std::string(argv[2]) != "nemometal")
            throw std::runtime_error("expected model directory and nemometal backend");
        if (argc > 3 && std::string(argv[3]) != "0")
            throw std::runtime_error("the native C ABI uses its default CPU thread policy; use --threads 0");
        const std::string model_path = std::string(argv[1]) + "/parakeet-tdt-0.6b-v3.q8_0.gguf";
        nemo_speech_asr_backend_config backend{};
        backend.size = sizeof(backend);
        backend.gpu = 0; // The pinned runtime errors if no GPU can be initialized.
        nemo_speech_asr_model_config model{};
        model.size = sizeof(model);
        model.path = model_path.c_str();
        nemo_speech_asr_recognizer_config config{};
        config.size = sizeof(config);
        config.backend = &backend;
        config.model = &model;
        nemo_speech_asr_recognizer* raw = nullptr;
        auto started = Clock::now();
        check(nemo_speech_asr_create(&config, &raw));
        std::unique_ptr<nemo_speech_asr_recognizer, decltype(&nemo_speech_asr_destroy)>
            recognizer(raw, &nemo_speech_asr_destroy);
        std::cout << Json({{"load_secs", seconds(started)}, {"backend", "nemometal"},
                          {"thread_policy", "native default: min(8, hardware threads)"}}).dump() << std::endl;
        std::string path;
        while (std::getline(std::cin, path)) {
            std::vector<float> samples;
            std::string error;
            if (!examples::read_wav_mono_16k(path, samples, error)) throw std::runtime_error(error);
            auto options = nemo_speech_asr_recognition_options_default();
            options.enable_word_time_offsets = true;
            options.enable_automatic_punctuation = true;
            nemo_speech_asr_result* result_raw = nullptr;
            started = Clock::now();
            check(nemo_speech_asr_recognize_f32(recognizer.get(), &options, samples.data(), samples.size(), 16000, &result_raw));
            std::unique_ptr<nemo_speech_asr_result, decltype(&nemo_speech_asr_result_destroy)>
                result(result_raw, &nemo_speech_asr_result_destroy);
            Json segments = Json::array();
            const size_t count = nemo_speech_asr_result_word_count(result.get(), 0);
            for (size_t i = 0; i < count; ++i) {
                segments.push_back({{"text", nemo_speech_asr_result_word_text(result.get(), 0, i)},
                    {"start_secs", nemo_speech_asr_result_word_start_time(result.get(), 0, i) / 1000.0},
                    {"end_secs", nemo_speech_asr_result_word_end_time(result.get(), 0, i) / 1000.0}});
            }
            Json row = {{"path", path}, {"backend", "nemometal"},
                        {"text", nemo_speech_asr_result_transcript(result.get(), 0)},
                        {"audio_secs", samples.size() / 16000.0}, {"segments", segments}};
            row["inference_secs"] = seconds(started);
            std::cout << row.dump() << std::endl;
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        return 1;
    }
}
