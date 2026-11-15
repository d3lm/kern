# Kern

A lightweight macOS menu-bar monitor for Apple Silicon. Kern shows CPU temperature, a CPU usage graph, and GPU activity in the menu bar, and is built to use almost no resources itself.

## Requirements

- A Mac with an M1, M2, M3, M4, or M5 chip
- macOS 15 or later
- Xcode 16.3 or later

## Getting started

```sh
swift build -c release --arch arm64   # build
swift test                            # run the tests
swift run kern-probe                  # show what Kern reads on this Mac
```

`kern-probe` is a development tool that prints sensor readings in the terminal. It is not part of the app.

```sh
$ swift run kern-probe
chip: M1 Max
```

## Project layout

| Path                  | Contents                                       |
| --------------------- | ---------------------------------------------- |
| `Sources/KernCore`    | Chip detection, sensors, and metric collection |
| `Sources/kern-probe`  | The development probe                          |
| `Tests/KernCoreTests` | Unit tests                                     |
