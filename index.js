// Cloudflare Worker: MCP server (Streamable HTTP) <-> Roblox client bridge
//   POST /mcp        MCP JSON-RPC (AI clients)
// MCP URL option: ?exclude=feed,memory,waypoints,macros,automation,advanced hides tool groups.
//   GET  /poll       long-poll for commands (Roblox script)
//   POST /result     command results (Roblox script)
//   POST /frame      live-feed frames (Roblox script)
//   GET  /view       live feed viewer page (browser)
//   GET  /frame.png  latest frame
// Auth: ?key=TOKEN or "Authorization: Bearer TOKEN". If no TOKEN secret is set, auth is off
// and run_lua is disabled.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const num = { type: "number" };
const str = { type: "string" };
const t = (name, description, properties = {}, required = []) => ({
  name,
  description,
  inputSchema: { type: "object", properties, required },
});

const STEPS = {
  type: "array",
  description: "Steps like [{\"tool\":\"walk\",\"args\":{\"direction\":\"forward\",\"seconds\":2}}, {\"tool\":\"jump\",\"args\":{}}]",
  items: { type: "object", properties: { tool: { type: "string" }, args: { type: "object" } }, required: ["tool"] },
};

const STEP_TOOLS = new Set([
  "click", "click_world", "mouse_move", "scroll", "press_key", "chat", "move_to", "walk", "stop", "jump", "teleport",
  "face", "look_at", "rotate_camera", "release_camera", "set_humanoid", "change_state", "equip_tool", "unequip_tool",
  "use_tool", "fire_prompt", "click_detector", "wait", "goto_waypoint",
]);

// Hide tool groups by adding ?exclude=feed,macros,... to the MCP URL (keeps the tool list small).
const GROUPS = {
  feed: ["screenshot", "set_feed", "get_frame"],
  memory: ["remember", "recall", "forget"],
  waypoints: ["get_position", "distance_to", "save_waypoint", "list_waypoints", "delete_waypoint", "goto_waypoint"],
  macros: ["save_macro", "list_macros", "delete_macro", "run_macro", "run_steps", "stop_macro", "macro_status", "record_start", "record_stop", "path_record_start", "path_record_stop"],
  automation: ["get_events", "add_trigger", "list_triggers", "remove_trigger", "wait_until", "anti_afk", "follow_player", "stop_follow"],
  advanced: ["inspect", "get_property", "set_property", "run_lua", "find_objects", "find_prompts", "fire_prompt", "click_detector", "set_humanoid", "change_state", "list_players", "get_stats", "history"],
};

