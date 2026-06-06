// Recover the 3 completed Inventory-phase agent outputs from the dead Phase-0 workflow.
// Each agent was schema-forced, so its result is the input to a StructuredOutput tool call
// (or the final assistant text). Extract whichever exists and write clean JSON+MD.
import fs from 'node:fs'
import path from 'node:path'

const WF = '/Users/sergiosolano/.claude/projects/-Users-sergiosolano-vy-monitor/752dbcbf-ceb7-40e6-b40f-7156e10a4be5/subagents/workflows/wf_3c901107-5c0'
const want = {
  a29c22a94e0d2d684: 'inv:oz-manifest',
  a88093b7f1d33ad3b: 'inv:deps-admin',
  aefec67d19fbcc4e4: 'inv:invariants',
}

const deepFindStructured = (obj, acc) => {
  if (!obj || typeof obj !== 'object') return
  // tool_use block for StructuredOutput
  if (obj.type === 'tool_use' && /structured/i.test(obj.name || '')) acc.push(obj.input)
  for (const k of Object.keys(obj)) deepFindStructured(obj[k], acc)
}

const results = {}
for (const [key, label] of Object.entries(want)) {
  const f = path.join(WF, `agent-${key}.jsonl`)
  if (!fs.existsSync(f)) { results[label] = { error: 'no file' }; continue }
  const lines = fs.readFileSync(f, 'utf8').trim().split('\n')
  const structured = []
  let lastText = null
  for (const l of lines) {
    let e
    try { e = JSON.parse(l) } catch { continue }
    deepFindStructured(e, structured)
    // capture last assistant text content
    const msg = e.message || e
    const content = msg && msg.content
    if (Array.isArray(content)) {
      for (const c of content) if (c && c.type === 'text' && c.text) lastText = c.text
    } else if (typeof content === 'string') lastText = content
  }
  results[label] = structured.length ? structured[structured.length - 1] : (lastText ? { _text: lastText } : { error: 'no output found', records: lines.length })
}

fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/_inventory_recovered.json', JSON.stringify(results, null, 2))

// Render a readable summary
let md = '# Phase 0 Inventory — recovered from interrupted workflow (wf_3c901107-5c0)\n\n'
md += 'The Inventory phase (3 agents) completed before the workflow process died; the Scoping fan-out never ran. Outputs recovered from agent transcripts.\n\n'
for (const [label, v] of Object.entries(results)) {
  md += `## ${label}\n\n`
  if (v && v.error) { md += `_recovery issue: ${v.error}_\n\n`; continue }
  if (v && v._text) { md += v._text + '\n\n'; continue }
  md += '```json\n' + JSON.stringify(v, null, 2).slice(0, 12000) + '\n```\n\n'
}
fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/_inventory_recovered.md', md)
console.log('keys: ' + Object.keys(results).map((k) => k + '=' + (results[k].error ? 'ERR' : 'ok')).join(' '))
