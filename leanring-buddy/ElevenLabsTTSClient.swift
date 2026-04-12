//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Streams text-to-speech audio from ElevenLabs and plays it back
//  through the system audio output. Uses the streaming endpoint so
//  playback begins before the full audio has been generated.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    /// Strong reference to the delegate adapter used by
    /// `speakTextAndAwaitCompletion`. `AVAudioPlayer.delegate` is a weak
    /// property, so we must hold the adapter ourselves for the duration
    /// of playback or it will deallocate and the finish callback will
    /// never fire.
    private var currentPlaybackFinishDelegate: AudioPlayerFinishDelegate?

    /// Continuation resumed when `speakTextAndAwaitCompletion` finishes.
    /// Protected by main-actor isolation — every mutation and every
    /// resume goes through `resumeCurrentPlaybackContinuationIfNeeded()`
    /// which main-actor-serializes the grab-and-nil against any racing
    /// caller (delegate finish, decode error, `stopPlayback`, or the
    /// playback-failed-to-start path).
    private var currentPlaybackContinuation: CheckedContinuation<Void, Never>?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(_ text: String) async throws {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.play()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    /// Sends `text` to ElevenLabs TTS, plays the audio, and only returns
    /// once playback actually finishes (or `stopPlayback()` is called).
    ///
    /// This is the variant used by interactive mode, which must know when
    /// the spoken utterance has finished before dispatching the next action.
    /// The existing `speakText(_:)` fire-and-forget variant is untouched.
    func speakTextAndAwaitCompletion(_ text: String) async throws {
        // Fetch audio via the same Worker proxy used by `speakText`.
        // If this throws, no continuation has been stored yet, so no
        // cleanup is required.
        let audioData = try await fetchTTSAudioData(for: text)

        // Build the player up front. If construction throws, we abort
        // before touching any continuation state.
        let player = try AVAudioPlayer(data: audioData)

        print("🔊 ElevenLabs TTS: playing \(audioData.count / 1024)KB audio (awaiting completion)")

        // Store the continuation synchronously inside the
        // `withCheckedContinuation` closure. Because the whole TTS client
        // is `@MainActor`, every continuation mutation serializes on
        // the main actor — no lock needed. The delegate callback hops
        // back to the main actor via a `Task { @MainActor in }` inside
        // `AudioPlayerFinishDelegate`, so the resume path also goes
        // through main-actor isolation.
        await withCheckedContinuation { (playbackCompletionContinuation: CheckedContinuation<Void, Never>) in
            currentPlaybackContinuation = playbackCompletionContinuation

            // Create a fresh delegate adapter for this playback. We keep
            // a strong reference on the client because
            // `AVAudioPlayer.delegate` is weak — without the strong
            // reference the adapter would deallocate immediately and the
            // finish callback would never fire.
            let finishDelegate = AudioPlayerFinishDelegate { [weak self] in
                // The delegate hops to the main actor for us, so by the
                // time this closure runs we are already on the main actor
                // and can touch the continuation safely.
                self?.resumeCurrentPlaybackContinuationIfNeeded()
            }
            player.delegate = finishDelegate
            self.currentPlaybackFinishDelegate = finishDelegate
            self.audioPlayer = player

            let playbackDidStart = player.play()
            if playbackDidStart == false {
                // `play()` returned false, meaning the player failed to
                // start for some reason. The delegate will never fire,
                // so resume the continuation immediately.
                resumeCurrentPlaybackContinuationIfNeeded()
            }
        }
    }

    /// Shared fetch helper for `speakTextAndAwaitCompletion`. Returns the
    /// raw audio bytes on success. Throws on non-2xx responses,
    /// cancellation, or network errors. This mirrors the work `speakText`
    /// does inline, but `speakText` keeps its original inline body
    /// untouched to preserve its behavior exactly (zero regression risk).
    private func fetchTTSAudioData(for text: String) async throws -> Data {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()

        return data
    }

    /// Resumes the stored playback continuation exactly once, if one
    /// exists. Main-actor-isolated, so the grab-and-nil is atomic under
    /// the main actor's mutual exclusion — any racing caller (delegate
    /// finish, decode error, explicit `stopPlayback`, or the
    /// playback-failed-to-start path) is serialized here and only the
    /// first call actually resumes the continuation.
    private func resumeCurrentPlaybackContinuationIfNeeded() {
        guard let continuationToResume = currentPlaybackContinuation else { return }
        currentPlaybackContinuation = nil
        continuationToResume.resume()
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    /// Stops any in-progress playback immediately. If a caller is
    /// awaiting `speakTextAndAwaitCompletion`, it will be resumed as
    /// part of stopping so the awaiting task doesn't deadlock.
    func stopPlayback() {
        // Resume before stopping. The delegate's
        // `audioPlayerDidFinishPlaying` is not guaranteed to fire when
        // `stop()` is called programmatically, so we must resume any
        // pending continuation ourselves.
        resumeCurrentPlaybackContinuationIfNeeded()
        audioPlayer?.stop()
        audioPlayer = nil
        currentPlaybackFinishDelegate = nil
    }
}

/// Private delegate adapter used by `speakTextAndAwaitCompletion` to
/// observe `AVAudioPlayer` completion without forcing
/// `ElevenLabsTTSClient` itself to inherit from `NSObject`. Holds a
/// main-actor-isolated closure; the delegate methods hop back to the
/// main actor via a `Task { @MainActor in }` before calling it, so the
/// closure body can touch main-actor state (the continuation field)
/// without any explicit locking.
private final class AudioPlayerFinishDelegate: NSObject, AVAudioPlayerDelegate {
    private let onPlaybackFinished: @MainActor () -> Void

    init(onPlaybackFinished: @escaping @MainActor () -> Void) {
        self.onPlaybackFinished = onPlaybackFinished
        super.init()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // `AVAudioPlayerDelegate` callbacks may fire on any thread chosen
        // by Core Audio. Hop back to the main actor before touching any
        // state in `ElevenLabsTTSClient`.
        let pinnedCallback = onPlaybackFinished
        Task { @MainActor in
            pinnedCallback()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // A decode error means playback will not complete normally, so
        // resume the waiter to prevent deadlock. Same main-actor hop
        // as the normal finish path.
        let pinnedCallback = onPlaybackFinished
        Task { @MainActor in
            pinnedCallback()
        }
    }
}
