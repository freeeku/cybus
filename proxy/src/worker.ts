/**
 * Cybus realtime proxy — Cloudflare Worker
 *
 * Fetches the CyNAP GTFS-RT protobuf feed (plain HTTP, unauthenticated) once
 * per cache window and serves an edge-cached snapshot to all devices over HTTPS.
 *
 * Why this must exist:
 *  - iOS App Transport Security blocks the upstream plain-HTTP IP:port endpoint.
 *  - Edge-caching one upstream fetch per ~60s fans it out to all devices for free.
 *
 * Endpoints:
 *  GET /gtfs-rt   → application/octet-stream (GTFS-RT FeedMessage protobuf)
 *  GET /health    → 200 OK with a small JSON status payload
 */

const UPSTREAM = "http://20.19.98.194:8328/Api/api/gtfs-realtime";

/** Cache window in seconds — matches CyNAP's "up to 1 minute" update cadence. */
const CACHE_TTL_SECONDS = 60;

/** Hard cap on accepted upstream payload (protects against oversized feeds). */
const MAX_PAYLOAD_BYTES = 5 * 1024 * 1024; // 5 MB

/** Cloudflare Cache API key — must be a valid HTTPS URL. */
const CACHE_KEY = "https://cybus-internal/gtfs-rt-snapshot";

// ---------------------------------------------------------------------------
// Testable deps interface
// ---------------------------------------------------------------------------

/** Minimal cache surface used by this worker — avoids coupling to workers-types Cache. */
export interface CacheLike {
  match(request: RequestInfo | URL): Promise<Response | undefined>;
  put(request: RequestInfo | URL, response: Response): Promise<void>;
}

export interface WorkerDeps {
  fetchFn: typeof fetch;
  cache: CacheLike;
}

// ---------------------------------------------------------------------------
// Worker entry point
// ---------------------------------------------------------------------------

export default {
  async fetch(request: Request): Promise<Response> {
    return handleRequest(request, { fetchFn: fetch, cache: caches.default });
  },
} satisfies ExportedHandler;

export async function handleRequest(
  request: Request,
  deps: WorkerDeps,
): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === "/health") {
    return healthResponse();
  }

  if (url.pathname === "/gtfs-rt") {
    return handleGtfsRt(request, deps);
  }

  return new Response("Not Found", { status: 404 });
}

// ---------------------------------------------------------------------------
// /gtfs-rt handler
// ---------------------------------------------------------------------------

async function handleGtfsRt(
  request: Request,
  { fetchFn, cache }: WorkerDeps,
): Promise<Response> {
  // Only allow GET
  if (request.method !== "GET") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const cacheRequest = new Request(CACHE_KEY);

  // 1. Try edge cache
  const cached = await cache.match(cacheRequest);
  if (cached) {
    return addCorsHeaders(cached.clone());
  }

  // 2. Fetch from upstream
  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetchFn(UPSTREAM, {
      signal: AbortSignal.timeout(10_000), // 10-second upstream timeout
    });
  } catch (err) {
    return errorResponse(502, "Upstream fetch failed", String(err));
  }

  if (!upstreamResponse.ok) {
    return errorResponse(
      502,
      "Upstream returned non-200",
      `status=${upstreamResponse.status}`
    );
  }

  // 3. Size check before reading body
  const contentLength = upstreamResponse.headers.get("content-length");
  if (contentLength && parseInt(contentLength, 10) > MAX_PAYLOAD_BYTES) {
    return errorResponse(502, "Upstream payload exceeds size limit");
  }

  const buffer = await upstreamResponse.arrayBuffer();
  if (buffer.byteLength > MAX_PAYLOAD_BYTES) {
    return errorResponse(502, "Upstream payload exceeds size limit");
  }
  if (buffer.byteLength === 0) {
    return errorResponse(502, "Upstream returned empty body");
  }

  // 4. Validate protobuf magic: first byte should be a valid field tag.
  //    Field 1 (header), wire type 2 (length-delimited) → 0x0A
  const firstByte = new Uint8Array(buffer)[0];
  if (firstByte !== 0x0a) {
    return errorResponse(
      502,
      "Upstream response is not a valid GTFS-RT protobuf",
      `first_byte=0x${firstByte.toString(16)}`
    );
  }

  // 5. Build cacheable response
  const snapshot = new Response(buffer, {
    status: 200,
    headers: {
      "Content-Type": "application/octet-stream",
      "Cache-Control": `public, max-age=${CACHE_TTL_SECONDS}`,
      "X-Cybus-Upstream-Bytes": String(buffer.byteLength),
      "X-Cybus-Fetched-At": new Date().toUTCString(),
    },
  });

  // Store in edge cache (async — don't await to avoid holding the response)
  // waitUntil would be ideal here but requires an ExecutionContext parameter;
  // the put() is fire-and-forget from the worker's perspective.
  cache.put(cacheRequest, snapshot.clone());

  return addCorsHeaders(snapshot);
}

// ---------------------------------------------------------------------------
// /health handler
// ---------------------------------------------------------------------------

function healthResponse(): Response {
  return new Response(
    JSON.stringify({ ok: true, service: "cybus-proxy", cache_ttl: CACHE_TTL_SECONDS }),
    {
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    }
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function addCorsHeaders(response: Response): Response {
  const r = new Response(response.body, response);
  // Allow the iOS app (and any future web clients) to fetch without CORS issues
  r.headers.set("Access-Control-Allow-Origin", "*");
  return r;
}

function errorResponse(status: number, message: string, detail?: string): Response {
  const body = JSON.stringify({ error: message, detail });
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
