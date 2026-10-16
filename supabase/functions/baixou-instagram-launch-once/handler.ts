const HASH = '600247ef4274a1507e96e9eab144ab4c853cfd639f07660fad94464136566284';
const EXPIRES = 1792109907188;
const ACCOUNT = '29009902871968723';
const ROW = 3;
const VIDEO = 'https://d2ol7oe51mr4n9.cloudfront.net/user_3JERl3pgdS1E5NYpOLY1ddnZCW5/e8641597-f214-42eb-968f-b517207156f4.mp4';
const PROJECT = 'https://xxskmxhpzbqzxoaffiul.supabase.co';
type Deps = {env:(key:string)=>string|undefined; fetch:typeof fetch; approvalHash?:string; expiresAt?:number};
const reply=(status:number,body:unknown)=>Response.json(body,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
export function createHandler(deps:Deps) {
 return async(req:Request)=>{
  let stage='authentication';
  try {
   const nonce=req.headers.get('X-Launch-Approval')??'';
   const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(nonce)))).map(x=>x.toString(16).padStart(2,'0')).join('');
   const expected=deps.approvalHash??HASH;
   let different=0;for(let i=0;i<expected.length;i++)different|=expected.charCodeAt(i)^digest.charCodeAt(i);
   if(!nonce||different||Date.now()>(deps.expiresAt??EXPIRES))return reply(401,{ok:false,error:'unauthorized_or_expired'});
   if(req.method!=='POST'||new URL(req.url).search)return reply(405,{ok:false,error:'method_not_allowed'});
   const input=await req.text();if(input.length>100)return reply(400,{ok:false,error:'invalid_action'});
   let body;try{body=JSON.parse(input);}catch{return reply(400,{ok:false,error:'invalid_action'});}
   if(!body||Object.keys(body).length!==1||!['inspect','prepare','status','publish'].includes(body.action))return reply(400,{ok:false,error:'invalid_action'});
   const token=deps.env('INSTAGRAM_ACCESS_TOKEN');const admin=deps.env('SUPABASE_SERVICE_ROLE_KEY');
   if(!token||!admin)return reply(503,{ok:false,error:'missing_server_configuration'});
   const db=async(path:string,method='GET',data?:unknown)=>{
    const r=await deps.fetch(PROJECT+'/rest/v1/'+path,{method,headers:{Authorization:'Bearer '+admin,apikey:admin,'Content-Type':'application/json',Prefer:'return=representation'},body:data===undefined?undefined:JSON.stringify(data),redirect:'error',signal:AbortSignal.timeout(12000)});
    if(!r.ok)throw Error('db_failed');return await r.json();
   };
   const meta=async(path:string,method='GET',data?:URLSearchParams)=>{
    const r=await deps.fetch('https://graph.instagram.com'+path,{method,headers:{Authorization:'Bearer '+token},body:data,redirect:'error',signal:AbortSignal.timeout(20000)});
    const d=await r.json().catch(()=>null);
    return {ok:r.ok&&!d?.error,data:d,status:r.status,code:typeof d?.error?.code==='number'?d.error.code:null,subcode:typeof d?.error?.error_subcode==='number'?d.error.error_subcode:null};
   };
   const errorMeta=(r:any)=>reply(502,{ok:false,stage,error:'instagram_rejected',upstream_status:r.status,meta_code:r.code,meta_subcode:r.subcode,retry:false});
   const row=(await db('instagram_publicacoes?id=eq.'+ROW+'&select=*'))[0];
   if(!row||row.oferta_id!==29756||row.formato!=='story'||row.imagem_url!==VIDEO||row.url_afiliado!=='https://meli.la/2s7NDdV')return reply(409,{ok:false,error:'approval_row_mismatch'});
   if(body.action==='inspect'){
    stage='profile';const me=await meta('/me?fields=id,username,account_type');if(!me.ok)return errorMeta(me);
    const stories=await meta('/'+ACCOUNT+'/stories?fields=id,media_type,timestamp');
    return reply(200,{ok:true,account:me.data,stories:stories.ok?stories.data.data:[],row:{id:row.id,situacao:row.situacao,container_id:row.id_container_meta,media_id:row.id_midia_meta}});
   }
   if(body.action==='prepare'){
    if(row.situacao!=='aprovada'||row.id_container_meta||row.id_midia_meta)return reply(409,{ok:false,error:'already_started',situacao:row.situacao});
    stage='profile';const me=await meta('/me?fields=id,username,account_type');if(!me.ok)return errorMeta(me);
    if(me.data.id!==ACCOUNT||me.data.username!=='_baixoupromocoes_'||me.data.account_type!=='BUSINESS')return reply(409,{ok:false,error:'business_account_required'});
    const offer=(await db('ofertas?id=eq.29756&select=preco_atual,disponivel,visto_ultimo_em,url_afiliado'))[0];
    if(!offer||Number(offer.preco_atual)!==145||!offer.disponivel||offer.url_afiliado!==row.url_afiliado||Date.now()-Date.parse(offer.visto_ultimo_em)>1800000)return reply(409,{ok:false,error:'offer_changed_or_stale'});
    const stories=await meta('/'+ACCOUNT+'/stories?fields=id,timestamp');
    if(!stories.ok)return errorMeta(stories);
    if(stories.data.data?.length)return reply(409,{ok:false,error:'existing_story_requires_review'});
    // Durable compare-and-set BEFORE the external side effect. Never retry creation.
    const claim=await db('instagram_publicacoes?id=eq.'+ROW+'&situacao=eq.aprovada','PATCH',{situacao:'processando',erro_ultimo:'container_creation_started'});
    if(claim.length!==1)return reply(409,{ok:false,error:'already_claimed'});
    stage='create_story_container';
    const created=await meta('/'+ACCOUNT+'/media','POST',new URLSearchParams({media_type:'STORIES',video_url:VIDEO}));
    if(!created.ok){await db('instagram_publicacoes?id=eq.'+ROW,'PATCH',{situacao:'revisao',erro_ultimo:'container_rejected_code_'+created.code});return errorMeta(created);}
    if(typeof created.data?.id!=='string'||!/^\d{1,40}$/.test(created.data.id))throw Error('bad_container');
    await db('instagram_publicacoes?id=eq.'+ROW,'PATCH',{id_container_meta:created.data.id,erro_ultimo:null});
    return reply(200,{ok:true,container_id:created.data.id,published:false});
   }
   if(!row.id_container_meta||!/^\d{1,40}$/.test(row.id_container_meta))return reply(409,{ok:false,error:'no_container'});
   stage='container_status';const state=await meta('/'+row.id_container_meta+'?fields=status_code');if(!state.ok)return errorMeta(state);
   if(body.action==='status')return reply(200,{ok:true,container_id:row.id_container_meta,status_code:state.data.status_code,situacao:row.situacao,media_id:row.id_midia_meta});
   if(row.situacao==='publicada')return reply(200,{ok:true,already_published:true,media_id:row.id_midia_meta});
   if(row.situacao!=='processando'||state.data.status_code!=='FINISHED')return reply(409,{ok:false,error:'not_publishable',situacao:row.situacao,status_code:state.data.status_code});
   // Quarantine before publish. Timeout/unknown outcome NEVER causes a second send.
   const claim=await db('instagram_publicacoes?id=eq.'+ROW+'&situacao=eq.processando&erro_ultimo=is.null','PATCH',{situacao:'revisao',erro_ultimo:'publish_started_do_not_retry'});
   if(claim.length!==1)return reply(409,{ok:false,error:'publish_already_attempted'});
   stage='publish_story';const published=await meta('/'+ACCOUNT+'/media_publish','POST',new URLSearchParams({creation_id:row.id_container_meta}));
   if(!published.ok)return errorMeta(published);
   if(typeof published.data?.id!=='string'||!/^\d{1,40}$/.test(published.data.id))throw Error('bad_media_id');
   const mediaId=published.data.id;
   await db('instagram_publicacoes?id=eq.'+ROW,'PATCH',{situacao:'publicada',id_midia_meta:mediaId,publicada_em:new Date().toISOString(),erro_ultimo:null});
   return reply(200,{ok:true,published:true,media_id:mediaId,container_id:row.id_container_meta});
  }catch{return reply(502,{ok:false,stage,error:'request_failed_or_outcome_unknown',retry:false});}
 };
}
