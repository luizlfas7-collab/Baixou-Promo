// One authorized Instagram feed launch completed on 2026-10-26.
// The fixed offer was published as media 17889470601477440.
// This endpoint cannot publish again.
Deno.serve(() => Response.json(
  { ok: false, error: "launch_completed_endpoint_retired" },
  { status: 410, headers: { "Cache-Control": "no-store" } },
))
