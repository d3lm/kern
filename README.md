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
11:19:01  cpu.host_processor_info  unavailable (awaiting baseline)
11:19:04  cpu.host_processor_info   58.1 %
11:19:06  cpu.host_processor_info   62.9 %
```

The first CPU reading is always unavailable, because utilization is the change between two readings.

To see what a running process has cost so far (CPU time and wakeups, the counters Activity Monitor uses):

```sh
swift Scripts/process-cost.swift <pid>
```

## Project layout

| Path                  | Contents                                       |
| --------------------- | ---------------------------------------------- |
| `Sources/KernCore`    | Chip detection, sensors, and metric collection |
| `Sources/kern-probe`  | The development probe                          |
| `Tests/KernCoreTests` | Unit tests                                     |
| `Scripts`             | Development measurement scripts                |
