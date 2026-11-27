# AI chat: source implementation and acceptance

Source of truth: the current English app Help sections **AI chat**, **Choosing AI models**, and **Connecting AI providers**. Source-only status: no .NET tests, build, Windows UI launch or requests to real AI providers have been performed.

## Present in source

- Native Fluent right panel, connection/model selectors, settings accessible from the app and chat, new conversation, local history, deletion and clearing history.
- OpenAI-compatible Chat Completions, Anthropic Messages and ChatGPT plan Responses, bounded streaming SSE and JSON fallback, cancellation, overall/idle timeouts and explicit terminal validation.
- OpenRouter browser authorization with S256 PKCE, state and an ephemeral loopback callback; model review and DPAPI storage only after explicit saving.
- Multiple manual key-based connections, editable model IDs and explicitly requested model catalogs. No model list or provider request on startup.
- Protected Windows-user credentials with entropy bound to the connection ID, normalized address and protocol. Changing the address/protocol requires explicit key entry.
- HTTPS endpoints or HTTP literal loopback/localhost gateways; redirects are rejected. Responses are bounded and provider error bodies are not displayed as diagnostics containing secrets.
- Context checkboxes start off. The send review identifies destination/model and previews attached content. Your message and conversation history go to that provider after confirmation.
- Current task, custom folder and note snapshots. Provider payloads exclude internal workspace/entity/proposal IDs, fingerprints and note digests.
- Reviewed task/note/event creation, task edits and note text/title edits. The model cannot choose edit-target IDs or apply mutations itself.
- Task deadline changes are independent of Today and planning folders. Proposed subtasks add items; they do not silently replace the saved checklist.
- Atomic stale-task checks with stable content fingerprints; note digest checks with conflict-copy preservation. Creation IDs are stable across retries.
- Native proposal editing, explicit note append/replace selection, persistent review audit and handled proposal markers. A refreshed context requires another review before application.
- Note append keeps original styles/images. Replace produces plain text and preserves images at the end; title-only changes keep the body.
- Cancelled/truncated/malformed tool replies never become applicable cards. Partial reply text is kept in history after generation stops.

Conversation history retains explicitly attached snapshots. Deleting the original task or note does not remove a separate conversation; clear its history separately. Keys do not enter the history database. History does not synchronize between devices.

## Explicit platform differences / remaining scope

ChatGPT and OpenRouter have browser sign-in flows. Copilot authenticates through the official GitHub CLI launched by the local Windows bridge. Named key-based connections select provider addresses and authentication; Yandex binds a Cloud folder and GigaChat exchanges a key for a scoped token. GigaChat validates TLS through the Windows trust store. See OPENROUTER-OAUTH.md for the OpenRouter callback and exchange contract.

There are no Windows reasoning controls, provider usage/limits views, Markdown rendering, chat file/audio attachments or existing-event edit proposals yet. Chat event creation targets the local Windows calendar, without calendar cloud-account access. Transcription settings remain separate and currently use a compatible transcription endpoint. Dismissals persist in conversation history. A refreshed context stays available for review in the current session. Saving the review keeps both snapshots in history.

These are open product gaps, not passed Help-parity items.

## Required verification on Windows — not run

- [ ] Restore/type-check/compile pinned Core and WinUI projects and execute all isolated fake-HTTP/SQLite regression sources.
- [ ] Test light/dark/high contrast, Narrator, keyboard focus and dialogs at narrow widths and 100–200% display scaling.
- [ ] Open from app settings after closing the parent dialog; add/change/remove connections and models without losing existing protected keys.
- [ ] Complete/cancel/deny OpenRouter browser authorization with a dedicated account, test wrong state/nonce/Host, port contention, exchange timeout and closing during model selection; verify nothing is saved before confirmation.
- [ ] Authorize a dedicated ChatGPT account and verify nonce, account identity and plan consent. Switch accounts, renew an expired session and verify only the newest refresh token is used.
- [ ] Start the Copilot bridge on Windows x64 and ARM64, verify the local code and account binding, and reject a stopped bridge or changed signed-in account.
- [ ] Test each named provider's catalog or manual model IDs, region/project/edition choice, chat response, proposal support and rate limits.
- [ ] Round-trip DPAPI credentials and reject credential reuse after changing endpoint/protocol.
- [ ] Stream an ordinary answer and proposals, stop during headers/text/tool arguments, interrupt the connection and exceed each timeout/size limit.
- [ ] Confirm partial text is saved once and partial proposals cannot be applied, including restart after cancellation.
- [ ] Attach each context explicitly, inspect disclosure and verify no internal identifiers enter the fake provider payload.
- [ ] Switch tasks/notes while a reply is generated; proposals retain their original target. Switch libraries and close while requests, catalogs or application are pending.
- [ ] Apply reviewed creations twice, including uncertain write/history failures, and verify no duplicate tasks, subtasks, notes or events.
- [ ] Edit an attached task remotely/locally before applying; reject stale proposals without losing newer content. A transport acknowledgement alone must not invalidate unchanged content.
- [ ] Replace/append/title-edit notes with Unicode, formatting and multiple inline images; test concurrent deletion, expiry and conflict copies.
- [ ] Switch to a different task or note, refresh a stale proposal and verify its target stays the original item. Reread the proposed text and confirm that both snapshots remain in the review history.
- [ ] Dismiss a proposal, reopen its conversation and verify the decision survives restart and a stale history save.
- [ ] Create timed/all-day event proposals around DST and verify independent task deadlines/folders/stars.
- [ ] Open, delete and clear scoped history; late saves must not erase newer messages or handled markers.
- [ ] Only after explicit authorization, run smoke requests with dedicated provider accounts and models. No personal/live service was exercised during source development.

Protocol references: [OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create), [OpenAI streaming](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events/), [Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming), [Anthropic versioning](https://platform.claude.com/docs/en/api/versioning).

Provider references: [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [ChatGPT Responses and models](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [Copilot CLI authentication](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli), [Yandex AI Studio](https://aistudio.yandex.ru/en/docs/ai-studio/operations/generation/completions-basic), [GigaChat authentication](https://developers.sber.ru/docs/ru/gigachat/api/reference/rest/gigachat-api), [MiniMax Messages](https://platform.minimax.io/docs/api-reference/text-anthropic-api).
