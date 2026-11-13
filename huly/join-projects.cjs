// Makes the workspace owner (you) a member and owner of every Huly project, so
// projects agents create (as `omp`) show in your sidebar. Huly only lists
// projects you belong to, and no MCP tool edits project members.
//
// Run through npx so the pinned huly-mcp-selfhost and its Huly client are on hand:
//   npx -y -p huly-mcp-selfhost@3.1.0 -c 'node huly/join-projects.cjs'
const fs = require('fs')
const path = require('path')

process.env.HULY_EMAIL = 'omp@agents.local'
process.env.HULY_PASSWORD = fs.readFileSync(path.join(process.env.HOME, '.config/huly/omp.password'), 'utf8').trim()
process.env.HULY_ACCOUNTS_URL = 'http://localhost:8087/_accounts'
process.env.HULY_WORKSPACE = 'jack'

// npx puts the package's node_modules/.bin on PATH; its node_modules is the parent.
const bin = (process.env.PATH || '').split(':').find((dir) => dir.includes('_npx') && dir.endsWith('node_modules/.bin'))
if (!bin) throw new Error('run through npx -p huly-mcp-selfhost (see the header)')
const modules = path.dirname(bin)
const conn = require(path.join(modules, 'huly-mcp-selfhost/dist/connection.js'))
const tracker = require(path.join(modules, '@hcengineering/tracker')).default
const core = require(path.join(modules, '@hcengineering/core')).default

;(async () => {
  const client = await conn.getConnection('jack')
  const { accountClient } = await conn.getWorkspace('jack')
  const owners = (await accountClient.getWorkspaceMembers()).filter((m) => m.role === 'OWNER')
  // shortcut: assumes one owner (you); name the user explicitly if the workspace gets more.
  if (owners.length !== 1) throw new Error('expected one workspace owner, found ' + owners.length)
  const user = owners[0].person
  let joined = 0
  for (const project of await client.findAll(tracker.class.Project, {})) {
    if ((project.members || []).includes(user) && (project.owners || []).includes(user)) continue
    await client.updateDoc(tracker.class.Project, core.space.Space, project._id, {
      members: [...new Set([...(project.members || []), user])],
      owners: [...new Set([...(project.owners || []), user])]
    })
    joined++
    console.log('joined ' + project.identifier)
  }
  console.log(joined + ' project(s) joined')
  await conn.closeConnection()
  process.exit(0)
})().catch((error) => {
  console.error('join-projects: ' + error.message)
  process.exit(1)
})
