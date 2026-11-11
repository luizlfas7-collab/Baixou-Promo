import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from './handler.ts';

const admin = 'test-only-admin-secret';
const token = 'test-only-instagram-secret';
function setup(responses = [], overrides = {}) {
  const calls = [];
  const env = { SUPABASE_SERVICE_ROLE_KEY: admin, INSTAGRAM_ACCESS_TOKEN: token, ...overrides };
  const handler = createHandler({ env: key => env[key], fetch: async (url, options) => {
    calls.push({url, options});
    const next = responses.shift();
    if (next instanceof Error) throw next;
    assert.ok(next, 'Unexpected upstream call');
    return new Response(JSON.stringify(next.body), {status: next.status ?? 200});
  }});
  const run = (auth = admin, method = 'GET', query = '') => handler(new Request('https://example.test/auth-test' + query, { method, headers: auth ? {Authorization: `Bearer ${auth}`} : {} }));
  return {calls, run};
}
const profile = {id:'123456',username:'baixou.teste',account_type:'BUSINESS'};

test('dashboard admin header still requires exact server-side admin secret', async () => {
  const handler = createHandler({env: name => name === 'SUPABASE_SERVICE_ROLE_KEY' ? admin : undefined, fetch: async () => {throw Error('must not fetch');}});
  for (const key of ['anon', 'forged-admin']) {
    assert.equal((await handler(new Request('https://example.test', {headers:{'X-Baixou-Admin-Key':key}}))).status,401);
  }
  assert.equal((await handler(new Request('https://example.test', {headers:{'X-Baixou-Admin-Key':admin}}))).status,503);
});

test('different admin JWT requires live admin-only Auth verification; failures stay closed', async () => {
  for (const status of [200,401,403,405,500]) {
    const calls = [];
    const handler = createHandler({env: name => ({SUPABASE_SERVICE_ROLE_KEY:admin,SUPABASE_URL:'https://project.test',SUPABASE_ANON_KEY:'anon'})[name],fetch:async (url, options)=>{
      calls.push({url,options}); return new Response('{}',{status});
    }});
    const response = await handler(new Request('https://example.test',{headers:{Authorization:'Bearer different.admin.jwt'}}));
    assert.equal(response.status,status===200?503:401);
    assert.equal(calls.length,1);
    assert.equal(calls[0].url,'https://project.test/auth/v1/admin/users?page=1&per_page=1');
    assert.equal(calls[0].options.redirect,'error');
  }
});

test('rejects absent, anonymous, forged and user credentials before Meta access', async () => {
  const s = setup();
  for (const auth of [null, 'anon', 'user-jwt', 'eyJhbGciOiJub25lIn0.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.']) {
    assert.equal((await s.run(auth)).status, 401);
  }
  assert.equal(s.calls.length, 0);
});
test('requires configured secrets, GET method and fixed query', async () => {
  assert.equal((await setup([], {SUPABASE_SERVICE_ROLE_KEY:undefined}).run()).status, 503);
  const s = setup();
  assert.equal((await s.run(admin, 'POST')).status, 405);
  assert.equal((await s.run(admin, 'GET', '?access_token=override')).status, 400);
  assert.equal(s.calls.length, 0);
  assert.equal((await setup([], {INSTAGRAM_ACCESS_TOKEN:undefined}).run()).status, 503);
});
test('reads only fixed Instagram endpoints; returns allowlisted fields and verified scopes', async () => {
  const s = setup([{body:{...profile,access_token:token}}, {body:{data:[{permission:'instagram_business_basic',status:'granted'},{permission:'instagram_business_content_publish',status:'granted'}]}}]);
  const res = await s.run();
  assert.equal(res.status,200);
  assert.equal(res.headers.get('cache-control'),'no-store');
  const body = await res.json();
  assert.deepEqual(body.account,profile);
  assert.equal(body.permissions.basic,'granted');
  assert.equal(body.permissions.content_publish,'granted');
  assert.equal(body.publishing_tested,false);
  assert.ok(!JSON.stringify(body).includes(token));
  assert.deepEqual(s.calls.map(c=>c.url), ['https://graph.instagram.com/me?fields=id,username,account_type','https://graph.instagram.com/me/permissions']);
  for (const c of s.calls) {
    assert.equal(c.options.method,'GET');
    assert.equal(c.options.headers.Authorization,`Bearer ${token}`);
    assert.equal(c.options.redirect,'error');
    assert.ok(c.options.signal);
    assert.ok(!c.url.includes(token));
  }
});
test('does not infer publishing scope from profile access or unsupported permissions endpoint', async () => {
  for (const next of [{status:400,body:{error:{message:token}}}, new Error(token), {body:{data:[]}}]) {
    const s = setup([{body:profile},next]);
    const res = await s.run();
    const body = await res.json();
    assert.equal(body.permissions.content_publish,'unverified');
    assert.equal(body.permissions.check,'unavailable');
    assert.ok(!JSON.stringify(body).includes(token));
  }
});
test('distinguishes declined publishing permission', async () => {
  const s = setup([{body:profile},{body:{data:[{permission:'instagram_business_basic',status:'granted'},{permission:'instagram_business_content_publish',status:'declined'}]}}]);
  assert.equal((await (await s.run()).json()).permissions.content_publish,'not_granted');
});
test('sanitizes expired tokens, provider errors and exceptions', async () => {
  for (const next of [{status:400,body:{error:{code:190,message:token}}}, {status:500,body:{error:{message:token}}}, new Error(token)]) {
    const s = setup([next]);
    const res = await s.run();
    assert.equal(res.status,502);
    assert.ok(!(await res.text()).includes(token));
    assert.equal(s.calls.length,1);
  }
});
test('rejects malformed and nonprofessional profiles', async () => {
  for (const p of [{}, {...profile,account_type:'PERSONAL'}, {...profile,id:token}, {...profile,username:token}]) {
    assert.equal((await setup([{body:p}]).run()).status,502);
  }
});
