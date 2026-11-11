type Dependencies = {
  creationEnabled?: boolean;
  creationDeadline?: number;
  env: (name: string) => string | undefined;
  fetch: typeof fetch;
};



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


export const CREATION_ENABLED = false;
const CREATION_DEADLINE = 1792020274154;
export const TEST_IMAGE_URL = 'https://placehold.co/1080x1080.jpg?text=Baixou%20Teste';
export function createHandler(deps: Dependencies) {
  let attempted = false;
  return async (req: Request): Promise<Response> => {
    let creationAttempted = false;
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

      if (req.method === "GET" && !new URL(req.url).search) {
        const token = deps.env("INSTAGRAM_ACCESS_TOKEN")?.trim();
        if (!token) return json(503,{ok:false,error:"instagram_token_not_configured"});
        const response = await deps.fetch("https://graph.instagram.com/17926039089201655?fields=status_code",{
          method:"GET",headers:{Authorization:`Bearer ${token}`,Accept:"application/json"},
          redirect:"error",signal:AbortSignal.timeout(15000),
        });
        const data=await response.json().catch(()=>null);
        if (!response.ok || data?.error) return json(502,{ok:false,error:"status_check_failed",published:false});
        const state=["FINISHED","IN_PROGRESS","ERROR","EXPIRED","PUBLISHED"].includes(data?.status_code)?data.status_code:"UNVERIFIED";
        return json(200,{ok:true,container_id:"17926039089201655",status_code:state,creation_enabled:false,published:state==="PUBLISHED"});
      }
      if (req.method !== "POST") return json(405, {ok:false,error:"method_not_allowed"});
      if (!(deps.creationEnabled ?? CREATION_ENABLED) || Date.now() > (deps.creationDeadline ?? CREATION_DEADLINE)) return json(410, {ok:false,error:"test_creation_disabled"});
      if (new URL(req.url).search) return json(400,{ok:false,error:"query_not_allowed"});
      const input = await req.text();
      if (input.length > 128) return json(400,{ok:false,error:"invalid_request"});
      let body;
      try { body = JSON.parse(input); } catch { return json(400,{ok:false,error:"invalid_request"}); }
      if (!body || body.action !== "create_test_container" || Object.keys(body).length !== 1) return json(400,{ok:false,error:"invalid_request"});
      const token = deps.env("INSTAGRAM_ACCESS_TOKEN")?.trim();
      if (!token) return json(503,{ok:false,error:"instagram_token_not_configured"});
      if (attempted) return json(409,{ok:false,error:"already_attempted_on_instance"});
      const call = async (path: string, method = "GET", body?: URLSearchParams) => {
        const r = await deps.fetch(`https://graph.instagram.com${path}`, {
          method, body, headers:{Authorization:`Bearer ${token}`,Accept:"application/json"},
          redirect:"error",signal:AbortSignal.timeout(15000),
        });
        const data = await r.json().catch(()=>null);
        return {ok:r.ok && !data?.error,status:r.status,data};
      };
      const fail = (stage: string, result: {status:number;data:any}) => json(502,{
        ok:false,stage,published:false,creation_attempted:creationAttempted,
        upstream_status:result.status,
        meta_code:typeof result.data?.error?.code === "number"?result.data.error.code:null,
        meta_subcode:typeof result.data?.error?.error_subcode === "number"?result.data.error.error_subcode:null,
        error:"instagram_request_rejected",
      });
      const me = await call("/me?fields=id,username,account_type");
      if (!me.ok) return fail("profile",me);
      if (me.data?.id !== "29009902871968723" || me.data?.username !== "_baixoupromocoes_") return json(403,{ok:false,error:"unexpected_instagram_account"});
      // One fixed JPEG, no caption, no caller-selected destination or media.
      attempted = true;
      creationAttempted = true;
      const created = await call(`/${me.data.id}/media`,"POST",new URLSearchParams({image_url:TEST_IMAGE_URL}));
      if (!created.ok) return fail("create_container",created);
      const id = created.data?.id;
      if (typeof id !== "string" || !/^\d{1,40}$/.test(id)) return json(502,{ok:false,error:"unexpected_container_response",creation_attempted:true,published:false});
      let statusCode = "UNVERIFIED";
      try {
        const state = await call(`/${id}?fields=status_code`);
        if (state.ok && ["FINISHED","IN_PROGRESS","ERROR","EXPIRED"].includes(state.data?.status_code)) statusCode=state.data.status_code;
      } catch { /* Container already exists; never retry creation after uncertainty. */ }
      return json(200,{ok:true,account:{id:me.data.id,username:me.data.username},container_id:id,status_code:statusCode,container_creation:"accepted",publishing_tested:false,published:false});
    } catch {
      return json(502,{ok:false,error:"request_failed",creation_attempted:creationAttempted,published:false,retry_creation:false});
    }
  };
}