const TOOLS = [
  // observation
  t("status", "Connection status of the Roblox client and the live feed."),
  t("get_state", "Player position, health, camera, viewport size, other players, and all visible GUI buttons/labels with screen x,y centers."),
  t("describe_scene", "Text 'vision': nearby objects and players with distance, world position and screen x,y (onScreen flag).", { radius: num, limit: num }),
  t("find_objects", "Search workspace by name and/or class. Returns path, position, distance, screen position.", {
    query: { ...str, description: "name substring" }, class: { ...str, description: "e.g. BasePart, Model, Tool, ProximityPrompt" }, radius: num, limit: num,
  }),
  t("screenshot", "Capture one frame of the game screen and return it as an image.", { width: { ...num, description: "pixels, default 320, max 640" } }),
  t("set_feed", "Start or stop a live frame feed. While on, the latest frame is available via get_frame and at /view?key=TOKEN. Auto-stops after `seconds`.", {
    enabled: { type: "boolean" }, interval: { ...num, description: "seconds between frames, default 1.5" },
    width: { ...num, description: "default 320" }, seconds: { ...num, description: "max duration, default 60, max 600" },
  }, ["enabled"]),
  t("get_frame", "Return the latest frame from the live feed as an image."),

  // input
  t("click", "Click at screen pixel coordinates (use x,y from get_state / describe_scene).", { x: num, y: num, button: { ...str, enum: ["left", "right"] } }, ["x", "y"]),
  t("click_world", "Click the screen position of a world coordinate.", { x: num, y: num, z: num, button: { ...str, enum: ["left", "right"] } }, ["x", "y", "z"]),
  t("mouse_move", "Move the mouse to screen coordinates.", { x: num, y: num }, ["x", "y"]),
  t("scroll", "Scroll the mouse wheel at coordinates.", { x: num, y: num, direction: { ...str, enum: ["up", "down"] } }, ["x", "y", "direction"]),
  t("press_key", "Press and hold a key (Enum.KeyCode name, e.g. W, Space, E, LeftShift, One).", { key: str, seconds: num }, ["key"]),
  t("chat", "Send a chat message.", { message: str }, ["message"]),

  // character
  t("move_to", "Walk the character to a world position (pathless MoveTo).", { x: num, y: num, z: num, timeout: num }, ["x", "y", "z"]),
  t("walk", "Walk in a direction for some seconds. direction: forward/back/left/right or combos like forward_left. Camera-relative by default.", {
    direction: str, seconds: num, relative: { type: "boolean" },
  }, ["direction"]),
  t("stop", "Stop moving."),
  t("jump", "Jump."),
  t("teleport", "Teleport the character to a world position (client-side).", { x: num, y: num, z: num }, ["x", "y", "z"]),
  t("face", "Rotate the character to face a world x,z.", { x: num, z: num }, ["x", "z"]),
  t("look_at", "Point the camera at a world position (locks camera until release_camera).", { x: num, y: num, z: num }, ["x", "y", "z"]),
  t("rotate_camera", "Rotate the camera by yaw/pitch degrees (locks camera until release_camera).", { yaw: num, pitch: num }),
  t("release_camera", "Return camera control to the default camera."),
  t("set_humanoid", "Set walkSpeed, jumpPower, jumpHeight and/or hipHeight.", { walkSpeed: num, jumpPower: num, jumpHeight: num, hipHeight: num }),
  t("change_state", "Change humanoid state (e.g. Jumping, Freefall, Running, Seated, Swimming).", { state: str }, ["state"]),

  // tools & interaction
  t("list_tools", "List tools in the backpack / equipped."),
  t("equip_tool", "Equip a tool from the backpack by name.", { name: str }, ["name"]),
  t("unequip_tool", "Unequip tools."),
  t("use_tool", "Activate the equipped tool.", { seconds: num }),
  t("find_prompts", "List ProximityPrompts within a radius (default 20).", { radius: num }),
  t("fire_prompt", "Trigger a ProximityPrompt by index (from find_prompts) or path.", { index: num, path: str }),
  t("click_detector", "Fire a ClickDetector at an instance path (needs executor support).", { path: str }, ["path"]),

  // misc
  t("wait", "Wait N seconds in-game (max 30).", { seconds: num }, ["seconds"]),

  // pathfinding & following
  t("path_to", "Walk to a position using Roblox pathfinding (goes around obstacles, jumps). Max ~20s per call; call again if not reached.", { x: num, y: num, z: num, timeout: num, tolerance: num }, ["x", "y", "z"]),
  t("follow_player", "Follow another player (by name or display name) in the background. stop or stop_follow ends it.", { name: str, distance: { ...num, description: "stay this many studs away, default 6" }, seconds: { ...num, description: "default 60" } }, ["name"]),
  t("stop_follow", "Stop following."),

  // events & automation
  t("get_events", "Read the game event log: chat, player_joined, player_left, damaged, died, respawned. Pass `last` from the previous result as `since`. `wait` (max 20s) blocks until a new event arrives.", {
    since: num, types: { type: "array", items: str }, limit: num, wait: num,
  }),
  t("add_trigger", "Run steps automatically on the client when an event happens (lasts until the script is re-run). event: chat, player_joined, player_left, damaged, died, respawned. `contains` filters event text/name.", {
    name: str, event: { ...str, enum: ["chat", "player_joined", "player_left", "damaged", "died", "respawned"] }, contains: str, cooldown: num, steps: STEPS,
  }, ["name", "event", "steps"]),
  t("list_triggers", "List active triggers."),
  t("remove_trigger", "Remove a trigger.", { name: str }, ["name"]),
  t("wait_until", "Block (max 20s) until a condition is true. condition: near (x,y,z,radius), gui_text (text), object (name), health_below / health_above (value).", {
    condition: { ...str, enum: ["near", "gui_text", "object", "health_below", "health_above"] },
    x: num, y: num, z: num, radius: num, text: str, name: str, value: num, timeout: num,
  }, ["condition"]),
  t("anti_afk", "Prevent the idle/AFK kick (on by default when called; enabled=false turns it off).", { enabled: { type: "boolean" } }),

  // GUI & inspection
  t("click_gui", "Click a visible GUI button/label by its text and/or instance name instead of coordinates.", {
    text: { ...str, description: "substring (case-insensitive) unless exact=true" }, name: str, exact: { type: "boolean" }, index: { ...num, description: "which match, default 1" }, button: { ...str, enum: ["left", "right"] },
  }),
  t("type_text", "Type into a TextBox: the focused one, or one by path. submit=true presses enter.", { text: str, path: str, submit: { type: "boolean" } }, ["text"]),
  t("list_players", "All players with team, leaderstats, health, held tool, position and distance."),
  t("inspect", "Describe an instance by path (e.g. Workspace.Map.Door): class, key properties, attributes, children.", { path: str }, ["path"]),
  t("get_property", "Read a property of an instance by path.", { path: str, property: str }, ["path", "property"]),
  t("set_property", "Set a property on the client (Vector3 as {x,y,z}, Color3 as {r,g,b}, enums by name).", { path: str, property: str, value: {} }, ["path", "property", "value"]),
  t("get_stats", "FPS, ping, memory, player count, jobId, placeId, server time."),
  t("history", "Your recent tool calls on this server (for reviewing what you already did).", { limit: num }),

  // coordinates & waypoints (saved permanently)
  t("get_position", "Current position, look direction and placeId."),
  t("distance_to", "Distance and offsets from the player to a coordinate or saved waypoint.", { x: num, y: num, z: num, name: { ...str, description: "waypoint name instead of x,y,z" } }),
  t("save_waypoint", "Save a named coordinate. Omit x,y,z to save the player's current position.", { name: str, x: num, y: num, z: num, note: str }, ["name"]),
  t("list_waypoints", "List saved waypoints. fromHere=true adds distance and sorts nearest first.", { fromHere: { type: "boolean" } }),
  t("delete_waypoint", "Delete a saved waypoint.", { name: str }, ["name"]),
  t("goto_waypoint", "Go to a saved waypoint. method: move_to (walk, default) or teleport.", { name: str, method: { ...str, enum: ["move_to", "teleport"] }, timeout: num }, ["name"]),

  // memory (saved permanently)
  t("remember", "Save any JSON value under a key. Persists across chats and restarts.", { key: str, value: {} }, ["key", "value"]),
  t("recall", "Read a saved value by key, or everything if no key is given.", { key: str }),
  t("forget", "Delete a saved memory key.", { key: str }, ["key"]),

  // macros
  t("save_macro", "Save a named macro: an ordered list of steps {tool,args}. Allowed step tools: click, click_world, mouse_move, scroll, press_key, chat, move_to, walk, stop, jump, teleport, face, look_at, rotate_camera, release_camera, set_humanoid, change_state, equip_tool, unequip_tool, use_tool, fire_prompt, click_detector, wait, goto_waypoint.", {
    name: str, description: str, steps: STEPS,
  }, ["name", "steps"]),
  t("list_macros", "List saved macros with their steps."),
  t("delete_macro", "Delete a saved macro.", { name: str }, ["name"]),
  t("run_macro", "Run a saved macro in the background on the client. Check progress with macro_status.", {
    name: str, repeat: { ...num, description: "times to repeat, default 1" }, delay: { ...num, description: "seconds between steps" }, continueOnError: { type: "boolean" },
  }, ["name"]),
  t("run_steps", "Run an ad-hoc list of steps (same format as save_macro) in the background without saving.", {
    steps: STEPS, repeat: num, delay: num, continueOnError: { type: "boolean" },
  }, ["steps"]),
  t("stop_macro", "Stop the running macro and stop moving."),
  t("macro_status", "Progress of the current/last macro."),
  t("record_start", "Start recording the action tool calls you make (moves, clicks, etc.) into a macro.", { name: str }, ["name"]),
  t("record_stop", "Stop recording and save the macro (or cancel=true to discard).", { cancel: { type: "boolean" } }),
  t("path_record_start", "Start recording the player's own movement (the human walks around). Jumps are captured.", { interval: { ...num, description: "seconds between samples, default 0.5" } }),
  t("path_record_stop", "Stop path recording. With a name, saves it as a macro of move_to/jump steps; otherwise returns the points.", { name: str, minDistance: { ...num, description: "drop points closer than this, default 2" } }),
  t("run_lua", "Execute arbitrary Luau on the client. Use `return` to send back a value. Disabled when the Worker has no TOKEN.", { code: str }, ["code"]),
];

