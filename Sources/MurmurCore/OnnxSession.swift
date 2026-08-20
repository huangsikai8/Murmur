import COnnxRuntime
import Foundation

/// A loaded ONNX model, run on the ONNX Runtime that is already inside the
/// binary.
///
/// Murmur links no ONNX runtime of its own. `moonshine-swift` ships a static
/// library whose C++ core embeds ORT 1.23.0 and exports its C entry points, so
/// `OrtGetApiBase` resolves at link time and a second copy of the runtime —
/// tens of megabytes — is not needed. `Package.swift` carries the matching
/// headers and nothing else.
///
/// The coupling is worth naming: if moonshine-swift ever stops exporting those
/// symbols this fails to *link*, loudly, at build time. It cannot degrade into
/// wrong output at runtime, which is the only failure mode that would matter
/// for a text pipeline.
///
/// This is the smallest wrapper that can run smart-turn — one float32 tensor
/// in, one float32 tensor out. It is not a general ONNX facade.
public final class OnnxSession: @unchecked Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case runtimeUnavailable
        case modelMissing(String)
        case ort(String)

        public var description: String {
            switch self {
            case .runtimeUnavailable: return "ONNX Runtime is unavailable"
            case .modelMissing(let path): return "ONNX model not found at \(path)"
            case .ort(let message): return "ONNX Runtime: \(message)"
            }
        }
    }

    private let api: UnsafePointer<OrtApi>
    private let env: OpaquePointer
    private let options: OpaquePointer
    private let session: OpaquePointer
    private let memoryInfo: OpaquePointer

    /// Owned C strings for the tensor names, kept alive for the session.
    private let inputName: UnsafeMutablePointer<CChar>
    private let outputName: UnsafeMutablePointer<CChar>

    public init(modelPath: String, inputName: String, outputName: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw Failure.modelMissing(modelPath)
        }
        guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION))
        else { throw Failure.runtimeUnavailable }
        self.api = api

        // `check` needs `api` before `self` is fully formed, so the ORT calls
        // below go through a local closure rather than the instance method.
        let check: (OrtStatusPtr?) throws -> Void = { status in
            guard let status else { return }
            let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"
            api.pointee.ReleaseStatus(status)
            throw Failure.ort(message)
        }

        var env: OpaquePointer?
        try check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "murmur", &env))
        guard let env else { throw Failure.runtimeUnavailable }
        self.env = env

        var options: OpaquePointer?
        try check(api.pointee.CreateSessionOptions(&options))
        guard let options else { throw Failure.runtimeUnavailable }
        self.options = options
        // Single-threaded on purpose: this model runs inside the audio path
        // alongside a speech model and a VAD, and 8M parameters do not need a
        // thread pool. It matches the reference inference settings.
        try check(api.pointee.SetIntraOpNumThreads(options, 1))
        try check(api.pointee.SetInterOpNumThreads(options, 1))
        try check(api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))

        var session: OpaquePointer?
        try check(api.pointee.CreateSession(env, modelPath, options, &session))
        guard let session else { throw Failure.runtimeUnavailable }
        self.session = session

        var memoryInfo: OpaquePointer?
        try check(api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo))
        guard let memoryInfo else { throw Failure.runtimeUnavailable }
        self.memoryInfo = memoryInfo

        self.inputName = strdup(inputName)
        self.outputName = strdup(outputName)
    }

    deinit {
        api.pointee.ReleaseMemoryInfo(memoryInfo)
        api.pointee.ReleaseSession(session)
        api.pointee.ReleaseSessionOptions(options)
        api.pointee.ReleaseEnv(env)
        free(inputName)
        free(outputName)
    }

    private func check(_ status: OrtStatusPtr?) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown error"
        api.pointee.ReleaseStatus(status)
        throw Failure.ort(message)
    }

    /// Runs the model over one float32 input tensor and returns the output
    /// tensor's values, flattened.
    public func run(input: [Float], shape: [Int64]) throws -> [Float] {
        var output: OpaquePointer?
        var mutableInput = input
        var mutableShape = shape

        try mutableInput.withUnsafeMutableBufferPointer { data in
            try mutableShape.withUnsafeBufferPointer { dims in
                var value: OpaquePointer?
                try check(api.pointee.CreateTensorWithDataAsOrtValue(
                    memoryInfo,
                    data.baseAddress,
                    data.count * MemoryLayout<Float>.size,
                    dims.baseAddress,
                    dims.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                    &value))
                defer { api.pointee.ReleaseValue(value) }

                var inputNames: [UnsafePointer<CChar>?] = [UnsafePointer(inputName)]
                var outputNames: [UnsafePointer<CChar>?] = [UnsafePointer(outputName)]
                var inputs: [OpaquePointer?] = [value]

                try check(api.pointee.Run(
                    session, nil,
                    &inputNames, &inputs, 1,
                    &outputNames, 1,
                    &output))
            }
        }

        guard let output else { throw Failure.ort("no output tensor") }
        defer { api.pointee.ReleaseValue(output) }

        var count = 0
        var info: OpaquePointer?
        try check(api.pointee.GetTensorTypeAndShape(output, &info))
        defer { api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
        try check(api.pointee.GetTensorShapeElementCount(info, &count))

        var raw: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(output, &raw))
        guard let raw else { throw Failure.ort("output tensor has no data") }
        let typed = raw.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }
}
