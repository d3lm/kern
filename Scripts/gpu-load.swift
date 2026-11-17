// Keeps the GPU fully busy with a fixed Metal compute workload for a set time, so GPU readings can be compared
// between idle and load.
//
// Run it as `swift Scripts/gpu-load.swift [seconds]`, where the time defaults to 60 seconds.

import Foundation
import Metal

let usage = "usage: swift Scripts/gpu-load.swift [seconds]"

guard CommandLine.arguments.count <= 2 else {
  print(usage)
  exit(EX_USAGE)
}

let seconds = CommandLine.arguments.count == 2 ? Double(CommandLine.arguments[1]) : 60

guard let seconds, seconds > 0 else {
  print(usage)
  exit(EX_USAGE)
}

// Pure arithmetic with no memory traffic, so the load depends on the GPU alone and not on whatever else
// is using memory bandwidth.
let shader = """
  #include <metal_stdlib>
  using namespace metal;

  kernel void spin(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id);

    for (uint i = 0; i < 20000; i++) {
      x = fma(x, 1.000001f, 0.5f);
    }

    out[id] = x;
  }
  """

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
  print("no Metal device")
  exit(EXIT_FAILURE)
}

let pipeline: MTLComputePipelineState

do {
  let library = try device.makeLibrary(source: shader, options: nil)

  pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "spin")!)
} catch {
  print("could not build the shader: \(error)")
  exit(EXIT_FAILURE)
}

let threads = 1 << 20

guard let output = device.makeBuffer(length: threads * MemoryLayout<Float>.stride, options: .storageModePrivate) else {
  print("could not allocate the output buffer")
  exit(EXIT_FAILURE)
}

func submit() -> MTLCommandBuffer {
  let commands = queue.makeCommandBuffer()!
  let encoder = commands.makeComputeCommandEncoder()!

  encoder.setComputePipelineState(pipeline)

  encoder.setBuffer(output, offset: 0, index: 0)

  encoder.dispatchThreads(
    MTLSize(width: threads, height: 1, depth: 1),
    threadsPerThreadgroup: MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
  )

  encoder.endEncoding()

  commands.commit()

  return commands
}

print("device: \(device.name)")
print(String(format: "loading the GPU for %.0f s", seconds))

fflush(nil)

let deadline = Date.now.addingTimeInterval(seconds)

var inFlight = [submit(), submit()]
var busy: Double = 0
var batches = 0

while Date.now < deadline {
  let finished = inFlight.removeFirst()

  finished.waitUntilCompleted()

  busy += finished.gpuEndTime - finished.gpuStartTime
  batches += 1

  inFlight.append(submit())
}

for commands in inFlight {
  commands.waitUntilCompleted()
}

print(String(format: "done: %d batches, %.1f ms GPU time each", batches, busy / Double(batches) * 1000))
