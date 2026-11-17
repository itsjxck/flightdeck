import { describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { Extensions } from "../src/extensions";

const panel = (callback?: string) => ({
  title: "Owl", callback,
  sections: [{ title: "Workstreams", sidebar: true, items: [
    { id: "w1", title: "Ship it", status: { label: "Needs you", tone: "waiting" },
      actions: [{ id: "answer", label: "Answer", input: "Your answer" }, { id: "web", label: "Open", url: "https://example.com/w1" }] }] }],
});

describe("extensions", () => {
  test("publish replaces the panel; bad panels and ids are refused with a readable reason", () => {
    const ext = new Extensions(new Database(":memory:"));
    ext.publish("owl", panel());
    ext.publish("owl", { ...panel(), title: "web-app" });
    expect(ext.list().map((e) => [e.id, e.title])).toEqual([["owl", "web-app"]]);
    expect(() => ext.publish("Owl!", panel())).toThrow("extension id");
    expect(() => ext.publish("owl", { title: "x", sections: [{ title: "s", items: [{ id: "", title: "t" }] }] })).toThrow("sections.0.items.0.id");
    expect(() => ext.publish("owl", panel("https://evil.example/cb"))).toThrow("on this Mac");
  });

  test("a silent extension is dropped after a day", () => {
    let now = 0;
    const ext = new Extensions(new Database(":memory:"), () => now);
    ext.publish("owl", panel());
    now = 86_400_001;
    expect(ext.list()).toEqual([]);
  });

  test("buttons call back only when the item has them, with the text they asked for", async () => {
    const got: unknown[] = [];
    const server = Bun.serve({ port: 0, fetch: async (req) => { got.push(await req.json()); return Response.json({ ok: true, message: "Sent." }); } });
    try {
      const ext = new Extensions(new Database(":memory:"));
      ext.publish("owl", panel(`http://127.0.0.1:${server.port}/cb`));
      expect(await ext.act("owl", "w1", "answer", "yes")).toEqual({ ok: true, message: "Sent." });
      expect(got).toEqual([{ item: "w1", action: "answer", text: "yes" }]);
      await expect(ext.act("owl", "w1", "answer", " ")).rejects.toThrow("needs text");
      await expect(ext.act("owl", "w1", "delete")).rejects.toThrow("no button");
      await expect(ext.act("owl", "w1", "web")).rejects.toThrow("opens a link");
    } finally { server.stop(true); }
  });
});
