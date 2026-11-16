import IOKit

struct SMCKey: Hashable, Sendable, CustomStringConvertible {
  let code: UInt32

  init?(_ name: String) {
    let characters = Array(name.utf8)

    guard characters.count == 4, characters.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }

    code = characters.reduce(0) { $0 << 8 | UInt32($1) }
  }

  init(code: UInt32) {
    self.code = code
  }

  var description: String {
    String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
  }

  static let keyCount = SMCKey("#KEY")!
}

struct SMCKeyInfo: Equatable, Sendable, CustomStringConvertible {
  let size: UInt32
  let type: SMCKey

  var description: String { "\(size)-byte \(type)" }

  static let float = SMCKeyInfo(size: 4, type: SMCKey("flt ")!)
}

struct SMCConnection: Sendable {
  private enum Command: UInt8 {
    case readKey = 5
    case readKeyAtIndex = 8
    case readKeyInfo = 9
  }

  /// `kSMCHandleYPCEvent`, the user client method that carries every command.
  private static let selector: UInt32 = 2

  private var port: io_connect_t

  init() throws(SensorError) {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))

    guard service != IO_OBJECT_NULL else { throw SensorError("IOKit has no AppleSMC service") }

    defer { IOObjectRelease(service) }

    var port = io_connect_t(IO_OBJECT_NULL)
    let result = IOServiceOpen(service, mach_task_self_, 0, &port)

    guard result == KERN_SUCCESS else {
      throw SensorError("could not open AppleSMC: \(String(cString: mach_error_string(result)))")
    }

    self.port = port
  }

  mutating func close() {
    guard port != IO_OBJECT_NULL else { return }

    IOServiceClose(port)

    port = io_connect_t(IO_OBJECT_NULL)
  }

  func info(for key: SMCKey) throws(SensorError) -> SMCKeyInfo {
    var request = SMCParameters()

    request.key = key.code

    let response = try call(.readKeyInfo, request)

    return SMCKeyInfo(size: response.dataSize, type: SMCKey(code: response.dataType))
  }

  func read(_ key: SMCKey, _ info: SMCKeyInfo) throws(SensorError) -> ArraySlice<UInt8> {
    guard info.size <= SMCParameters.dataCapacity else {
      throw SensorError("SMC key \(key) holds \(info.size) bytes, more than one read returns")
    }

    var request = SMCParameters()

    request.key = key.code
    request.dataSize = info.size

    return try call(.readKey, request).data.prefix(Int(info.size))
  }

  func allKeys() throws(SensorError) -> [SMCKey] {
    // big-endian, unlike `flt ` values, which are little-endian
    let count = try read(.keyCount, info(for: .keyCount)).reduce(0) { $0 << 8 | UInt32($1) }

    return try (0..<count).map { index throws(SensorError) in
      var request = SMCParameters()

      request.index = index

      return SMCKey(code: try call(.readKeyAtIndex, request).key)
    }
  }

  private func call(_ command: Command, _ request: SMCParameters) throws(SensorError) -> SMCParameters {
    var request = request
    var response = SMCParameters()
    var responseSize = SMCParameters.size

    request.command = command.rawValue

    let result = request.bytes.withUnsafeBytes { input in
      response.bytes.withUnsafeMutableBytes { output in
        IOConnectCallStructMethod(
          port, Self.selector, input.baseAddress, input.count, output.baseAddress, &responseSize)
      }
    }

    let subject =
      command == .readKeyAtIndex ? "SMC key at index \(request.index)" : "SMC key \(SMCKey(code: request.key))"

    guard result == KERN_SUCCESS else {
      throw SensorError("\(subject) call failed: \(String(cString: mach_error_string(result)))")
    }

    guard responseSize == SMCParameters.size, response.result == 0 else {
      throw SensorError("\(subject) returned result \(response.result) in \(responseSize) bytes")
    }

    return response
  }
}

/// No public header declares `SMCParamStruct`, so the size and every field offset must match its C layout exactly.
private struct SMCParameters {
  static let size = 80
  static let dataCapacity: UInt32 = 32

  var bytes = [UInt8](repeating: 0, count: size)

  var key: UInt32 {
    get { load(at: 0) }
    set { store(newValue, at: 0) }
  }

  var dataSize: UInt32 {
    get { load(at: 28) }
    set { store(newValue, at: 28) }
  }

  var dataType: UInt32 { load(at: 32) }

  var result: UInt8 { bytes[40] }

  var command: UInt8 {
    get { bytes[42] }
    set { bytes[42] = newValue }
  }

  var index: UInt32 {
    get { load(at: 44) }
    set { store(newValue, at: 44) }
  }

  var data: ArraySlice<UInt8> { bytes[48...] }

  private func load(at offset: Int) -> UInt32 {
    bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
  }

  private mutating func store(_ value: UInt32, at offset: Int) {
    bytes.withUnsafeMutableBytes { $0.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
  }
}
