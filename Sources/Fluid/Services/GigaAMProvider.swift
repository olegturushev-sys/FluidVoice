import Foundation

final class GigaAMProvider: TranscriptionProvider {
    let name = "GigaAM (Russian ASR)"

    var isAvailable: Bool {
        Self.checkPythonAndDependencies()
    }

    private(set) var isReady: Bool = false
    private var modelOverride: SettingsStore.SpeechModel?

    private let modelCacheDirectory: URL

    init(modelOverride: SettingsStore.SpeechModel? = nil) {
        self.modelOverride = modelOverride

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GigaAMModels")

        if let cacheDir = cacheDir {
            self.modelCacheDirectory = cacheDir
        } else {
            self.modelCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("GigaAMModels")
        }
    }

    private var selectedModel: SettingsStore.SpeechModel {
        self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
    }

    private var modelVersion: String {
        switch self.selectedModel {
        case .gigaamV3Ctc, .gigaamV3Rnnt:
            return "v3"
        case .gigaamV2Ctc, .gigaamV2Rnnt:
            return "v2"
        default:
            return "v3"
        }
    }

    private var modelType: String {
        switch self.selectedModel {
        case .gigaamV3Ctc, .gigaamV2Ctc:
            return "ctc"
        case .gigaamV3Rnnt, .gigaamV2Rnnt:
            return "rnnt"
        default:
            return "ctc"
        }
    }

    private var huggingfaceModelId: String {
        switch self.modelVersion {
        case "v3":
            return "ai-sage/GigaAM-v3"
        case "v2":
            return "ai-sage/GigaAM-v2"
        default:
            return "ai-sage/GigaAM-v3"
        }
    }

    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        guard self.isReady == false else { return }

        DebugLogger.shared.info("GigaAMProvider: Starting model preparation", source: "GigaAMProvider")

        guard Self.checkPythonAndDependencies() else {
            throw NSError(
                domain: "GigaAMProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Python or required packages not found. Please install: pip install gigaam torch transformers"]
            )
        }

        try FileManager.default.createDirectory(at: self.modelCacheDirectory, withIntermediateDirectories: true)

        self.isReady = true
        DebugLogger.shared.info("GigaAMProvider: Model ready", source: "GigaAMProvider")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isReady else {
            throw NSError(
                domain: "GigaAMProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "GigaAM model not prepared"]
            )
        }

        let minSamples = 16_000
        guard samples.count >= minSamples else {
            throw NSError(
                domain: "GigaAMProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio too short for GigaAM transcription"]
            )
        }

        let tempAudioURL = self.modelCacheDirectory.appendingPathComponent("temp_audio_\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: tempAudioURL)
        }

        try self.writeWAVFile(samples: samples, to: tempAudioURL)

        let transcription = try await self.runTranscription(audioURL: tempAudioURL)

        return ASRTranscriptionResult(text: transcription, confidence: 0.95)
    }

    func modelsExistOnDisk() -> Bool {
        return FileManager.default.fileExists(atPath: self.modelCacheDirectory.path)
    }

    func clearCache() async throws {
        if FileManager.default.fileExists(atPath: self.modelCacheDirectory.path) {
            try FileManager.default.removeItem(at: self.modelCacheDirectory)
        }
        self.isReady = false
    }

    // MARK: - Private Methods

    private func writeWAVFile(samples: [Float], to url: URL) throws {
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = samples.count * 2

        var wavData = Data()

        wavData.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(36 + dataSize)
        wavData.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        wavData.append(contentsOf: "fmt ".utf8)
        var fmtSize: UInt32 = 16
        wavData.append(contentsOf: withUnsafeBytes(of: fmtSize.littleEndian) { Array($0) })
        var audioFormat: UInt16 = 1
        wavData.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        wavData.append(contentsOf: "data".utf8)
        var dataSizeVal = UInt32(dataSize)
        wavData.append(contentsOf: withUnsafeBytes(of: dataSizeVal.littleEndian) { Array($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clamped * 32767.0)
            wavData.append(contentsOf: withUnsafeBytes(of: int16Sample.littleEndian) { Array($0) })
        }

        try wavData.write(to: url)
    }

    private func runTranscription(audioURL: URL) async throws -> String {
        let pythonScript = Self.transcriptionScript(
            modelId: self.huggingfaceModelId,
            modelType: self.modelType
        )

        let tempScriptURL = self.modelCacheDirectory.appendingPathComponent("transcribe_\(UUID().uuidString).py")
        defer {
            try? FileManager.default.removeItem(at: tempScriptURL)
        }

        try pythonScript.write(to: tempScriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [tempScriptURL.path, audioURL.path]
        process.currentDirectoryURL = self.modelCacheDirectory

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            DebugLogger.shared.error("GigaAMProvider: Transcription failed: \(errorString)", source: "GigaAMProvider")
            throw NSError(
                domain: "GigaAMProvider",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Transcription failed: \(errorString)"]
            )
        }

        let transcription = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return transcription
    }

    // MARK: - Static Helpers

    private static func checkPythonAndDependencies() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import gigaam; print('ok')"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func transcriptionScript(modelId: String, modelType: String) -> String {
        return """
        #!/usr/bin/env python3
        import sys
        import os

        os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'
        os.environ['TRANSFORMERS_VERBOSITY'] = 'error'

        try:
            import torch
            from transformers import AutoModel, AutoProcessor

            audio_path = sys.argv[1] if len(sys.argv) > 1 else None

            if not audio_path or not os.path.exists(audio_path):
                print("Error: Audio file not found", file=sys.stderr)
                sys.exit(1)

            model = AutoModel.from_pretrained(
                "\(modelId)",
                revision="\(modelType)",
                trust_remote_code=True
            )

            processor = AutoProcessor.from_pretrained(
                "\(modelId)",
                revision="\(modelType)",
                trust_remote_code=True
            )

            import torchaudio
            waveform, sample_rate = torchaudio.load(audio_path)

            if sample_rate != 16000:
                resampler = torchaudio.transforms.Resample(orig_freq=sample_rate, new_freq=16000)
                waveform = resampler(waveform)

            if waveform.shape[0] > 1:
                waveform = waveform.mean(dim=0, keepdim=True)

            input_features = processor(
                waveform.squeeze().numpy(),
                sampling_rate=16000,
                return_tensors="pt"
            ).input_features

            with torch.no_grad():
                logits = model(**input_features).logits

            predicted_ids = logits.argmax(dim=-1)
            transcription = processor.batch_decode(predicted_ids)[0]

            print(transcription)

        except Exception as e:
            print(f"Error: {str(e)}", file=sys.stderr)
            sys.exit(1)
        """
    }
}
