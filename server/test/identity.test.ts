import { expect, test } from "bun:test";
import { repoName, repoRoot, sessionFromArgv, sessionFromLsof } from "../src/identity";

const ID = "01a1ceb5-0463-75df-9c37-f67a82704600";

test("session from --resume and --restore", () => {
  expect(sessionFromArgv(["omp", "--resume", ID])).toBe(ID);
  expect(sessionFromArgv(["/x/omp", "--restore", `/h/.omp/agent/sessions/-p/2026-11-12T07-42-12-067Z_${ID}.jsonl`])).toBe(ID);
  expect(sessionFromArgv(["omp"])).toBeNull();
});

test("session from the open session file", () => {
  const lsof = `p1627\nn/dev/ttys004\nn/Users/j/.omp/agent/sessions/-projects-x/2026-11-12T07-42-12-067Z_${ID}.jsonl\n`;
  expect(sessionFromLsof(lsof)).toEqual({ session: ID, pid: "1627" });
  expect(sessionFromLsof("p1\nn/tmp/other.jsonl\n")).toBeNull();
});

test("repository name from the common git dir", () => {
  expect(repoName("/Users/j/projects/web-app/.git")).toBe("web-app");
  expect(repoName("/Users/j/projects/tern-plugins/overseer/.git")).toBe("overseer");
});

test("repository root from the common git dir", () => {
  expect(repoRoot("/Users/j/projects/web-app/.git")).toBe("/Users/j/projects/web-app");
});