export class Bridge {
  constructor(state) {
    this.state = state;
    this.queue = [];
    this.pending = new Map();
    this.waiter = null;
    this.lastSeen = 0;
    this.frame = null;
    this.history = [];
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

    if (path === "/frame") {
      if (req.method === "POST") {
        const d = await req.json();
        if (d && typeof d.image === "string") this.frame = { image: d.image, width: d.width, height: d.height, ts: Date.now() };
        return new Response("ok");
      }
      return this.frame ? Response.json(this.frame) : new Response("no frame", { status: 404 });
    }

    if (path === "/history") {
      if (req.method === "POST") {
        this.history.push(await req.json());
        if (this.history.length > 100) this.history.shift();
        return new Response("ok");
      }
      return Response.json(this.history);
    }

    if (path === "/data") {
      const k = new URL(req.url).searchParams.get("k");
      if (req.method === "POST") {
        await this.state.storage.put(k, await req.text());
        return new Response("ok");
      }
      return new Response((await this.state.storage.get(k)) ?? "");
    }

    if (path === "/status") {
      const now = Date.now();
      return Response.json({
        clientConnected: now - this.lastSeen < 30000,
        lastSeenSecondsAgo: this.lastSeen ? Math.round((now - this.lastSeen) / 1000) : null,
        hasFrame: !!this.frame,
        frameAgeSeconds: this.frame ? Math.round((now - this.frame.ts) / 1000) : null,
      });
    }

    return new Response("not found", { status: 404 });
  }
}

