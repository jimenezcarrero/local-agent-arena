import fs from "fs";
const C = "/home/arduino/.local/share/mise/installs/node/22.23.3/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/compaction/compaction.js";
const m = await import(C);
const f = process.argv[2];
const entries = fs.readFileSync(f, "utf8").trim().split("\n").map(JSON.parse);
const branch = entries.filter(e => e.type !== "session");
for (const keep of [20000, 15000, 10000]) {
  const p = m.prepareCompaction(branch, { ...m.DEFAULT_COMPACTION_SETTINGS, keepRecentTokens: keep });
  console.log("keepRecentTokens", keep, "->", p ? `compactable: ${p.messagesToSummarize?.length ?? "?"} messages to summarize, tokensBefore ${p.tokensBefore}` : "nothing to compact (undefined)");
}
let est = 0; for (const e of branch) if (e.type === "message") { const t = m.estimateTokens(e.message); est += t; if (t > 500) console.log("  estimate", e.message.role, t); }
console.log("estimated total", est, "| server-reported context after turn 2: 27152");
