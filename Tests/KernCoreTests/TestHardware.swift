import Darwin

/// Reports whether the tests are running directly on an Apple Silicon Mac rather than inside a virtual machine.
let onAppleSiliconHardware: Bool = {
  #if arch(arm64)
    var virtualized: Int32 = 0
    var size = MemoryLayout<Int32>.size

    return sysctlbyname("kern.hv_vmm_present", &virtualized, &size, nil, 0) != 0 || virtualized == 0
  #else
    return false
  #endif
}()
