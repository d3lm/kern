# Kern

A lightweight macOS menu-bar monitor for Apple Silicon. Kern shows CPU temperature, a CPU usage graph, and GPU activity in the menu bar, and is built to use almost no resources itself.

## Requirements

- A Mac with an M1, M2, M3, M4, or M5 chip
- macOS 15 or later
- Xcode 16.3 or later

## Getting started

```sh
swift build -c release --arch arm64    # build
swift test                             # run the tests
swift run kern-probe                   # show what Kern reads on this Mac
```

`kern-probe` is a development tool that prints sensor readings in the terminal. It is not part of the app.

```sh
$ swift run kern-probe
chip: M1 Max

$ swift run -c release kern-probe cpu    # one CPU reading every 2 seconds until Ctrl-C
chip: M1 Max
11:19:01  cpu.host_processor_info  utilization  unavailable (awaiting baseline)
11:19:04  cpu.host_processor_info  utilization   58.1 %
11:19:06  cpu.host_processor_info  utilization   62.9 %

$ swift run -c release kern-probe gpu    # one GPU reading every 2 seconds until Ctrl-C
chip: M1 Max
14:30:56  gpu.ioreport.gpuph  active residency  unavailable (awaiting baseline)
14:30:58  gpu.ioreport.gpuph  active residency   59.4 %
14:31:00  gpu.ioreport.gpuph  active residency   51.9 %
```

The first reading of each mode is always unavailable, because both numbers are the change between two readings. The GPU number is active-state residency, not utilization: the share of time the GPU was powered on, which includes time spent drawing the screen, so an idle desktop does not read zero.

To see what a running process has cost so far (CPU time and wakeups, the counters Activity Monitor uses):

```sh
swift Scripts/process-cost.swift <pid>
```

To put a steady, full load on the GPU for a given number of seconds (default 60), for comparing GPU readings at idle and under load:

```sh
swift Scripts/gpu-load.swift 60
```

## Project layout

| Path                  | Contents                                       |
| --------------------- | ---------------------------------------------- |
| `Sources/KernCore`    | Chip detection, sensors, and metric collection |
| `Sources/kern-probe`  | The development probe                          |
| `Tests/KernCoreTests` | Unit tests                                     |
| `Scripts`             | Development measurement scripts                |
