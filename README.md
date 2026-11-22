# Referee

A macOS PDF reader for peer review: the manuscript on the left, AI-drafted referee comments in a sidebar to approve, reject, discuss or add to, questions about any highlighted passage, clickable citations that open the cited paper, and a generated referee report to edit and export.

**Status: scaffold.** The package builds, every target exists with its public surface, and the implementations behind that surface are placeholders. `plan.md` is the implementation plan and the single source of truth; its §11 lists the work packages that fill the placeholders in. This README covers building and testing only. The user's guide (installation, providers, privacy, troubleshooting) is written at the end of the work (plan §11.5).

## Requirements

- macOS 26 on Apple silicon.
- Command Line Tools 26.6 (Swift 6.3). Xcode is not needed.
- Nothing else: the package has no third-party dependencies, so it builds offline.

## Commands

Run them from the repository root. These are the only commands used in this project (plan §3.4).

| Purpose | Command |
|---|---|
| Build everything (debug) | `scripts/build.sh` |
| Build one product | `scripts/build.sh --product referee-cli` |
| Run all tests | `scripts/test.sh` |
| Run one test target | `scripts/test.sh --filter PaperTextTests` |
| Run the app unbundled | `scripts/run.sh [app arguments]` |
| Assemble and sign the app | `scripts/bundle.sh`, which makes `build/Referee.app`; then `open build/Referee.app` |
| Render UI snapshots | `scripts/snapshots.sh [--out dir] [--scene name]…` |
| Real local-LLM end-to-end | `scripts/e2e-ollama.sh [model]` |
| Regenerate fixture PDFs | `scripts/make-fixtures.sh` (needs MacTeX) |
| Fetch optional real papers | `scripts/fetch-optional-fixtures.sh` (network; public arXiv PDFs into `Fixtures/private/`) |

`make build`, `make test`, `make run`, `make app`, `make snapshots`, `make e2e` and `make fixtures` call the same scripts.

What works at this stage:

- `build.sh`, `test.sh`, `run.sh`, `bundle.sh` and `make-icon.sh` work. `run.sh` opens an empty welcome window; quit it with ⌘Q.
- `snapshots.sh` runs but captures nothing yet: the snapshot runner is written in the next step (WP0b), and until then the script exits with an error.
- `make-fixtures.sh` arrives with WP0b; `e2e-ollama.sh` and `fetch-optional-fixtures.sh` arrive with Gate 1.

Rules that keep builds and tests reliable:

- Never run bare `swift test`. Under the Command Line Tools it cannot find the Swift Testing framework; `scripts/test.sh` passes the flags it needs and fails when zero tests ran, so a mistyped `--filter` cannot look green.
- Do not add flags, resources or dependencies to `Package.swift`. In particular the test flags must stay on the command line: in the manifest they make the test run report success without running anything (plan §3.1).
- Build only into the default `.build` folder of your own checkout. Do not pass `--scratch-path` or `--build-path`, and do not run `swift package clean`, `reset` or `update`.
- Tests never touch the Keychain, `~/Library/Application Support/Referee` or a vendor CLI's state. Code that needs a data folder gets it from `REFEREE_HOME`, which tests set to a temporary directory.

`scripts/bundle.sh` reads two optional environment variables: `REFEREE_VERSION` (default `0.1.0`) and `REFEREE_SIGN_IDENTITY` (default: ad-hoc signing).

## Layout

```
Package.swift   Makefile   README.md   plan.md
scripts/        the commands above, and make-icon.sh (app icon; called by bundle.sh)
docs/           plan-review.md, prototypes/, contract-notes/ (one notes file per work package)
Sources/        one folder per target (plan §2.1)
Tests/          one folder per test target
Fixtures/       synthetic manuscripts and recorded model output (added in WP0b)
build/          output of the scripts: the app, the icon, snapshots (not in git)
```

The targets and what each may import are in plan §2.1. The contracts every target is written against are in `Sources/RefereeCore` (plan Appendix A), and the public surface of every other target is in plan §11.3.
