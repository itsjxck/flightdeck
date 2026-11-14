import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { scanRepos } from "../src/repos";

test("scan finds repositories, not worktrees, nested repos or skipped folders", async () => {
  const root = mkdtempSync(join(tmpdir(), "scan-"));
  for (const dir of ["one/.git", "one/inner/.git", "deep/a/b/two/.git", "node_modules/x/.git", "skipme/three/.git"]) mkdirSync(join(root, dir), { recursive: true });
  mkdirSync(join(root, "wt"), { recursive: true });
  writeFileSync(join(root, "wt/.git"), "gitdir: elsewhere");
  const found = await scanRepos({ roots: [root], maxDepth: 5, skip: [join(root, "skipme")] });
  expect(found.map((r) => r.name)).toEqual(["one", "two"]);
});
