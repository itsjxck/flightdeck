// Overseer's link to Huly, run once per poll by window.luau:
//   npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/bridge.cjs'
// stdin:  {"panes": {"<pane id>": "working" | "waiting" | "idle"}, "seen": {"<issue id>": <createdOn ms>}}
//         `panes` lists every live agent pane in the window; `seen` is the newest
//         comment already delivered per issue (kept by Overseer in kv).
// stdout: {"tasks": [{pane, id, ident, title, url}],
//          "comments": [{pane, id, ident, title, createdOn, text}]}
//
// Issues link to agents by `omp session` (the agent's $PI_SESSION_ID), which
// outlives the pane: when Tern restarts, it resumes the session in a new pane.
// sessionPanes() finds each live pane's session from the file omp keeps open
// (`<…>_<session id>.jsonl`), else from `--resume <session id>` on its command.
//
// For every open linked issue it makes `Agent state` follow Tern (Working /
// Idle, Gone once no pane runs the session; `Waiting for you`, set by the agent
// when it asks, stays until the agent works again), and returns your comments
// newer than `seen`. A first sighting returns nothing and only reports the
// newest comment, so history from before a link is never replayed.
const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')

const WORKSPACE = 'jack'
const FRONT = 'http://localhost:8087'
process.env.HULY_EMAIL = 'omp@agents.local'
process.env.HULY_PASSWORD = fs.readFileSync(path.join(process.env.HOME, '.config/huly/omp.password'), 'utf8').trim()
process.env.HULY_ACCOUNTS_URL = FRONT + '/_accounts'
process.env.HULY_WORKSPACE = WORKSPACE

const bin = (process.env.PATH || '').split(':').find((dir) => dir.includes('_npx') && dir.endsWith('node_modules/.bin'))
if (!bin) throw new Error('run through npx -p huly-mcp-selfhost (see the header)')
const modules = path.dirname(bin)
const dist = path.join(modules, 'huly-mcp-selfhost/dist')
const conn = require(path.join(dist, 'connection.js'))
const attributes = require(path.join(dist, 'utils/attributes.js'))
const { markupToText } = require(path.join(dist, 'utils/format.js'))
const tracker = require(path.join(modules, '@hcengineering/tracker')).default
const chunter = require(path.join(modules, '@hcengineering/chunter')).default

const TERN_STATE = { working: 'Working', waiting: 'Waiting for you', idle: 'Idle' }
const CLOSED = new Set(['task:statusCategory:Won', 'task:statusCategory:Lost'])
const TERN = process.env.TERN_EXE || '/Applications/Tern.app/Contents/MacOS/tern'
const SESSION_ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

// Live pane ids → the omp session each runs: { "<session id>": "<pane id>" }.
function sessionPanes (paneIds) {
  const pidPane = new Map()
  const fromArgv = {}
  for (const pane of paneIds) {
    try {
      const info = JSON.parse(execFileSync(TERN, ['process', pane, '--json'], { encoding: 'utf8', timeout: 5000 }))
      const proc = info.foreground || info.child
      if (!proc || !proc.pid) continue
      pidPane.set(String(proc.pid), pane)
      const argv = proc.argv || []
      const resume = argv.indexOf('--resume')
      const id = resume >= 0 && SESSION_ID.exec(argv[resume + 1] || '')
      if (id) fromArgv[pane] = id[0]
    } catch {}
  }
  const fromFile = {}
  if (pidPane.size > 0) {
    let listing = ''
    try {
      listing = execFileSync('/usr/sbin/lsof', ['-a', '-p', [...pidPane.keys()].join(','), '-Fpn'], { encoding: 'utf8', timeout: 5000 })
    } catch (error) {
      listing = error.stdout || '' // lsof exits 1 when a pid has no match
    }
    let pane
    for (const line of listing.split('\n')) {
      if (line.startsWith('p')) pane = pidPane.get(line.slice(1))
      else if (pane && line.startsWith('n') && line.includes('/.omp/') && line.includes('/sessions/') && line.endsWith('.jsonl')) {
        const id = SESSION_ID.exec(path.basename(line))
        if (id) fromFile[pane] = id[0]
      }
    }
  }
  const map = {}
  for (const pane of paneIds) {
    const id = fromFile[pane] || fromArgv[pane]
    if (id) map[id] = pane
  }
  return map
}

async function main () {
  const input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}')
  const panes = input.panes || {}
  const seen = input.seen || {}
  const sessions = sessionPanes(Object.keys(panes))
  const client = await conn.getConnection(WORKSPACE)
  const me = client.user
  // Only open issues are linked: Done (Won) and Canceled (Lost) are not.
  const statuses = new Map((await client.findAll(tracker.class.IssueStatus, {})).map((s) => [s._id, s]))

  const out = { tasks: [], comments: [], seen: {} }
  // shortcut: scans the 500 most recently modified issues; linked ones are recent by nature.
  const issues = await client.findAll(tracker.class.Issue, {}, { limit: 500, sort: { modifiedOn: -1 } })
  for (const issue of issues) {
    const fields = await attributes.fieldsOf(client, issue)
    const byLabel = (label) => fields.find((f) => f.label === label)
    const sessionField = byLabel('omp session')
    const stateField = byLabel('Agent state')
    if (!sessionField || !stateField) continue
    const session = attributes.valueOf(issue, sessionField)
    if (!session) continue
    const pane = sessions[session]
    const status = statuses.get(issue.status)
    if (status && CLOSED.has(status.category)) continue
    const ident = issue.identifier
    const title = issue.title

    // Agent state follows Tern. An agent that asked ends its turn (Tern: idle),
    // so `Waiting for you` stays until it works again or its pane closes.
    const current = attributes.valueOf(issue, stateField)
    const wanted = panes[pane] ? TERN_STATE[panes[pane]] : 'Gone'
    const keepWaiting = current === 'Waiting for you' && panes[pane] && panes[pane] !== 'working'
    if (wanted && !keepWaiting && current !== wanted) {
      await attributes.writeFields(client, issue, [{ field: stateField, value: await attributes.coerceValue(client, stateField, wanted) }])
    }
    if (!panes[pane]) continue
    out.tasks.push({ pane, id: issue._id, ident, title, url: FRONT + '/workbench/' + WORKSPACE + '/tracker/' + ident })

    const comments = await client.findAll(chunter.class.ChatMessage, { attachedTo: issue._id }, { sort: { createdOn: 1 } })
    const newest = comments.reduce((max, c) => Math.max(max, c.createdOn || 0), 0)
    if (seen[issue._id] == null) {
      out.seen[issue._id] = newest
      continue
    }
    for (const comment of comments) {
      if ((comment.createdOn || 0) <= seen[issue._id] || comment.createdBy === me) continue
      out.comments.push({ pane, id: issue._id, ident, title, createdOn: comment.createdOn, text: markupToText(comment.message) })
    }
  }
  process.stdout.write(JSON.stringify(out))
  await conn.closeConnection()
}

main().then(() => process.exit(0), (error) => {
  process.stderr.write('huly bridge: ' + (error && error.stack ? error.stack : String(error)) + '\n')
  process.exit(1)
})
