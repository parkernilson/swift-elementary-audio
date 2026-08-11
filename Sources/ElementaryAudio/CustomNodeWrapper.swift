import cxxElementaryAudio

public class CustomNodeWrapper {
    private let node: CustomNode

    public init(id: Int32, sampleRate: Float, blockSize: Int32) {
        node = CustomNode.create(id, sampleRate, blockSize)
    }

    public func setProperty(_ key: String, value: Float) -> Int32 {
        return node.setPropertyWrapper(key, value)
    }

    public func process(_ context: FloatBlockContext) {
        node.processWrapper(context)
    }

    /// Processes audio directly into a raw output buffer (avoids constructing BlockContext from Swift)
    public func processSimple(_ outputBuffer: UnsafeMutablePointer<Float>, _ numSamples: Int) {
        node.processSimple(outputBuffer, numSamples)
    }
}
