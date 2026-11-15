import KernCore

switch ChipIdentifier.current {
case .recognized(let chip):
  print("chip: \(chip)")
case .unrecognized(let brandString?):
  print("chip: unrecognized (brand string: \"\(brandString)\")")
case .unrecognized(nil):
  print("chip: unrecognized (no brand string reported)")
}
