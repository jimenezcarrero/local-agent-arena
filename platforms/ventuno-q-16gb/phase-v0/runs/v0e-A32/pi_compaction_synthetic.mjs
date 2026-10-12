import fs from "fs";
const m = await import("/home/arduino/.local/share/mise/installs/node/22.23.3/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/compaction/compaction.js");
const all = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").map(JSON.parse).filter(e => e.type !== "session");
// boundary before the third user prompt
const users = all.map((e,i)=>[e,i]).filter(([e])=>e.type==="message"&&e.message.role==="user").map(([,i])=>i);
const pre = all.slice(0, users[2]);
const est = es => es.filter(e=>e.type==="message").reduce((a,e)=>a+m.estimateTokens(e.message),0);
const S = { ...m.DEFAULT_COMPACTION_SETTINGS };
console.log("recorded, before turn 3: estimate", est(pre), "->", m.prepareCompaction(pre, S) ? "preparation" : "nothing to compact");
const mod = structuredClone(pre); let last; mod.forEach(e=>{ if(e.type==="message"&&e.message.role==="assistant") last=e; });
last.message.content = [{ type: "thinking", thinking: "x".repeat(8000) }, ...last.message.content];
console.log("synthetic, +8000 thinking chars in the 2nd turn's last reply: estimate", est(mod), "->", m.prepareCompaction(mod, S) ? "preparation" : "nothing to compact");
