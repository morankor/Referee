# WP4 — LLMKit

Notes of the LLMKit work package (`plan.md` §11.4, WP4): the five HTTP providers (Anthropic, OpenAI, Gemini, xAI, Ollama), streaming, retry, model lists and the Keychain secret store. Read by Gate 1.

## What exists after this step

| Part | Files in `Sources/LLMKit` |
| --- | --- |
| Shared machinery of §5.3 | `HTTPStreamClient` (lines through `LineSplitter`, `json(for:)`, URLError translation), `HTTPFailure` (+ `RetryAfter`, `VendorError`), `HTTPProviderAdapter` (the four functions of §5.3 plus defaults), `StreamState`, `SSE`, `JSONValue`, `HTTPRequests`, `Endpoint`, `ModelLists` |
| Providers | `HTTPProvider` (one `LLMProvider` per adapter; `AttemptReader` turns one response into events) and `AnthropicAdapter`, `OpenAIAdapter`, `GeminiAdapter`, `XAIAdapter`, `OllamaAdapter` |
| Retry (§5.7) | `RetryPolicy` (injectable `sleep` and `random`), `RetryingReader` |
| Secrets (§5.8) | `KeychainSecretStore` over the internal `KeychainBackend`; `SecurityKeychainBackend` is the real one |
| Public surface | Exactly §11.3: `LLMKitFactory.makeProviders(environment:)` (order anthropic-api, openai-api, gemini-api, xai-api, ollama) and `KeychainSecretStore(service:account:)`. `UnimplementedHTTPProvider.swift` is deleted |

How a stream works: `stream(_:)` returns an `AsyncThrowingStream(unfolding:)` whose elements are produced in the consumer's task, one `next()` at a time, through three readers (retry → attempt → lines). It is cold (settings and key are read, and the request is built, when the first element is asked for, and again for each attempt), it stops reading at the first `.finished`, and cancelling the consumer cancels the `URLSession` task (the reader that owns it cancels it when released). As Gate 0 warned, a consumer cancelled between two elements sees the stream end silently; one cancelled during a read or a retry wait gets `LLMError.cancelled`.

## Decisions

Things the plan left open, decided inside `Sources/LLMKit`.

