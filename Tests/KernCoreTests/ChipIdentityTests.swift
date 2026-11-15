import Testing

@testable import KernCore

struct ChipIdentityTests {
  static let appleSiliconBrandStrings: [(String, Chip)] = [
    ("Apple M1", Chip(family: .m1, variant: .base)),
    ("Apple M1 Pro", Chip(family: .m1, variant: .pro)),
    ("Apple M1 Max", Chip(family: .m1, variant: .max)),
    ("Apple M1 Ultra", Chip(family: .m1, variant: .ultra)),
    ("Apple M2", Chip(family: .m2, variant: .base)),
    ("Apple M2 Pro", Chip(family: .m2, variant: .pro)),
    ("Apple M2 Max", Chip(family: .m2, variant: .max)),
    ("Apple M2 Ultra", Chip(family: .m2, variant: .ultra)),
    ("Apple M3", Chip(family: .m3, variant: .base)),
    ("Apple M3 Pro", Chip(family: .m3, variant: .pro)),
    ("Apple M3 Max", Chip(family: .m3, variant: .max)),
    ("Apple M3 Ultra", Chip(family: .m3, variant: .ultra)),
    ("Apple M4", Chip(family: .m4, variant: .base)),
    ("Apple M4 Pro", Chip(family: .m4, variant: .pro)),
    ("Apple M4 Max", Chip(family: .m4, variant: .max)),
    ("Apple M4 Ultra", Chip(family: .m4, variant: .ultra)),
    ("Apple M5", Chip(family: .m5, variant: .base)),
    ("Apple M5 Pro", Chip(family: .m5, variant: .pro)),
    ("Apple M5 Max", Chip(family: .m5, variant: .max)),
    ("Apple M5 Ultra", Chip(family: .m5, variant: .ultra)),
  ]

  @Test(arguments: appleSiliconBrandStrings)
  func recognizesEachAppleSiliconChip(brandString: String, expected: Chip) {
    #expect(ChipIdentity(brandString: brandString) == .recognized(expected))
  }

  @Test func brandStringTableCoversEverySupportedChip() {
    #expect(Set(Self.appleSiliconBrandStrings.map(\.1)) == Set(Chip.all))
  }

  @Test(arguments: [
    "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz",
    "VirtualApple @ 2.50GHz processor",
    "Apple M6",
    "Apple M6 Max",
    "Apple M0",
    "Apple M10",
    "Apple M",
    "Apple M1 Maximum",
    "Apple M1 Max ",
    "Apple M1  Max",
    "apple m1 max",
    "",
  ])
  func reportsAnythingElseAsUnrecognized(brandString: String) {
    #expect(ChipIdentity(brandString: brandString) == .unrecognized(brandString: brandString))
  }

  @Test func describesChipsTheWayAppleNamesThem() {
    #expect(Chip(family: .m1, variant: .base).description == "M1")
    #expect(Chip(family: .m3, variant: .pro).description == "M3 Pro")
    #expect(Chip(family: .m1, variant: .max).description == "M1 Max")
    #expect(Chip(family: .m5, variant: .ultra).description == "M5 Ultra")
  }
}
