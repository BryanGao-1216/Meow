// kokosuki-cli — test harness: load the bundled MiniCPM5 MLX model and generate.
// Usage: kokosuki-cli <model-dir> [prompt]
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: kokosuki-cli <model-dir> [prompt]")
    exit(1)
}
let modelDir = URL(fileURLWithPath: args[1])
let userPrompt = args.count >= 3 ? args[2] : "你好呀!请用一句话介绍你自己。"

// ChatML prompt built manually (chat_template.jinja is ChatML-style; empty <think> block disables thinking)
func buildPrompt(system: String, user: String) -> String {
    return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
}

let clock = ContinuousClock()
let t0 = clock.now

Task {
    do {
        // transformers v5 writes tokenizer_class "TokenizersBackend"; swift-transformers doesn't know it
        replacementTokenizers["TokenizersBackend"] = "PreTrainedTokenizer"
        let config = ModelConfiguration(
            directory: modelDir, overrideTokenizer: "PreTrainedTokenizer",
            extraEOSTokens: ["<|im_end|>"])
        let container = try await LLMModelFactory.shared.loadContainer(configuration: config)
        let loadTime = clock.now - t0
        FileHandle.standardError.write("[load: \(loadTime)]\n".data(using: .utf8)!)

        let system = args.count >= 4 ? args[3] : "你是高小喵,一只可爱的桌面宠物小猫。用简短活泼的话回复。"
        let prompt = buildPrompt(system: system, user: userPrompt)

        try await container.perform { (context: ModelContext) in
            let tokens = context.tokenizer.encode(text: prompt)
            FileHandle.standardError.write("[prompt tokens: \(tokens.count)] first=\(tokens.prefix(8))\n".data(using: .utf8)!)

            let input = LMInput(tokens: MLXArray(tokens))
            let params = GenerateParameters(maxTokens: 200, temperature: 0.8, topP: 0.95)
            let genStart = clock.now
            var nTokens = 0

            let stream = try MLXLMCommon.generate(
                input: input, parameters: params, context: context)
            for await item in stream {
                switch item {
                case .chunk(let text):
                    nTokens += 1
                    print(text, terminator: "")
                    fflush(stdout)
                case .info(let info):
                    let dt = clock.now - genStart
                    FileHandle.standardError.write("\n[gen: \(nTokens) chunks, \(info.tokensPerSecond) tok/s, \(dt)]\n".data(using: .utf8)!)
                default:
                    break
                }
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
        exit(2)
    }
}

RunLoop.main.run()
