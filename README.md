# VR180 Injector by Siyang Qi

A native macOS app to inject VR180 metadata into SBS H.265 video files — **no re-encoding**, instant metadata injection (~100 bytes added).

## Features

- **YouTube VR180** — Injects Google Spherical Video V2 metadata (st3d + sv3d) for YouTube upload
- **Vision Pro APMP** — Injects Apple Projected Media Profile metadata (vexu + hfov) for native VR180 stereo playback on visionOS 26+
- **Batch processing** — Queue multiple files or entire folders, process them in one go with per-item status
- **Adjustable camera baseline** — Default 64mm
- **Overwrite mode** — Modify files in-place, no copy needed
- **Handles large files** — Only modifies the moov atom, works with 17GB+ files
- **Drag & drop** — Drop one or many files, or drop a folder (recursively finds .mp4 / .mov / .m4v)

## Download

Download the latest signed & notarized release from [Releases](https://github.com/silverqsy/VR180Injector/releases).

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
- Input must be H.265/HEVC encoded (.mp4 or .mov)

## Build from Source

```bash
swiftc -O -parse-as-library -o "VR180 Injector" VR180Injector.swift \
    -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers
```

## Size

~400 KB native binary — no Python, no runtime dependencies. Signed DMG is ~150 KB.

## License

MIT
