// Tells Flightdeck's window and Mission control when something changed, so they
// fetch at once instead of polling often. `GET /api/events` is a stream of
// lines: the change counter, sent at once and after every change (an agent's
// tool call, a POST to the API), plus a heartbeat every HEARTBEAT_MS so idle
// connections stay open. Clients refetch on any line; the counter only helps
// them skip duplicates.
const HEARTBEAT_MS = 20_000;
const encoder = new TextEncoder();

export class Events {
  private version = 0;
  private readonly listeners = new Set<ReadableStreamDefaultController<Uint8Array>>();
  private readonly heartbeat = setInterval(() => this.send(`${this.version}`), HEARTBEAT_MS);

  // Something changed: tell every listener (coalesced to one line per tick).
  private queued = false;
  changed() {
    this.version++;
    if (this.queued) return;
    this.queued = true;
    queueMicrotask(() => { this.queued = false; this.send(`${this.version}`); });
  }

  private send(line: string) {
    const bytes = encoder.encode(line + "\n");
    for (const c of this.listeners) {
      try { c.enqueue(bytes); } catch { this.listeners.delete(c); }
    }
  }

  response(): Response {
    let self: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({
      start: (c) => { self = c; this.listeners.add(c); c.enqueue(encoder.encode(`${this.version}\n`)); },
      cancel: () => { this.listeners.delete(self); },
    });
    return new Response(stream, { headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });
  }

  stop() {
    clearInterval(this.heartbeat);
    for (const c of this.listeners) { try { c.close(); } catch { /* already gone */ } }
    this.listeners.clear();
  }
}