const text = (s, isError = false) => ({ content: [{ type: "text", text: s }], isError });
const image = (d, caption) => ({
  content: [{ type: "image", data: d.image, mimeType: "image/png" }, { type: "text", text: caption }],
});
const json = (v) => text(JSON.stringify(v));

// ---- storage helpers (Durable Object, survives restarts) ----
async function kvGet(bridge, k, def) {
  const t = await bridge.fetch("https://do/data?k=" + k).then((r) => r.text());
  return t ? JSON.parse(t) : def;
}
async function kvSet(bridge, k, v) {
  const s = JSON.stringify(v);
  if (s.length > 100000) throw new Error(`storage for "${k}" is full (100 KB limit)`);
  await bridge.fetch("https://do/data?k=" + k, { method: "POST", body: s });
}
const send = (bridge, action, args) =>
  bridge.fetch("https://do/enqueue", { method: "POST", body: JSON.stringify({ action, args }) }).then((r) => r.json());

function validateSteps(steps, open) {
  if (!Array.isArray(steps) || !steps.length) throw new Error("steps must be a non-empty array");
  if (steps.length > 300) throw new Error("max 300 steps");
  for (const s of steps) {
    const ok = s && typeof s.tool === "string" && (STEP_TOOLS.has(s.tool) || (s.tool === "run_lua" && !open));
    if (!ok) throw new Error(`step tool not allowed: ${s && s.tool}`);
  }
}

// replace goto_waypoint steps with concrete move_to/teleport steps
function resolveSteps(steps, wps) {
  return steps.map((s) => {
    if (s.tool !== "goto_waypoint") return { tool: s.tool, args: s.args || {} };
    const w = wps[s.args?.name];
    if (!w) throw new Error(`unknown waypoint in macro: ${s.args?.name}`);
    return { tool: s.args.method === "teleport" ? "teleport" : "move_to", args: { x: w.x, y: w.y, z: w.z, timeout: s.args.timeout } };
  });
}

async function maybeRecord(bridge, name, args, open) {
  if (!(STEP_TOOLS.has(name) || (name === "run_lua" && !open))) return;
  const rec = await kvGet(bridge, "rec", null);
  if (!rec) return;
  if (rec.steps.length < 300) rec.steps.push({ tool: name, args: args || {} });
  await kvSet(bridge, "rec", rec);
}

