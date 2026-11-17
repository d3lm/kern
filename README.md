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

The app runs as a menu-bar item with no Dock icon and no window:

```sh
xcodebuild -project App/Kern.xcodeproj -scheme Kern -configuration Release -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Release/Kern.app
```

Or open `App/Kern.xcodeproj` in Xcode and run the `Kern` scheme.

Click the menu-bar item for the details of every metric.

By default the menu bar shows the CPU temperature, a chart of the last two minutes of CPU use, a gauge of GPU activity, and a gauge of memory pressure, in that order. To change the order, hide widgets, or hide the `CPU`, `GPU`, and `RAM` labels, set the layout with `defaults` and restart Kern.

```sh
defaults write dev.kern.Kern menuBarLayout '{ widgets = (gpu, cpu); showsLabels = NO; }'
defaults delete dev.kern.Kern menuBarLayout    # back to the default
```

Debug builds accept `--fail <metric>[:<seconds>]` to make a sensor fail and `--chip "<brand string>"` to pretend to run on another chip.

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

$ swift run -c release kern-probe temperature    # one CPU temperature every 10 seconds until Ctrl-C
chip: M1 Max
15:05:46  temperature.smc.cpu  temperature   68.8 °C
15:05:57  temperature.smc.cpu  temperature   64.6 °C

$ swift run -c release kern-probe memory    # the share of memory in use every 5 seconds until Ctrl-C
chip: M1 Max
21:49:26  memory.host_statistics64  memory in use   86.6 %
21:49:31  memory.host_statistics64  memory in use   86.7 %

$ swift run -c release kern-probe memory-pressure    # the memory pressure every 5 seconds until Ctrl-C
chip: M1 Max
21:59:22  memory.memorystatus_level  memory pressure   70.0 %
21:59:27  memory.memorystatus_level  memory pressure   66.0 %
```

Memory pressure is the share of memory that macOS cannot give to an app without first reclaiming it, and the menu bar's RAM gauge shows it. Once memory is full, used memory stays near the top while pressure keeps moving with how hard macOS is working.

The first CPU and GPU readings are always unavailable, because both numbers are the change between two readings. The GPU number is active-state residency, not utilization. It is the share of time the GPU was powered on, which includes time spent drawing the screen, so an idle desktop does not read zero.

The temperature is the hottest of the CPU die sensors that have been verified for the chip. On a chip without a verified sensor map, which today means every chip except the M1 Max, it is always unavailable.

The `metrics` command runs all the metrics the way the app does, each on its own schedule, and prints what the app would read for a metric each time it is sampled:

```sh
$ swift run -c release kern-probe metrics    # until Ctrl-C or Ctrl-D
chip: M1 Max
16:04:32  cpu          unavailable (awaiting baseline)  history 1/60, 1 gap
16:04:32  temperature   69.3 °C
16:04:32  gpu          unavailable (awaiting baseline)  history 1/60, 1 gap
16:04:34  cpu           49.8 %  history 2/60, 1 gap
16:04:34  gpu           38.4 %  history 2/60, 1 gap
disable gpu
16:04:37  gpu disabled
interval cpu 1
16:04:42  cpu every 1 s
```

While it runs, type `enable <metric>`, `disable <metric>`, or `interval <metric> <seconds>` to change the schedules, where `<metric>` is `cpu`, `gpu`, `temperature`, `memory`, or `memory-pressure`. Used memory is sampled only after `details on`, as the app samples it only while its popover is open, and `details off` stops it again. A sample without a value stays in the history as a gap. When the latest sample has no value, the line also shows the last successful value and whether it is still current or already stale.

To find the temperature sensors of a new chip, list every temperature the SMC reports, one comma-separated row per second, and watch which ones follow a CPU load:

```sh
swift run -c release kern-probe temperature-sensors > sensors.csv
```

`Scripts/process-cost.swift` prints what a running process has cost so far in CPU time and wakeups, the counters Activity Monitor uses:

```sh
swift Scripts/process-cost.swift <pid>
```

`Scripts/gpu-load.swift` puts a steady, full load on the GPU for a given number of seconds (60 by default), so GPU readings can be compared at idle and under load:

```sh
swift Scripts/gpu-load.swift 60
```

`Scripts/memory-load.swift` fills a given amount of memory (4 GiB by default) with random bytes that cannot be compressed, holds it for a given time (30 seconds by default), and frees it:

```sh
swift Scripts/memory-load.swift 4 30
```

`kern-popover-bench` measures how long the popover takes to open and how much memory it leaves behind. It runs Kern from a Release build and opens and closes the popover by posting clicks to its own menu-bar item:

```sh
$ swift build -c release --product kern-popover-bench && .build/release/kern-popover-bench 50
memory before the first opening: footprint 13.1 MiB, resident 24.1 MiB
memory after 1 opening: footprint 14.3 MiB, resident 31.5 MiB
memory after 20 openings: footprint 18.0 MiB, resident 40.0 MiB
memory after 50 openings: footprint 19.3 MiB, resident 41.5 MiB
openings: 50, 0 failed checks
click to drawn, ms: median 40.7, p95 50.9, max 61.0
```

## Project layout

| Path                         | Contents                                                        |
| ---------------------------- | --------------------------------------------------------------- |
| `Sources/KernCore`           | Chip detection, sensors, and metric collection                  |
| `Sources/KernUI`             | The menu bar, the popover, and the app's startup                |
| `Sources/kern-probe`         | The development probe                                           |
| `Sources/kern-popover-bench` | The popover measurement tool                                    |
| `App`                        | The Xcode project with the app's entry point and build settings |
| `Tests/KernCoreTests`        | Unit tests of the core                                          |
| `Tests/KernUITests`          | Unit tests of the menu bar and the popover                      |
| `Scripts`                    | Development measurement scripts                                 |
