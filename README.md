# DirWiz

A macOS disk usage analyzer with a Metal-rendered cushion treemap, duplicate finder, and hardlink deduplication — inspired by WinDirStat.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Cushion Treemap** — Metal-rendered, WinDirStat-style visualization with per-extension vivid colors
- **File Scanner** — Fast recursive scan with real-time progress, allocated (on-disk) size display
- **Duplicate Finder** — Content-hash-based duplicate detection across directories
- **Hardlink Deduplication** — Identify and deduplicate hardlinked files
- **Extension Drill-down** — Filter and explore by file extension
- **FDA Banner** — Full Disk Access guidance for restricted directories
- **CLI** — `DirWizCLI` for scripted scanning and benchmarking

## Tech Stack

Swift, SwiftUI, Metal, Accelerate, GCD — no third-party dependencies.

## Build

```bash
# Xcode
open Package.swift

# CLI
swift build -c release
.build/release/DirWizCLI <path>

# Tests
swift test
```

## Architecture

```
Sources/
├── Models/       AppState, FileNode, DuplicateState, FileCategory, ExtensionPalette
├── Scanner/      FileScanner, DuplicateFinder, HardlinkFinder
├── Treemap/      CushionRenderer (Metal), CushionTreemapView, TreemapInteraction
├── Views/        ContentView, ExtensionLegend, ExtensionListView, TreeTableView, DuplicateFilesView
└── CLI/          DirWizCLI, BenchmarkCommand
Tests/            FileScannerTests, DuplicateFinderTests, HardlinkFinderTests
```

## Feature Branches

| Branch | Description |
|--------|-------------|
| `feature/bundle` | App bundle analysis |
| `feature/quicklook` | QuickLook preview integration |
| `feature/trash` | Move to Trash support |
| `feature/footer` | Status bar / footer improvements |
