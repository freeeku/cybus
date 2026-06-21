import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleRequest, type CacheLike } from "./worker";

// ---------------------------------------------------------------------------
// MockCache — minimal in-memory Cache used by tests
// ---------------------------------------------------------------------------

class MockCache implements CacheLike {
  private store = new Map<string, Response>();

  async match(request: RequestInfo | URL): Promise<Response | undefined> {
    const key = keyOf(request);
    const stored = this.store.get(key);
    return stored ? stored.clone() : undefined;
  }

  async put(request: RequestInfo | URL, response: Response): Promise<void> {
    this.store.set(keyOf(request), response.clone());
  }
}

function keyOf(req: RequestInfo | URL): string {
  if (typeof req === "string") return req;
  if (req instanceof URL) return req.toString();
  return req.url;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function validProtoBody(): ArrayBuffer {
  // Minimal valid-looking GTFS-RT: first byte 0x0A (field 1, wire type 2)
  return new Uint8Array([0x0a, 0x02, 0x08, 0x01]).buffer;
}

function makeDeps(
  fetchFn: typeof fetch = vi.fn(),
  cache: CacheLike = new MockCache(),
) {
  return { fetchFn, cache };
}

function get(path: string) {
  return new Request(`http://worker.test${path}`);
}

// ---------------------------------------------------------------------------
// /health
// ---------------------------------------------------------------------------

describe("GET /health", () => {
  it("returns 200 JSON with ok:true", async () => {
    const res = await handleRequest(get("/health"), makeDeps());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ ok: true, service: "cybus-proxy" });
  });

  it("includes cache_ttl in the payload", async () => {
    const res = await handleRequest(get("/health"), makeDeps());
    const body = await res.json();
    expect(typeof body.cache_ttl).toBe("number");
    expect(body.cache_ttl).toBeGreaterThan(0);
  });

  it("sets Cache-Control: no-store", async () => {
    const res = await handleRequest(get("/health"), makeDeps());
    expect(res.headers.get("cache-control")).toBe("no-store");
  });
});

// ---------------------------------------------------------------------------
// Unknown routes
// ---------------------------------------------------------------------------

describe("unknown route", () => {
  it("returns 404", async () => {
    const res = await handleRequest(get("/unknown"), makeDeps());
    expect(res.status).toBe(404);
  });
});

// ---------------------------------------------------------------------------
// /gtfs-rt — method guard
// ---------------------------------------------------------------------------

describe("POST /gtfs-rt", () => {
  it("returns 405", async () => {
    const req = new Request("http://worker.test/gtfs-rt", { method: "POST" });
    const res = await handleRequest(req, makeDeps());
    expect(res.status).toBe(405);
  });
});

// ---------------------------------------------------------------------------
// /gtfs-rt — cache hit
// ---------------------------------------------------------------------------

describe("GET /gtfs-rt — cache hit", () => {
  it("returns cached response without calling upstream", async () => {
    const cache = new MockCache();
    // Pre-populate the cache with a snapshot
    await cache.put(
      new Request("https://cybus-internal/gtfs-rt-snapshot"),
      new Response(validProtoBody(), {
        status: 200,
        headers: { "Content-Type": "application/octet-stream" },
      }),
    );

    const fetchFn = vi.fn<typeof fetch>();
    const res = await handleRequest(get("/gtfs-rt"), { fetchFn, cache });

    expect(fetchFn).not.toHaveBeenCalled();
    expect(res.status).toBe(200);
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });
});

// ---------------------------------------------------------------------------
// /gtfs-rt — cache miss, valid upstream
// ---------------------------------------------------------------------------

describe("GET /gtfs-rt — cache miss, valid upstream", () => {
  let fetchFn: ReturnType<typeof vi.fn>;
  let cache: MockCache;

  beforeEach(() => {
    cache = new MockCache();
    fetchFn = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(validProtoBody(), {
        status: 200,
        headers: { "Content-Type": "application/octet-stream" },
      }),
    );
  });

  it("returns 200 with application/octet-stream", async () => {
    const res = await handleRequest(get("/gtfs-rt"), { fetchFn, cache });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/octet-stream");
  });

  it("sets CORS header", async () => {
    const res = await handleRequest(get("/gtfs-rt"), { fetchFn, cache });
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });

  it("sets Cache-Control with max-age", async () => {
    const res = await handleRequest(get("/gtfs-rt"), { fetchFn, cache });
    expect(res.headers.get("cache-control")).toMatch(/max-age=\d+/);
  });

  it("stores response in cache for subsequent requests", async () => {
    await handleRequest(get("/gtfs-rt"), { fetchFn, cache });
    // Second request should hit cache, not upstream
    await handleRequest(get("/gtfs-rt"), { fetchFn, cache });
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// /gtfs-rt — upstream errors
// ---------------------------------------------------------------------------

describe("GET /gtfs-rt — upstream errors", () => {
  it("returns 502 when upstream fetch throws", async () => {
    const fetchFn = vi.fn<typeof fetch>().mockRejectedValue(new Error("ECONNREFUSED"));
    const res = await handleRequest(get("/gtfs-rt"), makeDeps(fetchFn));
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.error).toBe("Upstream fetch failed");
  });

  it("returns 502 when upstream returns non-200", async () => {
    const fetchFn = vi.fn<typeof fetch>().mockResolvedValue(
      new Response("Bad Gateway", { status: 503 }),
    );
    const res = await handleRequest(get("/gtfs-rt"), makeDeps(fetchFn));
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.error).toBe("Upstream returned non-200");
  });

  it("returns 502 when content-length header exceeds limit", async () => {
    const fetchFn = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(new Uint8Array(1), {
        status: 200,
        headers: { "content-length": String(6 * 1024 * 1024) },
      }),
    );
    const res = await handleRequest(get("/gtfs-rt"), makeDeps(fetchFn));
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.error).toBe("Upstream payload exceeds size limit");
  });

  it("returns 502 when body exceeds size limit after streaming", async () => {
    const big = new Uint8Array(6 * 1024 * 1024);
    big[0] = 0x0a; // valid magic so only size check triggers
    const fetchFn = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(big, { status: 200 }),
    );
    const res = await handleRequest(get("/gtfs-rt"), makeDeps(fetchFn));
    expect(res.status).toBe(502);
  });

  it("returns 502 when upstream returns empty body", async () => {
    const fetchFn = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(new Uint8Array(0), { status: 200 }),
    );
    const res = await handleRequest(get("/gtfs-rt"), makeDeps(fetchFn));
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.error).toBe("Upstream returned empty body");
  });

  it("returns 502 when first byte is not the GTFS-RT protobuf magic", async () => {
    const fetchFn = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(new Uint8Array([0x3c, 0x68, 0x74, 0x6d, 0x6c]), { status: 200 }), // "<html"
    );
    const res = await handleRequest(get("/gtfs-rt"), makeDeps(fetchFn));
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.error).toBe("Upstream response is not a valid GTFS-RT protobuf");
  });
});
