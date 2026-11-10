import { CopilotClient, RuntimeConnection } from "@github/copilot-sdk";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { resolve } from "node:path";

const workspace = resolve("workspace");
const client = new CopilotClient({
    connection: RuntimeConnection.forStdio({
        path: resolve("node_modules/.bin/copilot"),
        args: ["--no-custom-instructions", "--disable-builtin-mcps", "--disable-client-telemetry"],
    }),
    workingDirectory: workspace,
    useLoggedInUser: true,
});

await client.start().catch(() => {
    console.error("Could not start the official GitHub Copilot runtime.");
    process.exit(1);
});

async function identity() {
    const auth = await client.getAuthStatus();
    if (!auth.isAuthenticated || !auth.login || auth.authType !== "user") return null;
    return `${auth.host || "https://github.com"}|${auth.login.toLowerCase()}`;
}

const account = await identity().catch(() => null);
if (!account) {
    await client.stop();
    process.exit(42);
}

// Код локального соединения, не связанный с OAuth или API-ключами GitHub.
const key = randomBytes(32).toString("hex");
const expected = Buffer.from(`Bearer ${key}`);
const allowedEfforts = new Set(["low", "medium", "high", "xhigh", "max"]);
let active = false;

function json(response, status, value) {
    response.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    response.end(JSON.stringify(value));
}

async function readBody(request) {
    const parts = [];
    let size = 0;
    for await (const part of request) {
        size += part.length;
        if (size > 160000) throw new Error("Oversized request");
        parts.push(part);
    }
    return JSON.parse(Buffer.concat(parts).toString("utf8"));
}

function write(response, value) {
    if (!response.destroyed) response.write(`data: ${JSON.stringify(value)}\n\n`);
}

async function chat(request, response) {
    if (active) return json(response, 429, {});
    active = true;
    let session;
    try {
        const body = await readBody(request);
        if (typeof body.model !== "string" || !Array.isArray(body.messages) || body.messages.length < 2
            || body.messages[0]?.role !== "system" || body.messages.at(-1)?.role !== "user"
            || body.messages.some(message => typeof message?.content !== "string")) {
            return json(response, 400, {});
        }
        const tool = body.tools?.[0]?.function;
        const allowsTool = tool?.name === "propose_changes" && tool.parameters?.type === "object";
        let proposal;
        let duplicate = false;
        let tokens;
        let previewed = false;
        const history = body.messages.slice(1, -1);
        const context = history.length ? "\n\nConversation transcript (JSON data): " + JSON.stringify(history) : "";
        session = await client.createSession({
            model: body.model,
            reasoningEffort: allowedEfforts.has(body.reasoning_effort) ? body.reasoning_effort : undefined,
            workingDirectory: workspace,
            streaming: true,
            availableTools: allowsTool ? ["custom:propose_changes"] : [],
            excludedTools: ["builtin:*", "mcp:*"],
            tools: allowsTool ? [{
                name: "propose_changes",
                description: "Propose changes for review in Tasks.",
                parameters: tool.parameters,
                skipPermission: true,
                isTerminal: true,
                handler: args => {
                    if (proposal) duplicate = true;
                    proposal = JSON.stringify(args);
                    return "Proposal recorded for user review.";
                },
            }] : [],
            systemMessage: { mode: "append", content: body.messages[0].content + context },
            onPermissionRequest: () => ({ kind: "denied-by-rules" }),
            enableConfigDiscovery: false,
            enableFileHooks: false,
            enableHostGitOperations: false,
            enableSkills: false,
            enableSessionStore: false,
            mcpServers: {},
            includedBuiltinAgents: [],
            infiniteSessions: { enabled: false },
        });
        if (response.destroyed) return;
        response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
        response.on("close", () => { if (!response.writableEnded) session.abort().catch(() => {}); });
        session.on(event => {
            if (event.type === "assistant.message_delta" && event.data.deltaContent) {
                previewed = true;
                write(response, { choices: [{ index: 0, delta: { content: event.data.deltaContent } }] });
            }
            if (event.type === "assistant.usage") {
                const count = Number(event.data.inputTokens) + Number(event.data.outputTokens);
                if (Number.isSafeInteger(count) && count >= 0) tokens = (tokens ?? 0) + count;
            }
        });
        const message = await session.sendAndWait({ prompt: body.messages.at(-1).content }, 120000);
        if (duplicate || (proposal && Buffer.byteLength(proposal) > 120000) || (!proposal && !message?.data.content)) {
            throw new Error("Incomplete response");
        }
        if (proposal) {
            write(response, { choices: [{ index: 0, delta: { tool_calls: [
                { index: 0, type: "function", function: { name: "propose_changes", arguments: proposal } },
            ] } }] });
        } else if (!previewed) {
            write(response, { choices: [{ index: 0, delta: { content: message.data.content } }] });
        }
        write(response, { choices: [{ index: 0, finish_reason: proposal ? "tool_calls" : "stop" }] });
        if (tokens !== undefined) write(response, { choices: [], usage: { total_tokens: tokens } });
        response.end("data: [DONE]\n\n");
    } catch {
        if (!response.headersSent) json(response, 502, {});
        else if (!response.destroyed) {
            write(response, { error: {} });
            response.end();
        }
    } finally {
        if (session) {
            await session.disconnect().catch(() => {});
            await client.deleteSession(session.sessionId).catch(() => {});
        }
        active = false;
    }
}

const server = createServer(async (request, response) => {
    const actual = Buffer.from(request.headers.authorization ?? "");
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return json(response, 401, {});
    if (request.headers.origin) return json(response, 403, {});
    try {
        const currentAccount = await identity();
        if (!currentAccount || currentAccount !== account
            || (request.headers["x-tasks-account"] && request.headers["x-tasks-account"] !== account)) {
            return json(response, 403, {});
        }
        if (request.method === "GET" && request.url === "/v1/models") {
            const models = await client.listModels();
            return json(response, 200, { account, data: models.filter(model => model.policy?.state !== "disabled" && model.capabilities?.limits?.max_context_window_tokens > 0).map(model => ({
                id: model.id, name: model.name, supported_parameters: ["tools"],
                effort: { supported_levels: model.supportedReasoningEfforts ?? [] },
            })) });
        }
        if (request.method === "GET" && request.url === "/v1/quota") {
            const { quotaSnapshots } = await client.rpc.account.getQuota({});
            const quota = quotaSnapshots?.premium_interactions ?? quotaSnapshots?.chat;
            return json(response, 200, { remaining: quota?.isUnlimited ? null : quota?.remainingPercentage });
        }
        if (request.method === "POST" && request.url === "/v1/chat/completions" && request.headers["x-tasks-account"] === account) {
            return await chat(request, response);
        }
        return json(response, 404, {});
    } catch {
        if (!response.headersSent) json(response, 502, {});
        else response.end();
    }
});
server.requestTimeout = 30000;
server.on("error", async () => {
    console.error("Could not start the Tasks connection on port 43347.");
    await client.stop();
    process.exit(1);
});
server.listen(43347, "127.0.0.1", () => {
    console.log("\nGitHub Copilot → Tasks\nPaste this connection code in Tasks and keep this window open:\n" + key + "\n");
});
process.on("SIGINT", async () => {
    server.closeAllConnections();
    server.close();
    await client.stop();
    process.exit(0);
});
