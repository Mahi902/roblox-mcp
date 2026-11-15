// Cloudflare Worker: MCP server (Streamable HTTP) <-> Roblox client bridge
// Endpoints (all require ?key=TOKEN or "Authorization: Bearer TOKEN"):
//   POST /mcp     -> MCP JSON-RPC (for AI clients)
//   GET  /poll    -> long-poll for commands (for Roblox script)
//   POST /result  -> command results (from Roblox script)

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const t = (name, description, properties = {}, required = []) => ({
  name,
  description,
  inputSchema: { type: "object", properties, required },
});

const TOOLS = [
  t("get_state", "Get player position, health, viewport size, other players, and all visible GUI buttons/labels with their screen x,y centers."),
  t("click", "Click at screen pixel coordinates (use x,y from get_state).", {
    x: { type: "number" }, y: { type: "number" },
    button: { type: "string", enum: ["left", "right"] },
  }, ["x", "y"]),
  t("mouse_move", "Move the mouse to screen coordinates.", { x: { type: "number" }, y: { type: "number" } }, ["x", "y"]),
  t("scroll", "Scroll the mouse wheel at coordinates.", {
    x: { type: "number" }, y: { type: "number" }, direction: { type: "string", enum: ["up", "down"] },
  }, ["x", "y", "direction"]),
  t("press_key", "Press and hold a key (Roblox Enum.KeyCode name, e.g. W, A, Space, E, LeftShift, One).", {
    key: { type: "string" }, seconds: { type: "number", description: "hold time, default 0.05" },
  }, ["key"]),
  t("move_to", "Walk the character to a world position.", {
    x: { type: "number" }, y: { type: "number" }, z: { type: "number" }, timeout: { type: "number" },
  }, ["x", "y", "z"]),
  t("jump", "Make the character jump."),
  t("chat", "Send a chat message.", { message: { type: "string" } }, ["message"]),
  t("run_lua", "Execute arbitrary Luau code on the client. Use `return` to send back a value.", { code: { type: "string" } }, ["code"]),
];

export class Bridge {
  constructor() {
    this.queue = [];
    this.pending = new Map();
    this.waiter = null;
    this.lastSeen = 0;
  }

  async fetch(req) {
    const path = new URL(req.url).pathname;

    if (path === "/enqueue") {
      const { action, args } = await req.json();
      const id = crypto.randomUUID();
      const p = new Promise((resolve) => {
        const timer = setTimeout(() => {
          this.pending.delete(id);
          const connected = Date.now() - this.lastSeen < 30000;
          resolve({
            ok: false,
            error: connected
              ? "timeout waiting for the game to finish the command"
              : "Roblox client is not connected (run the Luau script in Delta)",
          });
        }, 25000);
        this.pending.set(id, { resolve, timer });
      });
      this.queue.push({ id, action, args: args || {} });
      if (this.waiter) this.waiter();
      return Response.json(await p);
    }

    if (path === "/poll") {
      this.lastSeen = Date.now();
      if (!this.queue.length) {
        await new Promise((res) => {
          const timer = setTimeout(() => { this.waiter = null; res(); }, 20000);
          this.waiter = () => { clearTimeout(timer); this.waiter = null; res(); };
        });
      }
      this.lastSeen = Date.now();
      return Response.json(this.queue.splice(0));
    }

    if (path === "/result") {
      const r = await req.json();
      const p = this.pending.get(r.id);
      if (p) {
        clearTimeout(p.timer);
        this.pending.delete(r.id);
        p.resolve({ ok: r.ok, result: r.result, error: r.error });
      }
      return new Response("ok");
    }

    return new Response("not found", { status: 404 });
  }
}

async function handleRpc(msg, bridge, open) {
  const tools = open ? TOOLS.filter((x) => x.name !== "run_lua") : TOOLS; // run_lua disabled when no TOKEN is set
  const { id, method, params } = msg;
  const reply = (result) => ({ jsonrpc: "2.0", id, result });
  const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

  if (id === undefined) return null; // notification

  switch (method) {
    case "initialize":
      return reply({
        protocolVersion: params?.protocolVersion || "2025-03-26",
        capabilities: { tools: {} },
        serverInfo: { name: "roblox-mcp", version: "1.0.0" },
      });
    case "ping":
      return reply({});
    case "tools/list":
      return reply({ tools });
    case "tools/call": {
      const { name, arguments: args } = params || {};
      if (!tools.find((x) => x.name === name)) return fail(-32602, "unknown tool " + name);
      const res = await bridge
        .fetch("https://do/enqueue", {
          method: "POST",
          body: JSON.stringify({ action: name, args }),
        })
        .then((r) => r.json());
      const text = res.ok
        ? typeof res.result === "string" ? res.result : JSON.stringify(res.result ?? "done")
        : "Error: " + res.error;
      return reply({ content: [{ type: "text", text }], isError: !res.ok });
    }
    default:
      return fail(-32601, "method not found: " + method);
  }
}

export default {
  async fetch(req, env) {
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });

    const url = new URL(req.url);
    const key = url.searchParams.get("key") || (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const open = !env.TOKEN; // no TOKEN secret set = no auth (anyone with the URL can use it)
    if (!open && key !== env.TOKEN) return new Response("unauthorized", { status: 401, headers: cors });

    const bridge = env.BRIDGE.get(env.BRIDGE.idFromName("main"));

    if (url.pathname === "/poll") return bridge.fetch("https://do/poll");
    if (url.pathname === "/result" && req.method === "POST")
      return bridge.fetch("https://do/result", { method: "POST", body: req.body });

    if (url.pathname === "/mcp") {
      if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: cors });
      const body = await req.json();
      const msgs = Array.isArray(body) ? body : [body];
      const out = (await Promise.all(msgs.map((m) => handleRpc(m, bridge, open)))).filter(Boolean);
      if (!out.length) return new Response(null, { status: 202, headers: cors });
      return Response.json(Array.isArray(body) ? out : out[0], { headers: cors });
    }

    return new Response("roblox-mcp running", { headers: cors });
  },
};
