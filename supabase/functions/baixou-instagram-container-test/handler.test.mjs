import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHandler,TEST_IMAGE_URL} from './handler.ts';
const env=n=>({SUPABASE_SERVICE_ROLE_KEY:'admin',INSTAGRAM_ACCESS_TOKEN:'secret-token'})[n];
const request=(body={action:'create_test_container'},auth='admin')=>new Request('https://example.test',{method:'POST',headers:{Authorization:`Bearer ${auth}`},body:JSON.stringify(body)});
test('rejects unauthorized and arbitrary inputs before any upstream access',async()=>{
const h=createHandler({env,creationEnabled:true,creationDeadline:Infinity,fetch:async()=>{throw Error('unexpected fetch')}});
assert.equal((await h(request({},'anon'))).status,401);
assert.equal((await h(request({action:'publish'}))).status,400);
assert.equal((await h(request({action:'create_test_container',image_url:'https://evil.test'}))).status,400);
});
test('creates only fixed test image, checks status and never publishes or retries',async()=>{
const calls=[]; const replies=[{id:'29009902871968723',username:'_baixoupromocoes_'},{id:'123456'},{status_code:'FINISHED'}];
const h=createHandler({env,creationEnabled:true,creationDeadline:Infinity,fetch:async(url,opts)=>{calls.push({url,opts});return Response.json(replies.shift());}});
const r=await h(request()); assert.equal(r.status,200); const body=await r.json();assert.equal(body.published,false);assert.equal(body.status_code,'FINISHED');
assert.deepEqual(calls.map(c=>c.opts.method),['GET','POST','GET']);assert.equal(calls[1].opts.body.get('image_url'),TEST_IMAGE_URL);assert.ok(!calls.some(c=>c.url.includes('media_publish')));assert.ok(!JSON.stringify(body).includes('secret-token'));
assert.equal((await h(request())).status,409);assert.equal(calls.length,3);
});
test('sanitizes upstream failure and does not retry creation',async()=>{
let i=0;const h=createHandler({env,creationEnabled:true,creationDeadline:Infinity,fetch:async()=>++i===1?Response.json({id:'29009902871968723',username:'_baixoupromocoes_'}):Response.json({error:{code:10,message:'secret-token'}},{status:400})});
const r=await h(request());assert.equal(r.status,502);const body=await r.json();assert.equal(body.meta_code,10);assert.ok(!JSON.stringify(body).includes('secret-token'));assert.equal((await h(request())).status,409);
});
test('refuses another Instagram account before creation',async()=>{
const h=createHandler({env,creationEnabled:true,creationDeadline:Infinity,fetch:async()=>Response.json({id:'999',username:'someone_else'})});assert.equal((await h(request())).status,403);
});

test('production defaults deny new containers without contacting Instagram',async()=>{
const h=createHandler({env,fetch:async()=>{throw Error('unexpected fetch')}});
assert.equal((await h(request())).status,410);
});
test('status query reads only the previously created container',async()=>{
const calls=[];const h=createHandler({env,fetch:async(url,opts)=>{calls.push({url,opts});return Response.json({status_code:'FINISHED'});}});
const r=await h(new Request('https://example.test',{headers:{Authorization:'Bearer admin'}}));const b=await r.json();assert.equal(b.status_code,'FINISHED');assert.equal(b.creation_enabled,false);assert.equal(b.published,false);assert.equal(calls.length,1);assert.equal(calls[0].opts.method,'GET');assert.ok(calls[0].url.includes('/17926039089201655?fields=status_code'));
});
