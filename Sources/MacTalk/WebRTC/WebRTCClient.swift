import Foundation
import MacTalkCore
@preconcurrency import WebRTC

struct IceServerConfig: Decodable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?

    enum CodingKeys: String, CodingKey { case urls, username, credential }

    init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls; self.username = username; self.credential = credential
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let many = try? c.decode([String].self, forKey: .urls) { urls = many } else { urls = [try c.decode(String.self, forKey: .urls)] }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }

    static let publicSTUN = [IceServerConfig(urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"])]
}

/// One WebRTC peer connection carrying a single Opus audio track in each direction.
/// Media is encrypted with DTLS-SRTP (mandatory in WebRTC). Echo cancellation, noise
/// suppression and automatic gain control run in WebRTC's audio processing module.
final class WebRTCClient: NSObject, @unchecked Sendable {
    enum Event: Sendable {
        case localCandidate(SignalPayload)
        case connection(RTCIceConnectionState)
    }

    private static let sslReady: Bool = { RTCInitializeSSL() }()

    private let factory: RTCPeerConnectionFactory
    private let peerConnection: RTCPeerConnection
    private let localTrack: RTCAudioTrack
    private let onEvent: @Sendable (Event) -> Void
    private var remoteTrack: RTCAudioTrack?
    private var remoteVolume: Double = 1
    private let lock = NSLock()

    init?(iceServers: [IceServerConfig], onEvent: @escaping @Sendable (Event) -> Void) {
        _ = Self.sslReady
        self.onEvent = onEvent
        // A fresh factory per call so WebRTC opens the audio devices selected for this call.
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                           decoderFactory: RTCDefaultVideoDecoderFactory())

        let config = RTCConfiguration()
        config.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.tcpCandidatePolicy = .enabled
        config.iceCandidatePoolSize = 2

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else { return nil }
        peerConnection = pc

        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": kRTCMediaConstraintsValueTrue,
            "googNoiseSuppression": kRTCMediaConstraintsValueTrue,
            "googAutoGainControl": kRTCMediaConstraintsValueTrue,
            "googHighpassFilter": kRTCMediaConstraintsValueTrue,
        ], optionalConstraints: nil)
        let source = factory.audioSource(with: audioConstraints)
        localTrack = factory.audioTrack(with: source, trackId: "mactalk-mic")
        super.init()
        pc.delegate = self
        pc.add(localTrack, streamIds: ["mactalk"])
    }

    // MARK: SDP

    private var mediaConstraints: RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse],
                            optionalConstraints: nil)
    }

    func makeOffer(iceRestart: Bool = false) async throws -> String {
        let constraints = iceRestart
            ? RTCMediaConstraints(mandatoryConstraints: [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                                         kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue],
                                  optionalConstraints: nil)
            : mediaConstraints
        let sdp: String = try await withCheckedThrowingContinuation { cont in
            peerConnection.offer(for: constraints) { desc, error in
                if let desc { cont.resume(returning: desc.sdp) } else { cont.resume(throwing: error ?? MacTalkError.webRTCFailed) }
            }
        }
        try await setLocal(RTCSessionDescription(type: .offer, sdp: sdp))
        return sdp
    }

    func makeAnswer() async throws -> String {
        let sdp: String = try await withCheckedThrowingContinuation { cont in
            peerConnection.answer(for: mediaConstraints) { desc, error in
                if let desc { cont.resume(returning: desc.sdp) } else { cont.resume(throwing: error ?? MacTalkError.webRTCFailed) }
            }
        }
        try await setLocal(RTCSessionDescription(type: .answer, sdp: sdp))
        return sdp
    }

    private func setLocal(_ desc: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(desc) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    func setRemote(sdp: String, isOffer: Bool) async throws {
        let desc = RTCSessionDescription(type: isOffer ? .offer : .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(desc) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    var hasRemoteDescription: Bool { peerConnection.remoteDescription != nil }

    func add(candidate payload: SignalPayload) async {
        guard let sdp = payload.candidate else { return }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: payload.sdpMLineIndex ?? 0, sdpMid: payload.sdpMid)
        try? await peerConnection.add(candidate)
    }

    // MARK: Controls

    var isMuted: Bool {
        get { !localTrack.isEnabled }
        set { localTrack.isEnabled = !newValue }
    }

    /// Playback gain for the other person's voice (0…1 maps to WebRTC's 0…10 source volume).
    func setOutputVolume(_ value: Double) {
        lock.lock(); remoteVolume = value; let track = remoteTrack; lock.unlock()
        track?.source.volume = max(0, min(10, value * 10))
    }

    func quality() async -> ConnectionQuality {
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in
            peerConnection.statistics { cont.resume(returning: $0) }
        }
        var rtt: Double?, jitter: Double?, lost = 0.0, received = 0.0
        for stat in report.statistics.values {
            if stat.type == "candidate-pair", (stat.values["state"] as? String) == "succeeded",
               (stat.values["nominated"] as? NSNumber)?.boolValue ?? false {
                rtt = (stat.values["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? rtt
            }
            if stat.type == "inbound-rtp", (stat.values["kind"] as? String) == "audio" {
                lost += (stat.values["packetsLost"] as? NSNumber)?.doubleValue ?? 0
                received += (stat.values["packetsReceived"] as? NSNumber)?.doubleValue ?? 0
                jitter = (stat.values["jitter"] as? NSNumber)?.doubleValue
            }
        }
        let loss = received + lost > 0 ? lost / (received + lost) : nil
        return ConnectionQuality.rate(roundTripTime: rtt, lossRatio: loss, jitter: jitter)
    }

    func close() {
        localTrack.isEnabled = false
        peerConnection.close()
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onEvent(.connection(newState))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onEvent(.localCandidate(.ice(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCAudioTrack else { return }
        lock.lock(); remoteTrack = track; let volume = remoteVolume; lock.unlock()
        track.source.volume = volume * 10
    }
}
