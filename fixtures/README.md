# iOS Fixture Harness

This directory documents the shared fixture harness work for the iOS port.

## Assumed Checkout Layout

These cross-platform notes assume a sibling checkout layout like:

```text
pretext/
  web/
  ios/
  <shared-fixture-workspace>/
```

So references below avoid machine-specific absolute paths. The iOS exporter can be pointed at the shared fixture workspace with `PRETEXT_FIXTURES_ROOT`.

Important context:

- the iOS parity and fixture-harness work currently lives on branch `daze/custom-harness`
- `main` contains the initial fixture exporter commit
- the later parity, fallback, and vertical-alignment work is not on `main`

If a future session needs to continue shared harness work, start from:

- repo: `pretext/ios`
- branch: `daze/custom-harness`

## Why This Matters

The Android/web/iOS comparison work depends on harness behavior and a few core fixes that were developed together while chasing parity. If someone resumes from iOS `main` without noticing the branch split, they will get stale comparison output and may end up re-debugging already-solved issues.

In practice, `daze/custom-harness` is the current source of truth for iOS fixture-export and cross-platform parity work.

## Package Boundary

This harness documents the iOS core fixture exporter only. It stays in `pretext/ios` because it needs:

- `@testable import PretextKit`
- UIKit/CoreText rendering APIs
- access to low-level measurement and fallback hooks
- PNG snapshot generation that reflects the iOS rendering path

Product-specific Swift APIs should live outside this fork. If a change is about application runtime behavior rather than CoreText parity or fixture export, keep it in the downstream integration layer instead of this package.

## What Was Added On `daze/custom-harness`

Major harness additions:

- shared JSON fixture export from `FixtureHarnessTests`
- explicit fallback measurement for:
  - `AppleColorEmoji` on iOS
  - `NotoSansArabic`
  - `NotoSansSC`
- richer run diagnostics and probe widths
- warmed timing capture for `prepare`, `layout`, and render
- line-height and vertical-metrics export
- ink-bounds extraction and normalization work
- an iOS demo-app benchmark screen in `Examples/PretextDemos`
  - single-text timings
  - corpus throughput timings
  - repeated vs uniqueness-forced corpus variants
  - bounded parallel-prepare experiments

Important library-facing changes made along the way:

- line-break and line-text materialization fixes needed for web parity
- broader URL-like merge behavior to match fixture expectations
- cache-key fixes so static and variable font assets do not collide in harness measurement caches
- swappable measurement behavior so the harness can use explicit fallback routing without polluting the default path

## Current iOS Harness Position

What is in good shape:

- iOS/web wrapping parity is strong on the pinned-font fixture cases
- Daze-suite wrapping parity is strong on the shared fixtures
- baseline parity is aligned in the vertical harness rows
- static Inter is aligned with web in the shared fixture path
- app-level parallel `prepare()` across messages has now been validated in the demo app as the main practical throughput optimization

What is still intentionally different:

- iOS uses `AppleColorEmoji`
- the shared web/Android harness uses `NotoColorEmoji`
- some remaining iOS/web difference is therefore expected emoji variance, not a parity failure
- iOS/web can still differ in painted ink-envelope height even when wraps and baselines align

## Current Performance Guidance

The most useful recent performance result is that message-level parallelization works well without needing more complicated library internals.

Practical guidance from the current demo-app benchmark screen:

- keep `prepare()` off the main thread
- parallelize across messages, not within one message
- use a bounded worker pool
- default to `4` workers
- consider `8` workers only for large cold distinct batches

Why `4` is the default:

- it gives strong speedups on both repeated and uniqueness-forced corpus loads
- it remains better than `8` on many warm/repeated runs where overhead starts to dominate

Why `8` is still worth keeping in mind:

- it can materially improve large, truly cold, distinct-message corpus loads

So the policy is not “always use 8”; it is:

- `4` as the general app default
- `8` as a cold-start override if the app can detect that workload

## Files To Know

- [Tests/PretextKitTests/FixtureHarnessTests.swift](../Tests/PretextKitTests/FixtureHarnessTests.swift)
  - main iOS fixture exporter
- [Sources/PretextKit/Pretext.swift](../Sources/PretextKit/Pretext.swift)
- [Sources/PretextKit/LineBreak/LineBreaker.swift](../Sources/PretextKit/LineBreak/LineBreaker.swift)
- [Sources/PretextKit/Measurement/SegmentMeasurer.swift](../Sources/PretextKit/Measurement/SegmentMeasurer.swift)
- [Sources/PretextKit/Measurement/GraphemeMeasurement.swift](../Sources/PretextKit/Measurement/GraphemeMeasurement.swift)
- [Sources/PretextKit/Measurement/SegmentMetricsCache.swift](../Sources/PretextKit/Measurement/SegmentMetricsCache.swift)
- [Sources/PretextKit/Options.swift](../Sources/PretextKit/Options.swift)
- [Examples/PretextDemos/PretextDemos/BenchmarkView.swift](../Examples/PretextDemos/PretextDemos/BenchmarkView.swift)
  - iOS demo-app benchmark surface for simulator/device runs

## Resume Commands

- `swift test`
- `xcodebuild test -scheme PretextKit -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' -only-testing:PretextKitTests/FixtureHarnessTests/testExportSharedFixtures`

The exported JSON is consumed by the shared comparison tooling, so the usual follow-up is:

- regenerate iOS fixture results
- run the shared comparison and summary scripts from the workspace that owns the fixture contract

## Constraint To Keep In Mind

Downstream comparison docs and summaries may assume the iOS fixture results came from `daze/custom-harness`. The same is now true for the iOS demo-app benchmark guidance:

- the benchmark screen
- the parallel corpus experiments
- the worker-count recommendation

all currently live on `daze/custom-harness`.

If iOS branch state changes in the future, update this file and any downstream comparison docs that depend on this harness.