1. **Model and limits.** The model is `request.model`, else `ProviderSettings.model`; with neither, `.notConfigured("no model is chosen for …")` before any request. `max_tokens` / `max_output_tokens` / `num_predict` use `request.maxOutputTokens`, else `ProviderSettings.maxOutputTokens` (the Advanced setting would otherwise do nothing), else the vendor rule of §5.4. Anthropic's `min(model.maxOutputTokens ?? 16_000, 32_000)` takes the model's limit from `settings.cachedModels` (the adapter has no other source).
2. **Ollama `num_ctx`** is `request.contextWindow`, else `contextWindowOverride`, else 4,096 (only callers that bypass the engine, such as a test prompt, reach the fallback). The "context full" status compares with the `num_ctx` actually sent.
3. **Keys.** The key is trimmed; an empty or blank key is no key. A key the store cannot read (`SecretError`) becomes `.notConfigured("the saved API key could not be read from the Keychain")`, since providers throw only `LLMError`. Any occurrence of the key in a vendor's error message is replaced by `••••`. Keys go only in the vendor's header.
4. **Availability of API providers** sends nothing: `.ready("Key set")` with a key, `.needsSetup("No API key", …)` without, `.needsSetup(…, "Allow access when macOS asks for it, then try again.")` when the key cannot be read, `.unavailable` for a base URL that is not an address. Ollama: `.ready("Ollama <version>")`, `.needsSetup("Ollama is not running", …)` on a refused connection, `.unavailable("Ollama at <host:port> did not answer.")` otherwise.
5. **Base URL.** An override without a scheme gets the endpoint's (`192.168.1.5:11434` → `http://…`); its path and query are ignored (§5.3 replaces scheme, host and port only); anything that is not http or https is `.invalidRequest` without a request. `descriptor` is computed from the settings at each call: `destination` follows the base URL, and for Ollama so do `isLocal` (only 127.0.0.1, localhost, ::1) and the retention note ("Sent to <host> on your network.").
6. **Bodies.** Empty `.text` parts are skipped and an empty system prompt leaves its field out (Anthropic rejects empty text blocks). Anthropic honours the first `.cacheBoundary` only and ignores one with no block before it. `extraBodyJSON` that is not a JSON object is ignored silently; its keys are not filtered (a user who adds `temperature` for Anthropic gets the vendor's 400).
7. **Stream details.** Empty deltas are dropped. The stream ends at the first `.finished`; bytes after it are not read. Anthropic's input tokens add `cache_creation_input_tokens` and `cache_read_input_tokens` to `input_tokens` (otherwise a cached review reports a few dozen input tokens); the Appendix D numbers are unchanged. OpenAI's collected refusal text decides `.refusal` and is not passed on. A terminal event without a stop reason is `.endOfTurn`. An xAI chunk with an `error` field, which xAI does not document, is `.server(500)`. Lines that are not JSON are ignored, so garbage ends as `.malformedResponse("stream ended early")`.
8. **Error mapping, where the table is silent.** Anthropic: any 4xx not in the table → `.invalidRequest`, any 5xx → `.server`; in-stream `error` events map by `error.type` (`api_error` and unknown types → `.server(500)`). OpenAI: a 503 without `server_is_overloaded` → `.server(503)` (the table names the code); in-stream codes: quota codes → `.quotaExhausted`, `rate_limit_exceeded`, `server_is_overloaded`, `context_length_exceeded`, `model_not_found`, `invalid_api_key`, other `invalid_*` → `.invalidRequest`, the rest → `.server(500)`. Gemini: a body without a string `code` (Google's numeric `code` repeats the status) maps by status (401/403 auth, 404 model, 429 rate, 503 overloaded, other 4xx invalid, else server); in-stream errors carry status 500. xAI and Ollama: other 4xx → `.invalidRequest`. Messages are the vendor's own, trimmed to 500 characters; without one, "HTTP <status>".
9. **Retry.** A `Retry-After` is honoured for `.overloaded` as for `.rateLimited` (`LLMError.overloaded` carries it, and OpenAI sends it on 503). `Retry-After` is read as seconds or as an HTTP date. The status reads `Retrying in N s (rate limited | overloaded | server error 503 | network error)`, N rounded, at least 1. Each retry logs `llm.retry` with `provider`, `attempt`, `reason`. Model lists are not retried.
10. **Models.** OpenAI ties on `created` are broken by id. Ollama asks `/api/show` when an entry lacks the context length or the capabilities; a failing `/api/show` lists the model without a context window. Models without the `completion` capability are hidden always (an embedding model cannot review), not only when "Show all" is off. Pagination stops at a repeated token or after 50 pages.
11. **Keychain.** The item lives in the login keychain (no data-protection keychain: an ad-hoc-signed app has no entitlements). `setSecret` reads the item afresh every time; `secret(for:)` keeps what it last read or wrote, so that four providers asking for their keys on every availability check and request do not make macOS ask again and again after a rebuild (a failed read is not kept). `setSecret("")` deletes like `nil`. An item whose value is not a JSON object of strings is `.unreadable(status: errSecDecode)` and is never overwritten. When the last key is removed the item stays, holding `{}`. Logged: `secrets.unreadable` and `secrets.write.failed` with the status only.
12. **Logging** of a request is exactly `llm.request` with `provider`, `bytes`, `pdf` (a test pins the field set).

## Contract problems

1. **Data files in a test target make SwiftPM warn, and the manifest is frozen.** §11.2 ("Test data private to a target goes in `Tests/<Target>Tests/Fixtures/`") and WP4 ("stream bodies … saved under `Tests/LLMKitTests/Fixtures/`") meet §3.2 (no `resources:`, manifest frozen): any non-Swift file in a target folder that the manifest neither declares nor excludes gives `warning: 'wp4-llmkit': found N file(s) which are unhandled; explicitly declare them as resources or exclude from the target`, on every build that reloads the package graph (measured here with `.sse` files). *Done here:* the Appendix D bodies are Swift raw strings in `Tests/LLMKitTests/Fixtures/AppendixDStreams.swift` (generated from the plan by a script; byte-identical to the five blocks of D.1–D.4, checked by comparison), the variants and model lists in `AppendixDVariants.swift`. *Suggested for Gate 1:* other packages will hit the same warning (WP5's fake CLIs are shell scripts by design); add `exclude: ["Fixtures"]` (or the folder they use) to those test targets only. Do not exclude `Fixtures` from `LLMKitTests`: its fixtures are sources.
2. **"Show all" has no way through `LLMProvider`** (§5.4.2, §5.4.4 and §9.6 against A.5: `listModels()` takes no argument). *Done here:* `listModels()` applies the filters; `HTTPProvider.listModels(showAll:)` (internal) returns everything, tested. *Suggested:* a protocol requirement such as `func listModels(includeHidden: Bool) async throws -> [ModelInfo]` with a default implementation in an extension that calls `listModels()` (so CLI providers and the fakes need no change), or a `ProviderSettings` flag read at call time. Until then the Settings pane's "Show all" cannot work; "Custom…" still lets the user type any id.

## For Gate 1

- `TimedOut` is LLMKit's internal marker for `URLError.timedOut` (never retried); consumers see `.network("the provider sent nothing for too long, so the request timed out")`.
- Gemini's `/v1beta` fallback ([A] of §5.4.4) is remembered per provider instance, that is for the life of the app.
- The live Ollama test runs in every `scripts/test.sh` while Ollama answers on 127.0.0.1:11434 (as §3.5 says); it sends one 16-token prompt to the smallest installed model that can complete text (here `phi:latest`) and takes about 0.5–3 s.
- `REFEREE_TEST_KEYCHAIN=1` enables one test that adds, reads, replaces and deletes keys in an item with the service `local.referee.tests.<UUID>` and removes the item afterwards. It never touches `local.referee.app`.
- Nothing in `Sources/LLMKit` names a model id; the only model-id strings are the filter words of §5.4.2 and §5.4.4.

## Acceptance

Run on Command Line Tools 26.6 (Swift 6.3.3), with `-j 2`, at the last commit.

| Command | Result | Final line |
| --- | --- | --- |
| `scripts/build.sh -j 2` | exit 0; no line with "warning" or "error" | `Build complete! (…)` |
| `scripts/test.sh -j 2 --filter LLMKitTests` | exit 0; no "warning"; the real-Keychain test skipped visibly, the live Ollama test ran | `test.sh: OK (107 tests)` |
| `scripts/test.sh -j 2` | exit 0; no "warning" | `test.sh: OK (234 tests)` |
| `REFEREE_TEST_KEYCHAIN=1 scripts/test.sh -j 2 --filter LLMKitTests` (run once) | exit 0; `theRealKeychainSetsGetsReplacesAndDeletes()` passed after 0.104 seconds; afterwards `security dump-keychain` lists no `local.referee.tests` item | `test.sh: OK (107 tests)` |
| `git status --porcelain \| wc -l` | | `0` |

The LLMKit suite also passed five runs in a row, and three more with eight extra busy loops on the machine.
