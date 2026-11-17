// Extensions: other tools on this Mac (a private Tern plugin, a script) publish
// a panel of items to Flightdeck, shown as a sidebar section and a Mission
// control tab, without Flightdeck knowing what they are. An extension POSTs its
// whole panel to /api/extensions/<id> whenever it changes (and every few minutes,
// so Flightdeck can tell it's alive); buttons it defines either open a link or
// are POSTed back to its own local `callback` URL. See server/README.md.
import type { Database } from "bun:sqlite";
import { z } from "zod";

const TONES = ["working", "waiting", "done", "failed", "idle"] as const;

const Action = z.object({
  id: z.string().min(1).max(64),
  label: z.string().min(1).max(40),
  primary: z.boolean().optional(),
  // Opens this link instead of calling back.
  url: z.string().url().optional(),
  // Asks for text first (the placeholder); sent as `text`.
  input: z.string().max(200).optional(),
  // Asks "are you sure" with this sentence first.
  confirm: z.string().max(300).optional(),
});

const Item = z.object({
  // Letters, digits and . _ : - (it travels inside Mission control's button actions).
  id: z.string().regex(/^[\w.:-]{1,128}$/, "letters, digits and . _ : - only"),
  title: z.string().min(1).max(300),
  subtitle: z.string().max(300).optional(),
  status: z.object({ label: z.string().max(40), tone: z.enum(TONES) }).optional(),
  // A repository name, so Mission control's repo filter applies.
  repo: z.string().max(100).optional(),
  url: z.string().url().optional(),
  // Shown in its details: a paragraph or two, then label/value pairs.
  body: z.string().max(4000).optional(),
  facts: z.array(z.tuple([z.string().max(40), z.string().max(300)])).max(12).optional(),
  actions: z.array(Action).max(6).optional(),
});

const Section = z.object({
  title: z.string().min(1).max(60),
  // Also listed in the sidebar, under the extension's title.
  sidebar: z.boolean().optional(),
  items: z.array(Item).max(100),
});

export const Panel = z.object({
  title: z.string().min(1).max(30),
  url: z.string().url().optional(),
  // Where Flightdeck POSTs { item, action, text? } when a call-back button is pressed: loopback only.
  callback: z.string().url().refine((u) => ["127.0.0.1", "localhost", "[::1]"].includes(new URL(u).hostname),
    "callback must be on this Mac (127.0.0.1 or localhost)").optional(),
  sections: z.array(Section).max(8),
});
export type Panel = z.infer<typeof Panel>;

const ID = /^[a-z][a-z0-9-]{0,31}$/;
// An extension silent this long is shown as stale; one silent for a day is dropped.
const DROP_MS = 86_400_000;

export class Extensions {
  constructor(private readonly db: Database, private readonly now = () => Date.now()) {
    db.run("create table if not exists extensions (id text primary key, panel text not null, updated integer not null)");
  }

  publish(id: string, body: unknown): void {
    if (!ID.test(id)) throw new Error("extension id: lowercase letters, digits and dashes, starting with a letter");
    const parsed = Panel.safeParse(body);
    if (!parsed.success) throw new Error(parsed.error.issues.slice(0, 5).map((i) => `${i.path.join(".") || "panel"}: ${i.message}`).join("; "));
    const panel = parsed.data;
    this.db.query("insert into extensions (id, panel, updated) values (?, ?, ?) on conflict(id) do update set panel = excluded.panel, updated = excluded.updated")
      .run(id, JSON.stringify(panel), this.now());
  }

  remove(id: string): void {
    this.db.query("delete from extensions where id = ?").run(id);
  }

  list(): (Panel & { id: string; updated: number })[] {
    this.db.query("delete from extensions where updated < ?").run(this.now() - DROP_MS);
    const rows = this.db.query("select id, panel, updated from extensions order by id").all() as { id: string; panel: string; updated: number }[];
    return rows.map((r) => ({ ...(JSON.parse(r.panel) as Panel), id: r.id, updated: r.updated }));
  }

  // A call-back button: checks the item has it (so the UI can only press real buttons), then POSTs to the extension.
  async act(id: string, item: string, action: string, text?: string): Promise<{ ok: boolean; message?: string }> {
    const ext = this.list().find((e) => e.id === id);
    if (!ext) throw new Error(`no extension ${id}`);
    const it = ext.sections.flatMap((s) => s.items).find((i) => i.id === item);
    const a = it?.actions?.find((x) => x.id === action);
    if (!it || !a) throw new Error(`${ext.title} has no button ${action} on ${item}`);
    if (a.url) throw new Error("that button opens a link");
    if (!ext.callback) throw new Error(`${ext.title} takes no calls back`);
    if (a.input && !text?.trim()) throw new Error("that button needs text");
    const res = await fetch(ext.callback, { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ item, action, text }), signal: AbortSignal.timeout(30_000) })
      .catch((e: Error) => { throw new Error(`${ext.title} didn't answer: ${e.message}`); });
    const reply = await res.json().catch(() => ({})) as { ok?: boolean; message?: string };
    return { ok: res.ok && reply.ok !== false, message: typeof reply.message === "string" ? reply.message.slice(0, 300) : undefined };
  }
}
