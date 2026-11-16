import { expect, test } from "bun:test";
import { githubRepo, parseIssueRef } from "../src/github";

test("GitHub remotes and issue references parse; other hosts don't", () => {
  expect(githubRepo("git@github.com:example-org/api-server.git\n")).toBe("example-org/api-server");
  expect(githubRepo("https://github.com/itsjxck/tern-overseer")).toBe("itsjxck/tern-overseer");
  expect(githubRepo("git@gitlab.com:a/b.git")).toBeNull();
  expect(parseIssueRef("o/r#12")).toEqual({ repo: "o/r", number: 12 });
  expect(parseIssueRef("https://github.com/o/r/issues/7")).toEqual({ repo: "o/r", number: 7 });
  expect(parseIssueRef("#12")).toBeNull();
});
