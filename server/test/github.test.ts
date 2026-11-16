import { expect, test } from "bun:test";
import { githubRepo, parseIssueRef } from "../src/github";

test("GitHub remotes and issue references parse; other hosts don't", () => {
  expect(githubRepo("git@github.com:acme/payments.git\n")).toBe("acme/payments");
  expect(githubRepo("https://github.com/acme/tern-flightdeck")).toBe("acme/tern-flightdeck");
  expect(githubRepo("git@gitlab.com:a/b.git")).toBeNull();
  expect(parseIssueRef("o/r#12")).toEqual({ repo: "o/r", number: 12 });
  expect(parseIssueRef("https://github.com/o/r/issues/7")).toEqual({ repo: "o/r", number: 7 });
  expect(parseIssueRef("#12")).toBeNull();
});
