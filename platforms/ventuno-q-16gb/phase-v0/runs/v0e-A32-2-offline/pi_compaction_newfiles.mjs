import fs from "fs";
const m = await import("/home/arduino/.local/share/mise/installs/node/22.23.3/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/compaction/compaction.js");
const [sess, fa, fb] = process.argv.slice(2);
const all = fs.readFileSync(sess, "utf8").trim().split("\n").map(JSON.parse).filter(e => e.type !== "session");
const users = all.map((e,i)=>[e,i]).filter(([e])=>e.type==="message"&&e.message.role==="user").map(([,i])=>i);
const pre = structuredClone(all.slice(0, users[2]));
const files = [fs.readFileSync(fa,"utf8"), fs.readFileSync(fb,"utf8")]; let k = 0;
for (const e of pre) if (e.type==="message") {
  if (e.message.role==="toolResult") e.message.content = [{ type: "text", text: files[k++] }];
  if (e.message.role==="assistant") e.message.content = e.message.content.filter(c => c.type!=="thinking").map(c => c.type==="text" ? { ...c, text: "X" } : c);
}
const est = es => es.filter(e=>e.type==="message").reduce((a,e)=>a+m.estimateTokens(e.message),0);
const p = m.prepareCompaction(pre, { ...m.DEFAULT_COMPACTION_SETTINGS });
console.log(`new files, model output stripped to a minimum: tool results replaced ${k}, estimate before turn 3 ${est(pre)} -> ${p ? "preparation (a cut exists)" : "nothing to compact"}`);
if (p) console.log("  firstKeptEntryId", p.firstKeptEntryId, "| tokensBefore", p.tokensBefore, "| messagesToSummarize", (p.messagesToSummarize||[]).length, "| isSplitTurn", p.isSplitTurn, "| turnPrefixMessages", (p.turnPrefixMessages||[]).map(x=>x.role).join(","));
