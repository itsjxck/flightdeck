# Flightdeck: rules for agents

## Public repository: no private references

This repository is public. Never commit anything that identifies the maintainer's employer, its organisation, or its private projects, services, hosts or infrastructure: not in code, tests, fixtures, docs, screenshots, examples or commit messages.

- Use made-up names in examples and tests: `web-app`, `api`, `example-org`, `Acme CI`, `ci.example`.
- Screenshots come from the isolated showcase (`scripts/showcase.sh`), never from a real Tern window.
- Agent instructions in the code stay generic ("another agent platform's MCP tools"), not named products.
- A local `pre-commit` and `commit-msg` hook (in `.git/hooks`, not committed, so the names stay private) refuses commits that mention them. Don't bypass it with `--no-verify`; replace the name instead.
