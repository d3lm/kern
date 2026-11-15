import Darwin

public struct Chip: Hashable, Sendable, CustomStringConvertible {
  public enum Family: Int, CaseIterable, Sendable {
    case m1 = 1
    case m2, m3, m4, m5
  }

  public enum Variant: CaseIterable, Sendable {
    case base, pro, max, ultra
  }

  public let family: Family
  public let variant: Variant

  public init(family: Family, variant: Variant) {
    self.family = family
    self.variant = variant
  }

  public var description: String {
    let name = "M\(family.rawValue)"
    switch variant {
    case .base: return name
    case .pro: return name + " Pro"
    case .max: return name + " Max"
    case .ultra: return name + " Ultra"
    }
  }

  static let all: [Chip] = Family.allCases.flatMap { family in
    Variant.allCases.map { Chip(family: family, variant: $0) }
  }
}

public enum ChipIdentity: Hashable, Sendable, CustomStringConvertible {
  case recognized(Chip)
  /// `brandString` is nil when the system did not report one.
  case unrecognized(brandString: String?)

  /// Accepts only the exact strings Apple Silicon reports in `machdep.cpu.brand_string`.
  /// Anything else is unrecognized, so chip-specific adapters are never applied by guesswork.
  public init(brandString: String) {
    if let chip = Chip.all.first(where: { "Apple \($0)" == brandString }) {
      self = .recognized(chip)
    } else {
      self = .unrecognized(brandString: brandString)
    }
  }

  public var description: String {
    switch self {
    case .recognized(let chip): return chip.description
    case .unrecognized: return "unrecognized"
    }
  }
}

public enum ChipIdentifier {
  /// Read from the system on first access and kept for the life of the process.
  public static let current: ChipIdentity =
    readBrandString().map(ChipIdentity.init(brandString:))
    ?? .unrecognized(brandString: nil)

  static func readBrandString() -> String? {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }
}