// ---- tools handled on the Worker (return undefined to forward to the Roblox client) ----
async function localTool(name, a, bridge, open) {
  switch (name) {
    case "status": {
      const s = await bridge.fetch("https://do/status").then((r) => r.json());
      const [mem, wps, macros, rec] = await Promise.all([kvGet(bridge, "mem", {}), kvGet(bridge, "wps", {}), kvGet(bridge, "macros", {}), kvGet(bridge, "rec", null)]);
      return json({ ...s, authRequired: !open, memoryKeys: Object.keys(mem).length, waypoints: Object.keys(wps).length, macros: Object.keys(macros).length, recording: rec ? rec.name : null });
    }
    case "get_frame": {
      const f = await bridge.fetch("https://do/frame");
      if (f.status !== 200) return text("No frame yet. Call set_feed {enabled:true} first.", true);
      const d = await f.json();
      return image(d, `${d.width}x${d.height}, ${Math.round((Date.now() - d.ts) / 1000)}s old`);
    }

    // memory
    case "remember": {
      const mem = await kvGet(bridge, "mem", {});
      mem[a.key] = { value: a.value, ts: Date.now() };
      await kvSet(bridge, "mem", mem);
      return text("remembered " + a.key);
    }
    case "recall": {
      const mem = await kvGet(bridge, "mem", {});
      if (a.key) return json(a.key in mem ? mem[a.key].value : null);
      return json(Object.fromEntries(Object.entries(mem).map(([k, v]) => [k, v.value])));
    }
    case "forget": {
      const mem = await kvGet(bridge, "mem", {});
      const had = a.key in mem;
      delete mem[a.key];
      await kvSet(bridge, "mem", mem);
      return text(had ? "forgot " + a.key : "no such key");
    }

    // waypoints
    case "save_waypoint": {
      let { x, y, z } = a;
      let place = null;
      if ([x, y, z].some((v) => typeof v !== "number")) {
        const r = await send(bridge, "get_position", {});
        if (!r.ok) return text("Error: " + r.error, true);
        ({ x, y, z } = r.result.position || {});
        place = r.result.placeId;
        if (typeof x !== "number") return text("Error: player has no character yet", true);
      }
      const wps = await kvGet(bridge, "wps", {});
      wps[a.name] = { x, y, z, place, note: a.note, ts: Date.now() };
      await kvSet(bridge, "wps", wps);
      return text(`saved waypoint ${a.name} at ${x}, ${y}, ${z}`);
    }
    case "list_waypoints": {
      const wps = await kvGet(bridge, "wps", {});
      let list = Object.entries(wps).map(([name, w]) => ({ name, x: w.x, y: w.y, z: w.z, place: w.place, note: w.note }));
      if (a.fromHere) {
        const r = await send(bridge, "get_position", {});
        if (r.ok && r.result.position) {
          const p = r.result.position;
          list = list.map((w) => ({ ...w, dist: Math.round(Math.hypot(w.x - p.x, w.y - p.y, w.z - p.z) * 10) / 10 })).sort((m, n) => m.dist - n.dist);
        }
      }
      return json(list);
    }
    case "delete_waypoint": {
      const wps = await kvGet(bridge, "wps", {});
      const had = a.name in wps;
      delete wps[a.name];
      await kvSet(bridge, "wps", wps);
      return text(had ? "deleted " + a.name : "no such waypoint");
    }
    case "goto_waypoint": {
      const wps = await kvGet(bridge, "wps", {});
      const w = wps[a.name];
      if (!w) return text("Error: unknown waypoint " + a.name, true);
      const r = await send(bridge, a.method === "teleport" ? "teleport" : "move_to", { x: w.x, y: w.y, z: w.z, timeout: a.timeout });
      return r.ok ? json(r.result) : text("Error: " + r.error, true);
    }
    case "distance_to": {
      let { x, y, z } = a;
      if (a.name) {
        const w = (await kvGet(bridge, "wps", {}))[a.name];
        if (!w) return text("Error: unknown waypoint " + a.name, true);
        ({ x, y, z } = w);
      }
      if ([x, y, z].some((v) => typeof v !== "number")) return text("Error: give x,y,z or a waypoint name", true);
      const r = await send(bridge, "distance_to", { x, y, z });
      return r.ok ? json(r.result) : text("Error: " + r.error, true);
    }

    // macros
    case "save_macro": {
      validateSteps(a.steps, open);
      const macros = await kvGet(bridge, "macros", {});
      macros[a.name] = { steps: a.steps, description: a.description, ts: Date.now() };
      await kvSet(bridge, "macros", macros);
      return text(`saved macro ${a.name} (${a.steps.length} steps)`);
    }
    case "list_macros": {
      const macros = await kvGet(bridge, "macros", {});
      return json(Object.entries(macros).map(([name, m]) => ({ name, description: m.description, steps: m.steps })));
    }
    case "delete_macro": {
      const macros = await kvGet(bridge, "macros", {});
      const had = a.name in macros;
      delete macros[a.name];
      await kvSet(bridge, "macros", macros);
      return text(had ? "deleted " + a.name : "no such macro");
    }
    case "run_macro":
    case "run_steps": {
      let steps = a.steps;
      if (name === "run_macro") {
        const m = (await kvGet(bridge, "macros", {}))[a.name];
        if (!m) return text("Error: unknown macro " + a.name, true);
        steps = m.steps;
      }
      validateSteps(steps, open);
      const wps = await kvGet(bridge, "wps", {});
      const r = await send(bridge, "run_steps", {
        name: a.name, steps: resolveSteps(steps, wps), repeat: a.repeat, delay: a.delay, continueOnError: a.continueOnError, background: true,
      });
      return r.ok ? json(r.result) : text("Error: " + r.error, true);
    }

    case "add_trigger": {
      validateSteps(a.steps, open);
      const wps = await kvGet(bridge, "wps", {});
      const r = await send(bridge, "add_trigger", { ...a, steps: resolveSteps(a.steps, wps) });
      return r.ok ? json(r.result) : text("Error: " + r.error, true);
    }
    case "history": {
      const h = await bridge.fetch("https://do/history").then((r) => r.json());
      return json(h.slice(-(a.limit || 20)));
    }

    // recording
    case "record_start": {
      await kvSet(bridge, "rec", { name: a.name, steps: [] });
      return text(`recording "${a.name}" - your next action tool calls are captured. Call record_stop to save.`);
    }
    case "record_stop": {
      const rec = await kvGet(bridge, "rec", null);
      if (!rec) return text("not recording", true);
      await kvSet(bridge, "rec", null);
      if (a.cancel) return text("recording discarded");
      if (!rec.steps.length) return text("nothing was recorded", true);
      const macros = await kvGet(bridge, "macros", {});
      macros[rec.name] = { steps: rec.steps, description: "recorded", ts: Date.now() };
      await kvSet(bridge, "macros", macros);
      return text(`saved macro ${rec.name} (${rec.steps.length} steps)`);
    }
    case "path_record_stop": {
      const r = await send(bridge, "path_record_stop", {});
      if (!r.ok) return text("Error: " + r.error, true);
      const min = typeof a.minDistance === "number" ? a.minDistance : 2;
      const steps = [];
      let last = null;
      for (const p of r.result.points || []) {
        const far = !last || Math.hypot(p.x - last.x, p.y - last.y, p.z - last.z) >= min;
        if (far) {
          steps.push({ tool: "move_to", args: { x: p.x, y: p.y, z: p.z, timeout: 8 } });
          last = p;
        }
        if (p.jump) steps.push({ tool: "jump", args: {} });
      }
      if (!a.name) return json({ points: (r.result.points || []).length, steps });
      if (!steps.length) return text("no movement was recorded", true);
      const macros = await kvGet(bridge, "macros", {});
      macros[a.name] = { steps, description: "recorded path", ts: Date.now() };
      await kvSet(bridge, "macros", macros);
      return text(`saved macro ${a.name} (${steps.length} steps from ${(r.result.points || []).length} samples)`);
    }
  }
  return undefined;
}

