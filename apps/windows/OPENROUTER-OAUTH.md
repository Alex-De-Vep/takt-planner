# OpenRouter browser connection for Windows

**Source implementation only.** No OAuth session, browser, listener, provider exchange, account, restore, build, .NET test or native application launch was executed during this update. Reading public documentation did not authenticate to OpenRouter.

## Verified provider contract

The current official [OpenRouter PKCE guide](https://openrouter.ai/docs/guides/overview/auth/oauth) documents browser authorization at `https://openrouter.ai/auth`, a `callback_url`, S256 PKCE, an optional key label, and state echoed on successful authorization. Loopback callbacks support arbitrary free ports. State is not returned when the user denies authorization, and headless authorization is a separate flow.

The code exchange is **POST `https://openrouter.ai/api/v1/auth/keys`**, with JSON fields `code`, `code_verifier`, and `code_challenge_method: "S256"`. A successful response has `key`. This creates a user-controlled OpenRouter API key, rather than a refresh-token session. No client secret or existing API key is sent by this browser flow. See the guide and [official exchange reference](https://openrouter.ai/docs/api/api-reference/oauth/exchange-authorization-code-for-api-key). The generated API reference currently includes a generic bearer-header example, while the browser PKCE guide's exchange example omits that header; this implementation follows the PKCE guide and the existing macOS/Android adapters.

`/api/v1/auth/keys/code` is a different authorization-code creation endpoint. `/api/v1/keys/code` is not used. Do not replace the verified exchange URL with either of those paths.

The existing implementations were reviewed: Android `GatewayOAuth.openRouter`, and macOS `AssistantGatewayConnections.signInOpenRouter`, `AssistantGatewayHTTP.openRouterKey`, and `ChatGPTLoopback.openRouterCallback`. The Windows adapter follows the same provider protocol and strengthens local callback Host/header/time/size checks.

## Core integration

```csharp
var oauth = new OpenRouterOAuth();
using var cancel = new CancellationTokenSource();
OpenRouterGrant grant = await oauth.ConnectAsync(async address =>
{
    // Native UI supplies browser launching. Check the launch result and throw
    // if Windows could not open it. Do not log the URL or its query parameters.
    bool opened = await global::Windows.System.Launcher.LaunchUriAsync(address);
    if (!opened) throw new InvalidOperationException("Browser launch failed.");
}, cancel.Token);
// Persist grant.Key only through the existing DPAPI-backed connection settings.
```

The root UI owns the explicit Connect button, cancellation, success/failure presentation, provider-model selection and DPAPI persistence. A modal connection flow should keep unrelated settings disabled until completion. Close/cancel must cancel the token and await the operation before accepting another attempt or leaving settings. The root must guard its settings/workspace revision again before applying a completed result. A cancelled or stale operation must never overwrite another connection's credentials.

Core neither persists the key nor selects a model. Reuse the normal OpenRouter API base `https://openrouter.ai/api/v1` in the saved connection. The grant's `ToString()` is redacted because a record's default formatter would otherwise print the credential; callers must still avoid logging `.Key`, exceptions from other provider code, or serialized grants.

The production HTTP client is private, has redirects/cookies/default server credentials disabled, bounds response headers, and uses normal certificate validation. Constructor injection is for isolated HTTP fixtures. .NET does not expose an already-created HttpClient's handler redirect/cookie settings; an injected client must obey the same constraints and must not carry default credentials. Authorization/Cookie/Proxy-Authorization default headers are rejected. No injected application-wide authenticated client should be used.

## Callback and resource bounds

- Each explicit attempt binds IPv4 literal **127.0.0.1**, port **0** (OS-assigned ephemeral port), with exclusive address use. It never binds wildcard interfaces or resolves a hostname.
- The callback is `/oauth/callback/{nonce}` with a fresh 128-bit base64url path nonce. Success additionally requires a fresh 256-bit state and S256 PKCE generated from 32 cryptographically random bytes. The verifier stays in memory and never enters the browser URL.
- The callback must be an origin-form HTTP/1.1 GET on the exact nonce path, with exactly the expected literal Host/port. Absolute-form targets, duplicate headers, bodies, transfer encodings and upgrades are rejected. Query values are decoded once using strict UTF-8; duplicate parameters, malformed escapes and control characters are rejected.
- Missing/wrong/duplicate state, unrelated favicon requests, foreign paths and malformed requests do not consume the active attempt. Valid nonmatching requests receive 400/404; oversized, incomplete or slow requests may be disconnected. A provider error without state only ends the attempt when its exact nonce path and Host match; a present but incorrect state never ends it. Provider error text is not displayed or returned.
- At most 8 callback connections are read concurrently, each with an 8 KiB header bound and a 5-second read/write lifetime. The total browser-plus-exchange attempt expires after 3 minutes. Cancellation stops the listener, closes callback clients and awaits their cleanup. The port is released before code exchange.
- The exchange has a 30-second deadline inside the total bound, reads headers first, refuses redirects, requires uncompressed JSON, caps the body at 16 KiB even without Content-Length, limits JSON depth to 8, and rejects missing/duplicate/blank/non-header-safe or oversized keys. A valid key is not assumed to have an undocumented prefix.
- Responses to the browser contain only static text, `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy: no-referrer`, a restrictive CSP and `nosniff`. No codes, states, key, provider errors or request headers are echoed.
- Exceptions exposed to the caller use owned messages with no original exception as an inner exception. Caller cancellation remains `OperationCanceledException`; owned flow/exchange deadlines are `TimeoutException`. Raw transport errors and response payloads are not surfaced.

Cancelling after provider authorization may leave a newly authorized OpenRouter key on the user's account if the exchange completed before cancellation; this adapter never silently deletes an external key. The user controls revocation in OpenRouter. Browser history/extensions may see the authorization code; S256 prevents its exchange without this attempt's verifier. No embedded webview, headless/manual-code fallback, external helper process, refresh-token grant or other provider OAuth is implemented here.

## Verification evidence

`OpenRouterOAuthTests.cs` supplies source-only fixtures with an in-memory HttpMessageHandler and literal-loopback TCP. They cover the RFC 7636 S256 vector; authorization URL/entropy/endpoint/body; missing/incorrect/duplicate state; duplicate code, invalid UTF-8 and escaping; nonce paths, Host duplication, bodies and absolute targets; denial without state; single decoding of opaque codes; oversized headers and slow parallel clients; cancellation/port release before and during exchange; fresh per-attempt secrets; HTTP error/redirect redaction; malformed or ambiguous keys; unknown-length oversized bodies; browser failure and grant diagnostics.

These tests were **not executed**. Only source parsing and static checks are permitted at this stage. The project-wide source checker parsed XML/XAML and C# syntax; this is not .NET type checking, NuGet validation or Windows acceptance.

## Acceptance before release — all pending

- [ ] Build Core and WinUI on Windows 11 and execute these isolated fixtures before using a real account.
- [ ] Verify browser launch, success callback/state echo, denial without state, tab closure, retry, timeout and cancellation on actual Windows.
- [ ] Verify port cleanup, parallel/slow invalid callback traffic, browser callback headers and Windows firewall behavior without wildcard exposure.
- [ ] Verify the current live provider's documented loopback and exchange contract with an explicit dedicated test-account approval.
- [ ] Verify no redirects/default credentials and key/code redaction in actual UI, diagnostics and crash reports.
- [ ] Verify DPAPI persistence, cancelled/stale settings guards, shutdown and account transitions, then list models using the explicitly connected provider.
- [ ] Verify x64/ARM64, accessibility/localization and unpackaged browser launching separately.
