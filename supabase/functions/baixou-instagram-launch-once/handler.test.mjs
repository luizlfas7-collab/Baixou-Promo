import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createHandler} from './handler.ts';
const VIDEO='https://d2ol7oe51mr4n9.cloudfront.net/user_3JERl3pgdS1E5NYpOLY1ddnZCW5/e8641597-f214-42eb-968f-b517207156f4.mp4';
function fixture(state='aprovada',kind='BUSINESS',price=145){
const row={id:3,oferta_id:29756,formato:'story',situacao:state,imagem_url:VIDEO,url_afiliado:'https://meli.la/2s7NDdV',id_container_meta:state==='processando'?'123':null,id_midia_meta:null,erro_ultimo:null};
const calls=[];
const handler=createHandler({approvalHash:createHash('sha256').update('test-nonce').digest('hex'),expiresAt:Date.now()+60000,env:k=>({INSTAGRAM_ACCESS_TOKEN:'instagram-secret',SUPABASE_SERVICE_ROLE_KEY:'admin-secret'})[k],fetch:async(url,opts={})=>{
calls.push({url,opts});let data;
if(url.includes('/rest/v1/instagram_publicacoes')){
if(opts.method==='PATCH'){
 if(url.includes('situacao=eq.aprovada')&&row.situacao!=='aprovada')return Response.json([]);
 if(url.includes('situacao=eq.processando')&&(row.situacao!=='processando'||row.erro_ultimo!==null))return Response.json([]);
 Object.assign(row,JSON.parse(opts.body));
} data=[{...row}];
}else if(url.includes('/rest/v1/ofertas'))data=[{preco_atual:price,disponivel:true,url_afiliado:row.url_afiliado,visto_ultimo_em:new Date().toISOString()}];
else if(url.includes('/me?'))data={id:'29009902871968723',username:'_baixoupromocoes_',account_type:kind};
else if(url.includes('/stories?'))data={data:[]};
else if(url.endsWith('/media'))data={id:'123'};
else if(url.includes('?fields=status_code'))data={status_code:'FINISHED'};
else if(url.endsWith('/media_publish')){assert.equal(row.situacao,'revisao');assert.equal(row.erro_ultimo,'publish_started_do_not_retry');data={id:'456'};}
else throw Error('unexpected '+url);
return Response.json(data);
}});
const run=(action,nonce='test-nonce')=>handler(new Request('https://example.test',{method:'POST',headers:{'X-Launch-Approval':nonce},body:JSON.stringify({action})}));return {run,row,calls};
}
test('rejects missing/wrong approval before any server calls',async()=>{const s=fixture();assert.equal((await s.run('prepare','wrong')).status,401);assert.equal(s.calls.length,0);});
test('refuses creator accounts and changed prices without creation',async()=>{for(const s of [fixture('aprovada','MEDIA_CREATOR'),fixture('aprovada','BUSINESS',146)]){assert.equal((await s.run('prepare')).status,409);assert.ok(!s.calls.some(c=>c.url.endsWith('/media')));}});
test('creates one STORIES container with exact approved video; second attempt blocked',async()=>{const s=fixture();assert.equal((await s.run('prepare')).status,200);assert.equal(s.row.id_container_meta,'123');assert.equal((await s.run('prepare')).status,409);const post=s.calls.filter(c=>c.url.endsWith('/media'));assert.equal(post.length,1);assert.equal(post[0].opts.body.get('media_type'),'STORIES');assert.equal(post[0].opts.body.get('video_url'),VIDEO);assert.ok(!post[0].url.includes('instagram-secret'));});
test('durably quarantines before publishing and records success exactly once',async()=>{const s=fixture('processando');const r=await s.run('publish');assert.equal(r.status,200);assert.equal((await r.json()).published,true);assert.equal(s.row.situacao,'publicada');assert.equal(s.row.id_midia_meta,'456');assert.equal((await s.run('publish')).status,200);assert.equal(s.calls.filter(c=>c.url.endsWith('/media_publish')).length,1);});
test('uncertain publication state never retries',async()=>{const s=fixture('revisao');s.row.id_container_meta='123';assert.equal((await s.run('publish')).status,409);assert.ok(!s.calls.some(c=>c.url.endsWith('/media_publish')));});
