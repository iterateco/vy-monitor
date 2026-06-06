// Extract structured outputs from a finished audit workflow's agent transcripts.
// Finds the synthesis (has safeToProceed) + all finder/verifier outputs.
import fs from 'node:fs'
import path from 'node:path'

const dir = process.argv[2]
const find = (obj, acc) => {
  if (!obj || typeof obj !== 'object') return
  if (obj.type === 'tool_use' && /structured/i.test(obj.name || '')) acc.push(obj.input)
  for (const k of Object.keys(obj)) find(obj[k], acc)
}
const files = fs.readdirSync(dir).filter((f) => f.startsWith('agent-') && f.endsWith('.jsonl'))
let synth = null
const finders = [], verdicts = []
for (const f of files) {
  const lines = fs.readFileSync(path.join(dir, f), 'utf8').trim().split('\n')
  const acc = []
  for (const l of lines) { let e; try { e = JSON.parse(l) } catch { continue } find(e, acc) }
  for (const o of acc) {
    if (!o || typeof o !== 'object') continue
    if ('safeToProceed' in o) synth = o
    else if ('verdict' in o && 'correctedSeverity' in o) verdicts.push(o)
    else if ('findings' in o && 'dimension' in o) finders.push(o)
  }
}
fs.writeFileSync('/Users/sergiosolano/vy-monitor/audit/_vy_audit_raw.json', JSON.stringify({ synth, verdicts, finderDims: finders.map((f) => ({ dim: f.dimension, n: (f.findings || []).length })) }, null, 2))
console.log('synth=' + !!synth + ' verdicts=' + verdicts.length + ' finders=' + finders.length)
