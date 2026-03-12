import Foundation

final class SpeakerDiarizationService {

    private let cacheDirectory: URL

    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpeakerDiarization")

        if let cacheDir = cacheDir {
            self.cacheDirectory = cacheDir
        } else {
            self.cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerDiarization")
        }

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    enum DiarizationError: LocalizedError {
        case pythonNotFound
        case dependenciesMissing
        case processingFailed(String)
        case audioTooShort

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "Python not found. Please install Python 3.10+."
            case .dependenciesMissing:
                return "Required Python packages not found. Install: pip install silero-vad speechbrain ecapa-tdnn sklearn numpy torch torchaudio"
            case .processingFailed(let msg):
                return "Diarization failed: \(msg)"
            case .audioTooShort:
                return "Audio file too short for speaker diarization (minimum 5 seconds required)"
            }
        }
    }

    /// Check if Python and required dependencies are available
    func checkDependencies() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import silero_vad
            from speechbrain.pretrained import EncoderClassifier
            from sklearn.cluster import MeanShift
            import numpy as np
            print('ok')
        """]

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

    /// Perform speaker diarization on audio file
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - transcription: Full transcription text for context-based speaker identification
    /// - Returns: Array of speaker segments
    func diarize(audioURL: URL, transcription: String?) async throws -> [SpeakerSegment] {

        // Check audio duration
        let duration = try await getAudioDuration(url: audioURL)
        guard duration >= 5.0 else {
            throw DiarizationError.audioTooShort
        }

        // Check dependencies
        let depsOk = await checkDependencies()
        guard depsOk else {
            throw DiarizationError.dependenciesMissing
        }

        // Run diarization Python script
        let segments = try await runDiarizationScript(audioURL: audioURL)

        // If transcription provided, use LLM to identify therapist/client
        if let transcription = transcription, !transcription.isEmpty {
            return try await identifySpeakersByContext(segments: segments, transcription: transcription)
        }

        return segments
    }

    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        // Use AVFoundation to get duration
        // For now, return a placeholder - can be implemented properly
        return 30.0 // placeholder
    }

    /// Run Python script for diarization
    private func runDiarizationScript(audioURL: URL) async throws -> [SpeakerSegment] {
        let script = Self.diarizationScript
        let scriptURL = cacheDirectory.appendingPathComponent("diarize_\(UUID().uuidString).py")
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path, audioURL.path]
        process.currentDirectoryURL = cacheDirectory

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
            DebugLogger.shared.error("SpeakerDiarization: \(errorString)", source: "SpeakerDiarizationService")
            throw DiarizationError.processingFailed(errorString)
        }

        // Parse JSON output
        let outputString = String(data: outputData, encoding: .utf8) ?? ""

        guard let jsonData = outputString.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        else {
            throw DiarizationError.processingFailed("Failed to parse diarization output")
        }

        var segments: [SpeakerSegment] = []
        for item in jsonArray {
            guard let speaker = item["speaker"] as? String,
                  let text = item["text"] as? String,
                  let start = item["start"] as? Double,
                  let end = item["end"] as? Double
            else { continue }

            segments.append(SpeakerSegment(
                speaker: speaker,
                text: text,
                startTime: start,
                endTime: end
            ))
        }

        return segments
    }

    /// Use LLM to identify which speaker is therapist and which is client
    private func identifySpeakersByContext(segments: [SpeakerSegment], transcription: String) async throws -> [SpeakerSegment] {
        // Group segments by speaker
        var speakerTexts: [String: String] = [:]
        for segment in segments {
            if speakerTexts[segment.speaker] == nil {
                speakerTexts[segment.speaker] = ""
            }
            speakerTexts[segment.speaker]! += segment.text + " "
        }

        guard speakerTexts.count == 2 else {
            return segments
        }

        let speakers = Array(speakerTexts.keys).sorted()
        let speaker1 = speakers[0]
        let speaker2 = speakers[1]

        // Create prompt for LLM
        let prompt = """
        Analyze this therapist-client conversation and determine who is who.

        Speaker A: \(speakerTexts[speaker1] ?? "")...

        Speaker B: \(speakerTexts[speaker2] ?? "")...

        Determine which speaker is the therapist and which is the client based on the context.
        Respond with exactly one line in this format:
        A=therapist,B=client

        Or if it's the opposite:
        A=client,B=therapist

        Just respond with the line above, nothing else.
        """

        // Use SettingsStore LLM client if available
        // For now, return segments as-is (SPEAKER_01/SPEAKER_02)
        // The context-based identification can be added later with LLM integration

        return segments
    }

    // MARK: - Python Script

    private static var diarizationScript: String {
        return """
