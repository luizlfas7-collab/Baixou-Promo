type Dependencies = {
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
};

const BASIC = "instagram_business_basic";
const PUBLISH = "instagram_business_content_publish";
const headers = { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers });

// Compare digests: never authorize from an unverified JWT role claim.
async function equalSecret(a: string, b: string): Promise<boolean> {
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [left, right] = await Promise.all([digest(a), digest(b)]);
  let diff = 0;
  for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i];
  return diff === 0;
}

export function createHandler(deps: Dependencies) {
  return async (req: Request): Promise<Response> => {
    try {
      const adminKey = deps.env("SUPABASE_SERVICE_ROLE_KEY");
      if (!adminKey) return json(503, { ok: false, error: "admin_auth_not_configured" });
      const match = /^Bearer ([^\s]+)$/i.exec(req.headers.get("Authorization") ?? "");
      // Dashboard's test proxy can replace Authorization with its own JWT.
      // Keep gateway JWT verification AND independently validate the admin key.
      const supplied = req.headers.get("X-Baixou-Admin-Key") ?? match?.[1];
      let authorized = !!supplied && await equalSecret(supplied, adminKey);
      // A rotated dashboard service-role JWT can differ from the injected key.
      // Auth's admin-only endpoint cryptographically validates it and enforces
      // the admin role. Never decode claims or consume/return the user response.
      if (!authorized && supplied && supplied.split(".").length === 3) {
        const projectUrl = deps.env("SUPABASE_URL");
        const anonKey = deps.env("SUPABASE_ANON_KEY");
        if (projectUrl && anonKey) {
          try {
            const validation = await deps.fetch(`${projectUrl}/auth/v1/admin/users?page=1&per_page=1`, {
              method: "GET",
              headers: { Authorization: `Bearer ${supplied}`, apikey: anonKey },
              redirect: "error", signal: AbortSignal.timeout(5000),
            });
            authorized = validation.status === 200;
            await validation.body?.cancel();
          } catch { /* Fail closed when authentication cannot be verified. */ }
        }
      }
      if (!authorized) {
        return json(401, { ok: false, error: "unauthorized" });
      }
      if (req.method !== "GET") return new Response(JSON.stringify({ ok: false, error: "method_not_allowed" }), { status: 405, headers: { ...headers, Allow: "GET" } });
      // Reject arbitrary targets/fields/token overrides; this is a fixed, read-only diagnostic.
      if (new URL(req.url).search) return json(400, { ok: false, error: "query_parameters_not_allowed" });
      const token = deps.env("INSTAGRAM_ACCESS_TOKEN")?.trim();
      if (!token) return json(503, { ok: false, error: "instagram_token_not_configured" });
      const read = async (path: string) => {
        const res = await deps.fetch(`https://graph.instagram.com${path}`, {
          method: "GET",
          headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
          redirect: "error",
          signal: AbortSignal.timeout(10000),
        });
        // Never return/log raw Meta errors: they may contain sensitive values.
        const body = await res.json().catch(() => null);
        return { status: res.status, ok: res.ok, body };
      };
      const profile = await read("/me?fields=id,username,account_type");
      if (!profile.ok || profile.body?.error) {
        const code = profile.body?.error?.code;
        return json(502, {
          ok: false, error: code === 190 ? "instagram_token_invalid_or_expired" : "instagram_profile_failed",
          upstream_status: profile.status,
          meta_code: typeof code === "number" ? code : null,
        });
      }
      const p = profile.body;
      if (!p || typeof p.id !== "string" || !/^\d{1,40}$/.test(p.id) || typeof p.username !== "string" || !/^[A-Za-z0-9_.]{1,30}$/.test(p.username) || !["BUSINESS", "MEDIA_CREATOR", "CREATOR"].includes(p.account_type)) {
        return json(502, { ok: false, error: "unexpected_or_nonprofessional_profile" });
      }
      // Best-effort explicit scope introspection. A successful profile read alone
      // does not prove content publishing permission, app review or token lifetime.
      let permissions: { basic: string; content_publish: string; check: string } = {
        basic: "effective_profile_read", content_publish: "unverified", check: "unavailable",
      };
      try {
        const scopes = await read("/me/permissions");
        const rows = scopes.body?.data;
        if (scopes.ok && !scopes.body?.error && Array.isArray(rows) && rows.length > 0 && rows.every((r: { permission?: unknown; status?: unknown }) => typeof r.permission === "string" && typeof r.status === "string")) {
          const granted = (name: string) => rows.some((r: { permission: string; status: string }) => r.permission === name && r.status === "granted");
          permissions = { basic: granted(BASIC) ? "granted" : "not_granted", content_publish: granted(PUBLISH) ? "granted" : "not_granted", check: "verified" };
        }
      } catch { /* Unsupported/timeout is explicitly unverified, never granted. */ }
      return json(200, {
        ok: true, authentication: "verified", read_only: true,
        account: { id: p.id, username: p.username, account_type: p.account_type },
        permissions, required_permission: BASIC,
        publishing_tested: false, token_expiry: "unverified",
      });
    } catch {
      return json(502, { ok: false, error: "instagram_request_failed" });
    }
  };
}
