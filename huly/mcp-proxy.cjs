// Runs huly-mcp-selfhost behind a stdio proxy that makes agents' comments
// render formatted. The server stores add_comment's and update_comment's
// `message` as raw Markdown, which Huly shows as
// one plain run of text with literal ** and -. Huly's editor stores comments
// as ProseMirror JSON, so the proxy converts those fields before the server
// sees them. Everything else passes through unchanged. (finish_work prefixes
// its summary with Markdown inside the server, out of reach; agents skip it.)
//
// Started by ~/.config/huly/mcp-server.sh through npx, so the pinned package is on PATH:
//   npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/mcp-proxy.cjs'
const { spawn } = require('child_process')
const path = require('path')
const readline = require('readline')

const bin = (process.env.PATH || '').split(':').find((dir) => dir.includes('_npx') && dir.endsWith('node_modules/.bin'))
if (!bin) throw new Error('run through npx -p huly-mcp-selfhost (see the header)')
const { markdownToProseMirror } = require(path.join(path.dirname(bin), 'huly-mcp-selfhost/dist/utils/markdown.js'))

const MARKDOWN_ARGS = { add_comment: 'message', update_comment: 'message' }

function rewrite (line) {
  let msg
  try { msg = JSON.parse(line) } catch { return line }
  const field = msg && msg.method === 'tools/call' && msg.params && MARKDOWN_ARGS[msg.params.name]
  const args = field && msg.params.arguments
  const text = args && args[field]
  // Already ProseMirror JSON (or not text): leave it.
  if (typeof text !== 'string' || text.trimStart().startsWith('{')) return line
  args[field] = JSON.stringify(markdownToProseMirror(text))
  return JSON.stringify(msg)
}

const server = spawn(path.join(bin, 'huly-mcp-selfhost'), process.argv.slice(2), { stdio: ['pipe', 'inherit', 'inherit'] })
server.on('exit', (code, signal) => process.exit(code ?? (signal ? 1 : 0)))
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity })
input.on('line', (line) => server.stdin.write(rewrite(line) + '\n'))
input.on('close', () => server.stdin.end())
