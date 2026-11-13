// Overseer's link to Huly, run once per poll by window.luau:
//   npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/bridge.cjs'
// stdin:  {"panes": {"<pane id>": "working" | "waiting" | "idle"}, "seen": {"<issue id>": <createdOn ms>}}
//         `panes` lists every live agent pane in the window; `seen` is the newest
//         comment already delivered per issue (kept by Overseer in kv).
// stdout: {"tasks": [{pane, id, ident, title, url}],
//          "comments": [{pane, id, ident, title, createdOn, text}]}
//
// For every open issue whose `Tern pane` is set it makes `Agent state` follow
// Tern (Working / Idle, Gone once the pane has closed; `Waiting for you` with a
// Question stays, the agent owns it), and returns your comments newer than
// `seen`. A first sighting returns nothing and only reports the newest comment,
// so history from before a link is never replayed.
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

async function main () {
  const input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}')
  const panes = input.panes || {}
  const seen = input.seen || {}
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
    const paneField = byLabel('Tern pane')
    const stateField = byLabel('Agent state')
    const questionField = byLabel('Question')
    if (!paneField || !stateField) continue
    const pane = attributes.valueOf(issue, paneField)
    if (!pane) continue
    const status = statuses.get(issue.status)
    if (status && CLOSED.has(status.category)) continue
    const ident = issue.identifier
    const title = issue.title

    // Agent state follows Tern, except a question the agent is waiting on.
    const current = attributes.valueOf(issue, stateField)
    const asking = current === 'Waiting for you' && questionField && attributes.valueOf(issue, questionField)
    const wanted = panes[pane] ? TERN_STATE[panes[pane]] : 'Gone'
    if (wanted && !asking && current !== wanted) {
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
