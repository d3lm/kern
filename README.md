<p align="center">
  <img src="assets/logo.webp" alt="Kern logo" width="120">
</p>

# Kern

A lightweight macOS menu-bar monitor for Apple Silicon. Kern shows CPU temperature, a CPU usage graph, and GPU activity in the menu bar, and is built to use almost no resources itself.

<p align="center">
  <img src="assets/menu-bar.png" alt="Kern in the menu bar, showing the CPU temperature, a CPU usage chart, and gauges for GPU activity and memory pressure" width="308">
</p>

<p align="center">
  <img src="assets/popover.png" alt="Kern's popover with cards for CPU, GPU, temperature, and memory" width="376">
</p>

## Requirements

- A Mac with an M1, M2, M3, M4, or M5 chip
- macOS 15 or later
- Xcode 16.3 or later

## Getting started

```sh
# build
swift build -c release --arch arm64

# run the tests
swift test

# show what Kern reads on this Mac
swift run kern-probe
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
defaults delete dev.kern.Kern menuBarLayout # back to the default
```

Kern stops sampling while the Mac sleeps and samples again as soon as it wakes. In Low Power Mode it samples CPU and GPU every 5 seconds, memory every 10, and temperature every 20, instead of every 2, 5, and 10. To keep the usual intervals in Low Power Mode, set the behavior to `override` and restart Kern.

```sh
defaults write dev.kern.Kern lowPowerModeBehavior override
defaults delete dev.kern.Kern lowPowerModeBehavior # back to adaptive, the default
```

A sensor that fails is tried again after one interval, then after two, four, and so on, until the wait would pass a minute. Its readings return at the first retry that works.

Debug builds accept `--fail <metric>[:<seconds>]` to make a sensor fail and `--chip "<brand string>"` to pretend to run on another chip.

`kern-probe` is a development tool that prints sensor readings in the terminal. It is not part of the app.

```sh
$ swift run kern-probe
chip: M1 Max

$ swift run -c release kern-probe cpu # one CPU reading every 2 seconds until Ctrl-C
chip: M1 Max
11:19:01  cpu.host_processor_info  utilization  unavailable (awaiting baseline)
11:19:04  cpu.host_processor_info  utilization   58.1 %
11:19:06  cpu.host_processor_info  utilization   62.9 %

$ swift run -c release kern-probe gpu # one GPU reading every 2 seconds until Ctrl-C
chip: M1 Max
14:30:56  gpu.ioreport.gpuph  active residency  unavailable (awaiting baseline)
14:30:58  gpu.ioreport.gpuph  active residency   59.4 %
14:31:00  gpu.ioreport.gpuph  active residency   51.9 %

$ swift run -c release kern-probe temperature # one CPU temperature every 10 seconds until Ctrl-C
chip: M1 Max
15:05:46  temperature.smc.cpu  temperature   68.8 °C
15:05:57  temperature.smc.cpu  temperature   64.6 °C

$ swift run -c release kern-probe memory # the share of memory in use every 5 seconds until Ctrl-C
chip: M1 Max
21:49:26  memory.host_statistics64  memory in use   86.6 %
21:49:31  memory.host_statistics64  memory in use   86.7 %

$ swift run -c release kern-probe memory-pressure # the memory pressure every 5 seconds until Ctrl-C
chip: M1 Max
21:59:22  memory.memorystatus_level  memory pressure   70.0 %
21:59:27  memory.memorystatus_level  memory pressure   66.0 %
```

Memory pressure is the share of memory that macOS cannot give to an app without first reclaiming it, and the menu bar's RAM gauge shows it. Once memory is full, used memory stays near the top while pressure keeps moving with how hard macOS is working.

The first CPU and GPU readings are always unavailable, because both numbers are the change between two readings. The GPU number is active-state residency, not utilization. It is the share of time the GPU was powered on, which includes time spent drawing the screen, so an idle desktop does not read zero.

The temperature is the hottest of the CPU die sensors that have been verified for the chip. On a chip without a verified sensor map, which today means every chip except the M1 Max, it is always unavailable.

The `metrics` command runs all the metrics the way the app does, each on its own schedule, and prints what the app would read for a metric each time it is sampled:

```sh
$ swift run -c release kern-probe metrics # until Ctrl-C or Ctrl-D
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

While it runs, type `enable <metric>`, `disable <metric>`, or `interval <metric> <seconds>` to change the schedules, where `<metric>` is `cpu`, `gpu`, `temperature`, `memory`, or `memory-pressure`. Used memory is sampled only after `details on`, as the app samples it only while its popover is open, and `details off` stops it again. `sleep` and `wake` suspend and resume sampling as the app does when the Mac sleeps and wakes. `low-power on` and `low-power off` sample as the app does while Low Power Mode is on or off, and `low-power-behavior override` or `low-power-behavior adaptive` sets whether Low Power Mode slows the sampling down. A sample without a value stays in the history as a gap. When the latest sample has no value, the line also shows the last successful value and whether it is still current or already stale.

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

`kern-power-bench` runs Kern and announces sleep and wake to it ten times, without putting the Mac to sleep. It puts an item in the menu bar while it runs, next to Kern's own if Kern is running. `Scripts/power-report.swift` reads Kern's debug log and prints what Kern did at each sleep and wake. It checks that nothing was sampled during a sleep, that every provider was stopped and started again, that every metric was sampled within 5 seconds of the wake without a burst, and that each metric still has exactly one schedule at the end:

```sh
$ swift build -c release --product kern-power-bench
$ log stream --style ndjson --level debug --predicate 'subsystem == "Kern" && process == "kern-power-bench"' \
    | swift Scripts/power-report.swift    # in a second terminal, until Ctrl-C
$ .build/release/kern-power-bench 10
```

The script reports real sleeps the same way. Start it with `process == "Kern"` in the predicate while the app runs, put the Mac to sleep and wake it as often as wanted, and press Ctrl-C. With more than one Kern running, add `&& processID == <pid>` to the predicate.

## Project layout

| Path                         | Contents                                                        |
| ---------------------------- | --------------------------------------------------------------- |
| `Sources/KernCore`           | Chip detection, sensors, and metric collection                  |
| `Sources/KernUI`             | The menu bar, the popover, and the app's startup                |
| `Sources/kern-probe`         | The development probe                                           |
| `Sources/kern-popover-bench` | The popover measurement tool                                    |
| `Sources/kern-power-bench`   | The sleep and wake test tool                                    |
| `App`                        | The Xcode project with the app's entry point and build settings |
| `Tests/KernCoreTests`        | Unit tests of the core                                          |
| `Tests/KernUITests`          | Unit tests of the menu bar and the popover                      |
| `Scripts`                    | Development measurement scripts                                 |
