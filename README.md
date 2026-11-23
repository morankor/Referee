# Referee

A Mac app for refereeing a paper. The manuscript sits in the middle of the window; an AI model drafts referee comments into a sidebar on the right, where you approve, reject, discuss, edit or add to them with single keys; you can ask about any passage you select; citations in the text open a card with the cited paper and, when one is free to read, its PDF; and at the end the app drafts a referee report from the comments you approved, which you edit and export.

You choose which AI does the reading: a model that runs on your Mac (Ollama, nothing leaves the computer), an API account (Anthropic, OpenAI, Google Gemini, xAI), or a subscription you already pay for through its command-line tool (Claude Code, Codex). The toolbar always shows where the text would go, and the first time a document would leave your Mac the app asks you.

`plan.md` is the full design. This README is the user's guide: how to build and install the app, the first run, setting up providers, what leaves your Mac, what to do when something does not work, and what still needs checking with your own accounts. The developer's notes are at the end.

## Contents

1. [What you need](#what-you-need)
2. [Build and install](#build-and-install)
3. [First run](#first-run)
4. [Working on a paper](#working-on-a-paper)
5. [Setting up AI providers](#setting-up-ai-providers)
6. [Privacy: what leaves your Mac, and when](#privacy-what-leaves-your-mac-and-when)
7. [Troubleshooting](#troubleshooting)
8. [Checks that need your accounts](#checks-that-need-your-accounts)
9. [Testing the text cleaning on journal-system PDFs](#testing-the-text-cleaning-on-journal-system-pdfs)
10. [For developers](#for-developers)

## What you need

- A Mac with Apple silicon running macOS 26.
- Apple's Command Line Tools 26.6 or later (Swift 6.3). Xcode is not needed. If `swift --version` in Terminal says the command is missing, run `xcode-select --install`.
- For a local model (recommended to start with): the Ollama app from ollama.com and one model, for example `gemma4:e4b` (the model used for the end-to-end tests of this project, on a Mac with 24 GB of memory).
- Optionally an API key from Anthropic, OpenAI, Google or xAI, or the Claude Code or Codex command-line tool signed in with your subscription.

The app has no third-party code and builds without a network connection.

## Build and install

In Terminal, from the folder that holds this README:

```bash
scripts/bundle.sh              # builds the app in release mode, signs it, and puts it in build/Referee.app (a few minutes the first time)
open build/Referee.app         # starts it
```

To keep it with your other apps, quit it and drag `build/Referee.app` into Applications in Finder (replace the old copy when asked), or in Terminal: `ditto build/Referee.app /Applications/Referee.app`. The app is built and signed on your own Mac ("ad hoc"), so macOS opens it without a warning.

To update after a change of the source, run `scripts/bundle.sh` again and copy the new app over the old one. Your reviews and settings are kept: they live in your Library folder, not in the app (see [Privacy](#privacy-what-leaves-your-mac-and-when)). After each rebuild macOS may ask once for permission to read your saved API keys; [Troubleshooting](#the-keychain-asks-for-permission-after-every-rebuild) says why and how to stop it.

You can also open a PDF directly: `open -a build/Referee.app paper.pdf`, or drag a PDF onto the app's icon or window.

## First run

The app opens with a welcome window: **Open PDF…**, a drop area for a PDF, your recent reviews (none yet), and at the bottom a line that says which AI is set up.

- If Ollama is running and has a model when you first start Referee, the app switches it on and makes it the default ("AI: Local · gemma4:e4b"). It never switches on a remote provider by itself.
- Otherwise the line reads "No AI provider set up — Open Settings". You can still open papers, read them, select passages, write your own comments and look up references; only the AI features wait for a provider.

Open Settings with **⌘,** to set up a provider ([below](#setting-up-ai-providers)). Help ▸ Referee Help lists the keys and commands and has a button that opens this README.

## Working on a paper

Open a PDF (**⌘O**, the welcome window, or drag it onto the app). Each paper gets its own window:

- **Left: the navigator.** Page thumbnails, the outline when the PDF has one, and **References**: the paper's reference list, each entry with an icon once it has been looked up. Toggle it with the toolbar button on the left or **⌃⌘S**.
- **Middle: the PDF.** Highlights mark the passages comments refer to (yellow pending, green approved, blue your own, purple a passage you asked about). Click a highlight to select its comment. Select text to get a small bar: **Ask AI**, **Comment** (your own comment on that passage), **Copy**, and quick questions. Click a citation such as "Acemoglu et al. (2011)" to open its card: the reference as printed, what the lookup found, and **Open PDF** (an open-access copy, in a viewer window), **Open in Browser**, **Copy DOI**, **Search Google Scholar**. **⌘F** finds text; **⌘+**, **⌘−**, **⌘0** zoom.
- **Right: the sidebar.** **Comments** (⌘1), **Chat** (⌘2) and **Report** (⌘3).
- **Toolbar:** where the text would go (the destination indicator, for example "Local · gemma4:e4b"; click it to choose another provider for this paper), **Review** (⌘R; it becomes Cancel with the progress while a review runs, ⌘. cancels), **Report**, and the sidebar toggle.

**Reviewing.** Press **⌘R**. Comments appear in the sidebar as the model writes them, sorted by their place in the paper. Then triage with single keys (they work while the PDF or the comment list has the keyboard, not while you type in a field):

| Key | Does |
| --- | --- |
| J / K | next / previous comment |
| A | approve, then move to the next undecided comment |
| R or X | reject, then move on |
| U | back to undecided |
| D | discuss the comment with the model (it can propose a revised comment, which you accept or discard) |
| E | edit the comment |
| N | a new comment of your own, on the selected text if there is any |
| Return | show the comment's passage in the PDF again |
| 1 2 3 4 | kind: major, minor, question, strength |
| Esc | close what is open (citation card, new comment, editor, discussion, find bar), then clear the selection |

Comments marked **≈** were matched to the PDF approximately; "p. 4" with a dotted underline means that the model named the page but its quote could not be located on it; "Passage not found" means the model quoted something that is not in the paper (attach it to a selection with the card's button, or delete it). A small **verify** tag marks comments about missing literature: the model cannot look papers up, so check any paper it names.

**The report.** In the Report tab, add the target journal and any notes for the report, then **Generate**. The report is written from the comments you approved. Edit it in place (Preview shows it formatted), use **Revise Voice** to make it sound less machine-written, and **Export ▾** as Markdown, plain text, Word or PDF (or File ▸ Export Report…, **⇧⌘E**). The **Style check** list under the text flags phrases referees often regret (em dashes, "robust" used loosely, and the like); click one to select it.

Everything is saved as you work. Reopening a paper (the same file, even renamed or moved) brings back its comments, discussions and report.

## Setting up AI providers

Open **Settings ▸ Providers** (**⌘,**). The list has three groups; each row has a switch, a coloured status dot (green ready, yellow needs set-up with the reason, red unavailable with the reason) and, on the right, the details. At the bottom choose the default provider for reviews, chat and reports. You can also choose a provider per paper from the toolbar's destination indicator.

### Local: Ollama (nothing leaves your Mac)

1. Install the Ollama app from ollama.com and start it (a llama appears in the menu bar).
2. In Terminal: `ollama pull gemma4:e4b`.
3. In Settings ▸ Providers ▸ Ollama (local): switch it on and choose the model.

`gemma4:e4b` reads a typical paper in one pass. Smaller-context models such as `phi4` read a long paper in parts and then make a whole-paper pass; this works but takes longer (about ten minutes for a 16-page paper on a 24 GB Mac). A local model's comments are weaker than a large hosted model's; the app's job is the same either way.

### API keys: Anthropic, OpenAI, Gemini, xAI

1. Create a key in the vendor's console (each vendor bills per token on your API account).
2. In Settings ▸ Providers, choose the provider, paste the key into its field and switch it on. The key is stored in your macOS Keychain (one item, "local.referee.app"), never in a file, and is sent only to that vendor.
3. Choose a model (the list comes from the vendor; **Show all models** for OpenAI and Gemini lists the ones filtered out).
4. Press **Send Test Prompt** (see below).

Anthropic, OpenAI and Gemini receive the PDF itself, so equations and tables reach the model intact. xAI and Ollama receive the extracted text; the toolbar then says "text only", and the app warns that equations and tables may reach the model garbled. You can force either mode per provider under **Advanced ▸ Input mode** (a protected PDF, or one too large for the provider, goes as text).

### Subscriptions through an installed command-line tool: Claude Code, Codex

These use the subscription you already pay for (Claude Pro or Max; a ChatGPT plan). Referee runs the vendor's own program, which signs in with its own credentials; Referee never sees or stores them. Install and sign in once in Terminal (Settings shows the same commands, with a Copy button):

| Provider | Install | Sign in |
| --- | --- | --- |
| Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` | run `claude` and type `/login` |
| Codex (ChatGPT plan) | `npm install -g @openai/codex@latest` (the ChatGPT app's own copy also works) | `codex login` |
| Antigravity (Google AI plan), experimental | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | follow the tool's own sign-in |
| Grok Build (xAI), experimental | `curl -fsSL https://x.ai/cli/install.sh \| bash` (the installer on xAI's own site) | `grok login` |

xAI also lists an npm package, `@xai-official/grok`. When Referee was built, that package named no source repository or homepage, so it could not be confirmed as xAI's and was not installed; prefer the installer above.

Then switch the provider on in Settings and press **Send Test Prompt**. Referee finds the program in the usual places (or set **Path** to point at it) and checks that the installed version still has the safety options it needs; if one is missing, the provider shows red with the reason, and stays off. Claude Code receives the PDF itself and Codex receives it as page images (both were tried with the invented fixture paper); Antigravity and Grok Build receive the extracted text.

These tools are AI agents that can normally run commands and edit files. Referee runs them with every tool switched off that the tool allows, in an empty temporary folder, and stops the run at once if the model tries to use a tool ([Privacy](#privacy-what-leaves-your-mac-and-when) has the details per tool). Using a subscription through a third-party app is governed by each vendor's terms; Referee only launches your own installed tool for your own work. Keep this to personal use.

### What "experimental" means

Antigravity and Grok Build are marked **experimental**. Their adapters were written from the vendors' documentation; neither program was installed on the Mac where Referee was built, so **neither has ever been run against the real program**. Settings shows "Experimental — not yet verified against the real CLI on this machine" in orange under the name, and the toolbar adds "· experimental". If the real program's options differ from the documentation, the provider will most likely show red with a reason ("does not list the option …"): that is the safe outcome, not a bug. Do not use them on a confidential manuscript until a test prompt has succeeded and you have tried a non-confidential paper.

### The Send Test Prompt button

**Send Test Prompt** sends the single message "Reply with exactly: OK" to the provider and shows the answer. It costs a few tokens on an API account, or one message of your subscription. When it succeeds, Referee records the date, and for an experimental provider the warning disappears. Use it once after setting up each provider. Nothing else in Settings sends a prompt; fetching a model list sends your key to its vendor and nothing of any paper.

### Each paper, the first time

The first time anything of a paper would go to a provider that is not on your Mac, a card asks you: what will be sent (the PDF, or the extracted text), how many requests, about how many tokens, and to which address. **Send** remembers your answer for that paper and provider; tick **Ask again next time** to be asked every time. **Local only** (Settings ▸ Privacy, or the destination menu) blocks every remote provider altogether.

Check the journal's policy on AI tools before sending a manuscript under review. Some journals forbid it; a local model keeps the manuscript on your Mac.

## Privacy: what leaves your Mac, and when

| What | Goes to | When |
| --- | --- | --- |
| The PDF, or its extracted text | the provider shown in the paper's toolbar | only when you start a review, send a discussion message, ask a question, or generate or revise the report; the first time per paper and provider only after you agree |
| Your approved comments, discussions, notes for the report | the same provider | with those same actions |
| The text or identifier of one reference | Crossref and OpenAlex (public bibliographic services) | when you click that citation, or that entry in References; if you switch off "Look up references only when I click them" (Settings ▸ References), every reference of a paper as soon as it opens |
| A request for an open-access PDF | the site that hosts it | when you click Open PDF on a citation card |
| An API key | its own vendor only | with each request to that vendor, including fetching its model list |
| Anything else | nobody | no telemetry, no update checks, no crash reports |

With Ollama on your Mac and no citation clicked, the app connects to nothing but `127.0.0.1` (your own Mac). File names are never logged and never sent: a provider receives the file as "manuscript.pdf". The app's log (`log show --predicate 'subsystem == "local.referee.app"'`) holds counts and identifiers, never manuscript text.

**What the providers keep.** OpenAI and Gemini requests are sent with storage switched off; xAI's endpoint stores nothing; Anthropic's API keeps requests under your API account's data terms. Claude Code runs without saving a session; Codex runs with an ephemeral session, though Codex keeps its own log database under `~/.codex` whose contents were not examined. Antigravity may keep a local conversation record. Grok Build saves every conversation under `~/.grok` and may sync it to your xAI account; Referee deletes the local copy after each run but cannot undo a sync.

**What a manuscript can make a model do.** A manuscript is someone else's text and could contain instructions aimed at a model ("ignore your instructions and …"). Through an API key or Ollama the model can only return text: no tools are offered. Claude Code runs with no tools and no extensions at all, and Referee checks that on every run. Codex runs with its shell and agent tools removed and a read-only sandbox; one built-in code tool cannot be removed, and if the model uses any tool Referee stops the run, though it may learn of the tool only after it ran. Antigravity's tools cannot be switched off (they need approvals nobody gives, file writes stay inside an empty temporary folder, and Referee stops the run at the first tool step). Grok Build runs in its strictest sandbox with every permission denied. For Antigravity and Grok Build none of this has been tested against the real program. In every case the model's output is treated as untrusted text: nothing it writes is run, fetched or opened automatically, and links in comments are not clickable. The worst a successful injection can do through an API provider is distort comments that you then read and triage.

**What stays on your Mac.** Each paper's review (comments with quotes from the manuscript, discussions, report, reference lookups) is in `~/Library/Application Support/Referee/sessions/`, in a folder named after the file's fingerprint, not its name. Downloaded reference PDFs are in `~/Library/Caches/Referee/papers/`. File ▸ Delete Review Data… removes one paper's folder; Settings ▸ Privacy ▸ Delete all review data removes them all; Settings ▸ References clears the downloads. The command-line tools write their own files on their own account, outside Referee's control. Referee never modifies your PDF. It needs no special permissions (no Accessibility, Screen Recording or Full Disk Access).

## Troubleshooting

### Codex shows "not installed", "unavailable" or fails at once

On the Mac where Referee was built, the copy of Codex installed by Homebrew or npm at `/opt/homebrew/bin/codex` was broken: it exits with an error immediately. Referee tests every copy it finds and skips a broken one (it uses the copy inside the ChatGPT app if you have that). To repair the command-line copy:

```bash
npm install -g @openai/codex@latest
codex --version        # should print a version number
codex login            # sign in with your ChatGPT account
```

Then press the refresh button next to Codex's status in Settings ▸ Providers. If you keep several copies, set **Path** in Codex's row to the one you want.

### The Keychain asks for permission after every rebuild

Each `scripts/bundle.sh` signs the app "ad hoc", which gives every build a new identity. macOS then asks whether Referee may read the Keychain item "local.referee.app" where your API keys are; answer **Always Allow** (it asks for your login password). Until you answer, the API providers show "The saved key could not be read from the Keychain", and Referee refuses to save a new key, so that the keys already stored cannot be overwritten by accident.

To stop the question, sign the app with a certificate of your own, once:

1. Open **Keychain Access**, then Keychain Access ▸ Certificate Assistant ▸ **Create a Certificate…**
2. Name: `Referee Local Signing`; Identity Type: **Self-Signed Root**; Certificate Type: **Code Signing**; **Create**.
3. Build with it from now on:

   ```bash
   REFEREE_SIGN_IDENTITY="Referee Local Signing" scripts/bundle.sh
   ```

The first launch with the new signature asks one last time; later rebuilds keep the same identity and should not ask. (macOS may also ask whether `codesign` may use the certificate's key: Always Allow.) This option is reasoned from how macOS identifies signed apps and was not tried during the build.

### "Ollama is not running", or a review fails at once with Ollama

- Start the Ollama app, or run `ollama serve` in Terminal. Check it with `curl http://127.0.0.1:11434/api/version` (it answers with a version number).
- "No model": `ollama pull gemma4:e4b`, then choose the model in Settings ▸ Providers ▸ Ollama.
- The toolbar's indicator does not test whether Ollama is running (that would cost a request each time); it keeps showing "Local · gemma4:e4b", and the review then stops with a banner that says why. Start Ollama and run the review again (**Retry** on the banner, or ⌘R).
- The first request after starting Ollama loads the model and can take a minute.

### Other messages

- **"This PDF has no text layer"**: a scanned PDF. Comments can be tied to pages only, and only providers that receive the PDF itself (Anthropic, OpenAI, Gemini, Claude Code, Codex) can review it.
- **"This PDF is protected"**: the text is readable, so reviews send the text, not the file.
- **A CLI shows red: "… does not list the option …"**: the installed version lacks a safety option Referee requires. Update the tool (the install commands above install the latest version).
- **"Remote providers are blocked by Local only"**: Settings ▸ Privacy ▸ Local only is on.
- **A citation card says "No match found"**: Crossref and OpenAlex do not know the reference (common for working papers and books). Search Google Scholar is one click away on the card.

## Checks that need your accounts

These were **not** run while building Referee, because each needs your accounts or costs money. Everything else was tested: more than 980 automated tests, the app's own screenshots of every window state, and complete reviews with two local Ollama models. No paid API was ever called. The only prompts sent through a subscription were the ones plan §11.6 allows, through Claude Code and through Codex: the test prompt "Reply with exactly: OK" twice each (while the command-line support was built, and at the end; `docs/contract-notes/wave3.md` has the last results), and one run each of an experiment that handed them the invented four-page fixture paper, to learn whether they can read the PDF itself (they can).

Use a non-confidential PDF for each, for example `Fixtures/pdf/ay_round_nolinks.pdf` from this folder (an invented four-page paper) or a published paper of your own:

- [ ] **Anthropic API**: set the key, Send Test Prompt, then one full review.
- [ ] **OpenAI API**: the same.
- [ ] **Gemini API**: the same.
- [ ] **xAI API**: the same.
- [ ] **Claude Code**: one full review (only the test prompt has been run).
- [ ] **Codex**: one full review (only the test prompt has been run).
- [ ] **Antigravity** and **Grok Build**, if you install them: Send Test Prompt first. Both are experimental and were never run against the real programs; expect the first try to fail with a reason, and tell whoever maintains the app what it said.
- [ ] **The signing certificate** of the Keychain section, if you use it: rebuild twice and confirm that the second rebuild does not ask.

For each review, check that comments arrive, that most of them are tied to the right passage (highlighted in the PDF), and that the report generates. The command-line version gives a one-line summary per run, for example `"$(swift build --show-bin-path)"/referee-cli review Fixtures/pdf/ay_round_nolinks.pdf --provider anthropic-api` with the key in `REFEREE_KEY_ANTHROPIC_API` (provider names: `anthropic-api`, `openai-api`, `gemini-api`, `xai-api`, `claude-cli`, `codex-cli`, `antigravity-cli`, `grok-cli`, `ollama`; build it first with `scripts/build.sh`).

## Testing the text cleaning on journal-system PDFs

Journal systems stamp review copies with line numbers in the margin, running headers ("Page 3 of 34", the journal's name), footers and watermarks ("For Peer Review"). Referee removes these before a model sees the text and still uses the line numbers for locations such as "p. 4, lines 14–16". It was built and tested on synthetic PDFs that imitate Editorial Manager and ScholarOne, but never on a real one.

To check it on real ones, put a few non-confidential PDFs built by those systems (your own past submissions, for example) into `Fixtures/private/journal/`. That folder is never committed to git. Then:

```bash
scripts/build.sh
scripts/test.sh --filter IntegrationRealPaperTests                                   # the whole pipeline on each PDF there
"$(swift build --show-bin-path)"/referee-cli extract Fixtures/private/journal/paper.pdf --stats   # what was recognised as line numbers, per page
"$(swift build --show-bin-path)"/referee-cli extract Fixtures/private/journal/paper.pdf           # the cleaned text a model receives
```

If line numbers or stamps survive in the cleaned text, or real text disappears, note what happened for whoever maintains the app. Meanwhile, Settings ▸ Advanced ▸ "Remove margin line numbers from extracted text" set to **Never** stops the removal of margin numbers for papers opened afterwards.

## For developers

`plan.md` is the single source of truth for the design; `docs/contract-notes/` has one notes file per step of the build (`wave3.md` is the last). The targets and what each may import are in plan §2.1, the shared contracts in `Sources/RefereeCore` (plan Appendix A), and the public surface of every other target in plan §11.3.

### Commands

Run them from the repository root. These are the only commands used in this project (plan §3.4).

| Purpose | Command |
| --- | --- |
| Build everything (debug) | `scripts/build.sh` |
| Build one product | `scripts/build.sh --product referee-cli` |
| Run all tests | `scripts/test.sh` (run `scripts/build.sh` first: the integration tests run the built `referee-cli`) |
| Run one test target | `scripts/test.sh --filter PaperTextTests` |
| Run the app unbundled | `scripts/run.sh [PDF]` |
| Assemble and sign the app | `scripts/bundle.sh`, which makes `build/Referee.app` (`REFEREE_SIGN_IDENTITY`, `REFEREE_VERSION` optional) |
| Render UI snapshots | `scripts/snapshots.sh [--out dir] [--scene name]… [--dark] [--size WxH]` |
| Real local-LLM end-to-end | `scripts/e2e-ollama.sh [model] [pdf] [--expect-parts]` |
| Regenerate fixture PDFs | `scripts/make-fixtures.sh` (needs MacTeX) |
| Fetch optional real papers | `scripts/fetch-optional-fixtures.sh` (network; public arXiv PDFs into `Fixtures/private/`) |

`make build`, `make test`, `make run`, `make app`, `make snapshots`, `make e2e` and `make fixtures` call the same scripts.

- `snapshots.sh` makes the app draw each window state off screen and capture its own window (no Screen Recording permission needed; a corner of the window shows at the edge of the screen while a scene runs). It writes one PNG per scene and a line per scene in `manifest.jsonl`. Three scenes, `check-document-loaded`, `check-citation-click` and `check-triage-keys`, check that the panes are connected rather than how they look.
- `referee-cli` runs the app's pipeline without the UI (plan §10.2): `providers`, `dump-raw`, `extract`, `anchor`, `citations`, `plan`, `review`, `ask`. `referee-cli review Fixtures/pdf/ay_round_nolinks.pdf --provider mock` needs no set-up. It uses a temporary data folder unless given `--home`, and keys from `REFEREE_KEY_*` variables only unless given `--use-keychain`.
- `e2e-ollama.sh` reviews a fixture with a local Ollama model and asks one question about it, at no cost.

### Rules that keep builds and tests reliable

- Never run bare `swift test`. Under the Command Line Tools it cannot find the Swift Testing framework; `scripts/test.sh` passes the flags it needs and fails when zero tests ran, so a mistyped `--filter` cannot look green.
- Do not add flags, resources or dependencies to `Package.swift`. The test flags must stay on the command line: in the manifest they make the test run report success without running anything (plan §3.1).
- Build only into the default `.build` folder of your checkout. Do not pass `--scratch-path` or `--build-path`, and do not run `swift package clean`, `reset` or `update`.
- Tests never touch the Keychain, `~/Library/Application Support/Referee` or a vendor CLI's state; they set `REFEREE_HOME` to a temporary folder. The default run sends nothing to a subscription CLI or a paid API (it sends one short prompt to the smallest local Ollama model when Ollama is running). Opt-in only: `REFEREE_CLI_SMOKE=1` (one test prompt per signed-in CLI, plan §11.6), `REFEREE_LIVE_NET=1` (the public reference services), `REFEREE_TEST_KEYCHAIN=1` (a throwaway Keychain item); `REFEREE_CLI_EXPERIMENT` is for the coordinator only (plan §10.6).
- No `#file`, `#filePath`, `fatalError`, `precondition`, `preconditionFailure` or `assertionFailure` in `Sources/`: they put the source path into a release binary, which `scripts/bundle.sh` refuses (plan §3.7; a test checks).

### Layout

```text
Package.swift   Makefile   README.md   plan.md
scripts/        the commands above, and make-icon.sh (app icon; called by bundle.sh)
docs/           plan-review.md, prototypes/, contract-notes/ (one notes file per step of the build)
Sources/        one folder per target (plan §2.1)
Tests/          one folder per test target
Fixtures/       synthetic manuscripts (LaTeX sources, PDFs, raw dumps), model outputs for the mock, sample sessions;
                private/ (not in git) for real papers, private/journal/ for journal-system PDFs
build/          output of the scripts: the app, the icon, snapshots (not in git)
```
