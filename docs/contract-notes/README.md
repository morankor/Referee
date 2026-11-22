# Contract notes

One notes file per step of the plan (`plan.md` §11.2), written by the agent that did the step and read by the integrators at the gates. The agents cannot talk to each other; these files are how a problem found in one worktree reaches the person who can fix it for everyone.

## File names

`<step id>-<name>.md`, lower case: `wp0a-scaffold.md`, `wp0b-testsupport.md`, `gate0.md`, `wp1-papertext.md`, …, `gate1.md`, `wp9-reader.md`, …, `wp13-integration.md`. A step may add other files the plan asks it to save here (for example `wp5-grok-help.txt`).

## What a notes file contains

1. **Decisions.** Anything the plan did not specify and you decided inside your own files (plan §0).
2. **Contract problems.** Use exactly this heading. A shared contract that is wrong, contradicts itself, or lacks something you need: what the problem is, where the plan states it (section, file), and the workaround you built inside your own target. If there are none, write "None".
3. **Acceptance.** The acceptance commands of your work package, as you ran them at your last commit, each with its final line of output.
4. For the UI packages: what you saw in each snapshot scene you own, and anything that looks wrong but lies outside your files (plan §10.1).

## Rules

- A frozen path is read-only (plan §11.2): `Package.swift`, `Makefile`, `scripts/`, `.gitignore`, `Sources/RefereeCore/`, `Sources/TestSupport/`, `Sources/Composition/`, `Sources/Referee/`, `Sources/RefereeUI/Common/`, `Tests/RefereeCoreTests/`, `Fixtures/`. If one of them is wrong, do not edit it: implement what you need inside your own target, keep the public shape, and record it under "Contract problems". Gate 1 and the final integration resolve these and update `plan.md` in the same commit.
- Wave 0 (WP0a, WP0b) and Gate 0 work before the freeze and fix shared code directly; their notes say what was changed and why.
- Nothing confidential or personal goes into a notes file: no manuscript text, no file names of real manuscripts, no personal names or email addresses, no absolute home-directory paths, no API keys. When you quote a tool's output, remove account fields first.