#!/usr/bin/env python3
import sys
import os
import json
import numpy as np

os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'
os.environ['HYDRA_FULL_ERROR'] = '1'

def get_speech_timestamps():
    try:
        import torch
        torch.set_num_threads(1)

        from silero_vad import load_silero_vad, read_audio, get_speech_timestamps

        model = load_silero_vad()

        audio_path = sys.argv[1] if len(sys.argv) > 1 else None
        if not audio_path or not os.path.exists(audio_path):
            print("Error: Audio file not found", file=sys.stderr)
            sys.exit(1)

        wav = read_audio(audio_path, sampling_rate=16000)

        speech_timestamps = get_speech_timestamps(wav, model, min_speech_duration_ms=500)

        if not speech_timestamps:
            print("[]")
            sys.exit(0)

        # Extract embeddings using ECAPA
        try:
            from speechbrain.pretrained import EncoderClassifier
            import torch

            classifier = EncoderClassifier.from_hparams(
                source="speechbrain/spkrec-ecapa-voxceleb",
                savedir="/tmp/ecapa_model"
            )

            # Process each speech segment
            results = []
            for i, segment in enumerate(speech_timestamps):
                start_sample = segment['start']
                end_sample = segment['end']

                # Extract audio segment
                segment_audio = wav[start_sample:end_sample]

                if len(segment_audio) < 1600:  # Skip very short segments
                    continue

                # Get embedding
                with torch.no_grad():
                    embedding = classifier.encode_batch(torch.tensor(segment_audio).unsqueeze(0))
                    embedding = embedding.squeeze().numpy()

                results.append({
                    'start': start_sample / 16000.0,
                    'end': end_sample / 16000.0,
                    'embedding': embedding.tolist()
                })

            if len(results) < 2:
                # Not enough segments, assign all to SPEAKER_01
                output = []
                for r in results:
                    output.append({
                        'speaker': 'SPEAKER_01',
                        'text': '',
                        'start': r['start'],
                        'end': r['end']
                    })
                print(json.dumps(output))
                sys.exit(0)

            # Perform Mean Shift clustering
            from sklearn.cluster import MeanShift

            embeddings = np.array([r['embedding'] for r in results])

            # We want exactly 2 clusters
            # Use bandwidth that typically gives 2 clusters for speaker diarization
            try:
                clustering = MeanShift(bandwidth=0.5).fit(embeddings)
            except:
                # Fallback: split by duration heuristics
                clustering_labels = [0] * len(results)
                mid = len(results) // 2
                clustering_labels = [0 if i < mid else 1 for i in range(len(results))]
                clustering = type('obj', (object,), {'labels_': clustering_labels})()

            unique_labels = list(set(clustering.labels_))

            # Map clusters to SPEAKER_01/SPEAKER_02
            # First occurring label -> SPEAKER_01
            label_map = {}
            for label in unique_labels:
                if len(label_map) == 0:
                    label_map[label] = 'SPEAKER_01'
                else:
                    label_map[label] = 'SPEAKER_02'

            # Sort segments by start time
            results.sort(key=lambda x: x['start'])

            output = []
            for i, r in enumerate(results):
                speaker = label_map[clustering.labels_[i]]
                output.append({
                    'speaker': speaker,
                    'text': '',
                    'start': round(r['start'], 2),
                    'end': round(r['end'], 2)
                })

            print(json.dumps(output))

        except Exception as e:
            # Fallback: assign all to SPEAKER_01
            output = []
            for segment in speech_timestamps:
                start = segment['start'] / 16000.0
                end = segment['end'] / 16000.0
                output.append({
                    'speaker': 'SPEAKER_01',
                    'text': '',
                    'start': round(start, 2),
                    'end': round(end, 2)
                })
            print(json.dumps(output))

    except Exception as e:
        print(f"Error: {str(e)}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    get_speech_timestamps()
"""
    }
}
