# Klik Studio: research and plan

Written 2026-09-29 on branch `feat/studio`.

| # | Document | What it answers |
|---|---|---|
| 1 | [Market research](01-market-research.md) | Who the competitors are, what each offers, what their users complain about |
| 2 | [Gap analysis](02-gap-analysis.md) | What nobody does well, what we lack, where we are already ahead |
| 3 | [Feature list](03-feature-list.md) | Every feature found, with our status and the phase it is planned for |
| 4 | [Architecture](04-architecture.md) | How the app is built, the rules that keep it correct, how each planned feature fits |
| 5 | [Roadmap and tasks](05-roadmap.md) | The phases and the task list, with what is done |
| 6 | [Quality log](06-quality-log.md) | Every bug found, how it was measured, what fixed it |
| 7 | [Working notes](07-working-notes.md) | The rules of the design, the style, how to build, test and drive the app |

Full research reports with sources are in [`docs/research/`](../research/).

## In one paragraph

Auto zoom, a smooth pointer and nice backgrounds are now a commodity: a $35 tool and several free ones have them. What no competitor delivers is **reliability** (every one has open bugs for lost takes, drift, or preview that does not match export) and **enough editing that nobody has to leave** (annotations, more than one blur, blur that follows content, several clips). Klik Studio is native, local and built around one clock and one renderer, which is the right base for both. The plan is: fix correctness first and prove it by measurement, reach parity with Screen Studio, then build what the market is missing.

## Measuring tool

```
cd Tools/studio-lab && swift build
.build/debug/studiolab pointer --target display   # or area, window
.build/debug/studiolab stream
.build/debug/studiolab press "pid:<Klik's pid>" "Add Zoom at Playhead"
.build/debug/studiolab shot "pid:<Klik's pid>" /tmp/editor.png
```

`pointer` and `stream` cover the screen and move the pointer for about 25 seconds. `press`, `key` and `shot` do not touch the screen or the pointer.
