import AVFoundation
import cxxElementaryAudio
@testable import ElementaryAudio
import XCTest

final class GraphRendererAudioNodeTests: XCTestCase {
    private var renderer: GraphRenderer!

    override func setUp() {
        super.setUp()
        renderer = GraphRenderer()
    }

    override func tearDown() {
        renderer.reset()
        renderer = nil
        super.tearDown()
    }

    func testGetAudioNodeReturnsNodeWithRequestedFormat() {
        let node = renderer.getAudioNode(sampleRate: 48000, blockSize: 256, channels: 1)
        let format = node.outputFormat(forBus: 0)
        XCTAssertEqual(format.sampleRate, 48000)
        XCTAssertEqual(format.channelCount, 1)
    }

    func testRenderAndProcessStillWorkAfterGetAudioNode() throws {
        _ = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 1)

        let graph = AudioGraph { El.cycle(440.0) }
        try renderer.render(graph)

        var foundNonZero = false
        for _ in 0 ..< 4 {
            let samples = processBlock(numSamples: 512)
            let maxAmp = samples.map { Swift.abs($0) }.max() ?? 0
            if maxAmp > 0.1 {
                foundNonZero = true
                XCTAssertLessThanOrEqual(maxAmp, 1.0)
                break
            }
        }
        XCTAssertTrue(foundNonZero, "audio should still play via process() after getAudioNode's internal initialize() call")
    }

    func testCallingGetAudioNodeTwiceDoesNotCrash() {
        _ = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 2)
        _ = renderer.getAudioNode(sampleRate: 48000, blockSize: 256, channels: 1)
    }

    // MARK: - Helpers

    private func processBlock(numSamples: Int) -> [Float] {
        var outputBuffer = [Float](repeating: 0, count: numSamples)
        outputBuffer.withUnsafeMutableBufferPointer { bufPtr in
            var channelPtr: UnsafeMutablePointer<Float>? = bufPtr.baseAddress
            withUnsafeMutablePointer(to: &channelPtr) { channelPtrPtr in
                renderer.process(
                    outputData: channelPtrPtr,
                    outputChannels: 1,
                    numSamples: numSamples
                )
            }
        }
        return outputBuffer
    }
}
