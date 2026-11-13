// Posts a Markdown comment on a Huly issue so it renders formatted.
// huly-mcp-selfhost's add_comment stores the Markdown text as-is, and Huly
// shows that as one plain run of text with literal ** and -. Huly's editor
// stores comments as ProseMirror JSON; this converts Markdown to that first.
//
//   echo '**Done.** …' | NODE_OPTIONS=--no-experimental-webstorage \
//     npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/comment.cjs OVERS-1'
//   … -c 'node huly/comment.cjs OVERS-1 <comment id>'   # rewrites that comment instead
const fs = require('fs')
const path = require('path')

process.env.HULY_EMAIL = 'omp@agents.local'
process.env.HULY_PASSWORD = fs.readFileSync(path.join(process.env.HOME, '.config/huly/omp.password'), 'utf8').trim()
process.env.HULY_ACCOUNTS_URL = 'http://localhost:8087/_accounts'
process.env.HULY_WORKSPACE = 'jack'

const bin = (process.env.PATH || '').split(':').find((dir) => dir.includes('_npx') && dir.endsWith('node_modules/.bin'))
if (!bin) throw new Error('run through npx -p huly-mcp-selfhost (see the header)')
const modules = path.dirname(bin)
const dist = path.join(modules, 'huly-mcp-selfhost/dist')
const conn = require(path.join(dist, 'connection.js'))
const { markdownToProseMirror } = require(path.join(dist, 'utils/markdown.js'))
const tracker = require(path.join(modules, '@hcengineering/tracker')).default
const chunter = require(path.join(modules, '@hcengineering/chunter')).default

;(async () => {
  const [ident, commentId] = process.argv.slice(2)
  const markdown = fs.readFileSync(0, 'utf8').trim()
  if (!ident || !markdown) throw new Error('usage: node huly/comment.cjs ISSUE [COMMENT_ID] < markdown')
  const message = JSON.stringify(markdownToProseMirror(markdown))
  const client = await conn.getConnection('jack')
  const issue = await client.findOne(tracker.class.Issue, { identifier: ident })
  if (!issue) throw new Error('issue ' + ident + ' not found')
  if (commentId) {
    await client.updateCollection(chunter.class.ChatMessage, issue.space, commentId, issue._id, tracker.class.Issue, 'comments', { message })
    console.log('updated comment on ' + ident)
  } else {
    await client.addCollection(chunter.class.ChatMessage, issue.space, issue._id, tracker.class.Issue, 'comments', { message })
    console.log('commented on ' + ident)
  }
  await conn.closeConnection()
  process.exit(0)
})().catch((error) => {
  console.error('huly comment: ' + error.message)
  process.exit(1)
})