async function handleRpc(msg, bridge, open, exclude = new Set()) {
  const { id, method, params } = msg;
  const reply = (result) => ({ jsonrpc: "2.0", id, result });
  const fail = (code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

  if (id === undefined) return null; // notification

  const tools = TOOLS.filter((x) => !(open && x.name === "run_lua") && !exclude.has(x.name));

  switch (method) {
    case "initialize": {
      const [mem, wps, macros] = await Promise.all([kvGet(bridge, "mem", {}), kvGet(bridge, "wps", {}), kvGet(bridge, "macros", {})]);
      const list = (o) => Object.keys(o).slice(0, 30).join(", ") || "none";
      return reply({
        protocolVersion: params?.protocolVersion || "2025-03-26",
        capabilities: { tools: {} },
        serverInfo: { name: "roblox-mcp", version: "3.0.0" },
        instructions:
          "Controls the user's Roblox client. Use describe_scene/get_state/screenshot to see, then act. " +
          `Saved memory keys (read with recall): ${list(mem)}. Waypoints: ${list(wps)}. Macros: ${list(macros)}. ` +
          "Use remember to store anything worth keeping between chats.",
      });
    }
    case "ping":
      return reply({});
    case "tools/list":
      return reply({ tools });
    case "tools/call": {
      const { name, arguments: args } = params || {};
      if (!tools.find((x) => x.name === name)) return fail(-32602, "unknown tool " + name);
      const a = args || {};

      const log = (ok) =>
        name === "history" ? null : bridge.fetch("https://do/history", { method: "POST", body: JSON.stringify({ t: new Date().toISOString(), tool: name, args: JSON.stringify(a).slice(0, 160), ok }) });

      let out;
      try {
        out = await localTool(name, a, bridge, open);
      } catch (e) {
        await log(false);
        return reply(text("Error: " + e.message, true));
      }
      if (out) {
        if (!out.isError) await maybeRecord(bridge, name, a, open);
        await log(!out.isError);
        return reply(out);
      }

      const res = await send(bridge, name, a);
      await log(!!res.ok);
      if (!res.ok) return reply(text("Error: " + res.error, true));
      await maybeRecord(bridge, name, a, open);

      const r = res.result;
      if (r && typeof r === "object" && typeof r.image === "string") return reply(image(r, `${r.width}x${r.height}`));
      return reply(text(typeof r === "string" ? r : JSON.stringify(r ?? "done")));
    }
    default:
      return fail(-32601, "method not found: " + method);
  }
}

const VIEW_HTML = `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<title>Roblox live feed</title>
<body style="margin:0;background:#111;color:#aaa;font:14px sans-serif;text-align:center">
<p id=s>waiting for frames... (ask the AI to call set_feed)</p>
<img id=i style="max-width:100%;image-rendering:pixelated;display:none">
<script>
const q=location.search,i=document.getElementById('i'),s=document.getElementById('s');
setInterval(()=>{const n=new Image();n.onload=()=>{i.src=n.src;i.style.display='block';s.style.display='none'};
n.src='/frame.png'+q+(q?'&':'?')+'t='+Date.now()},1000);
</script>`;

export default {
  async fetch(req, env) {
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });

    const url = new URL(req.url);
    const key = url.searchParams.get("key") || (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const open = !env.TOKEN; // no TOKEN secret = no auth (anyone with the URL can use it)
    if (!open && key !== env.TOKEN) return new Response("unauthorized", { status: 401, headers: cors });

    const bridge = env.BRIDGE.get(env.BRIDGE.idFromName("main"));
    const p = url.pathname;

    if (p === "/poll") return bridge.fetch("https://do/poll");
    if (p === "/result" && req.method === "POST") return bridge.fetch("https://do/result", { method: "POST", body: req.body });
    if (p === "/frame" && req.method === "POST") return bridge.fetch("https://do/frame", { method: "POST", body: req.body });

    if (p === "/frame.png") {
      const f = await bridge.fetch("https://do/frame");
      if (f.status !== 200) return new Response("no frame", { status: 404, headers: cors });
      const d = await f.json();
      const bin = Uint8Array.from(atob(d.image), (c) => c.charCodeAt(0));
      return new Response(bin, { headers: { ...cors, "content-type": "image/png", "cache-control": "no-store" } });
    }
    if (p === "/view") return new Response(VIEW_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });

    if (p === "/mcp") {
      if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: cors });
      const body = await req.json();
      const msgs = Array.isArray(body) ? body : [body];
      const exclude = new Set(
        (url.searchParams.get("exclude") || "").split(",").map((g) => g.trim()).flatMap((g) => GROUPS[g] || []),
      );
      const out = (await Promise.all(msgs.map((m) => handleRpc(m, bridge, open, exclude)))).filter(Boolean);
      if (!out.length) return new Response(null, { status: 202, headers: cors });
      return Response.json(Array.isArray(body) ? out : out[0], { headers: cors });
    }

    return new Response("roblox-mcp running", { headers: cors });
  },
};
