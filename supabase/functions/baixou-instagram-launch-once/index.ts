// One authorized launch completed. No further writes are possible from this entrypoint.
Deno.serve(() => Response.json({ok:false,error:'launch_completed_endpoint_retired'},{status:410,headers:{'Cache-Control':'no-store'}}));
