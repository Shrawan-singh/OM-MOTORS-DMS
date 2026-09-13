import assert from 'node:assert/strict';
const base='http://127.0.0.1:3000';
for(const path of ['/','/admin','/customers','/inventory','/quotations/new','/invoices','/service']){
 const response=await fetch(base+path,{redirect:'manual'});
 assert.equal(response.status,307,path);
 assert.equal(new URL(response.headers.get('location')).pathname,'/login',path);
}
const attack=await fetch(base+'/admin',{redirect:'manual',headers:{'x-middleware-subrequest':'middleware:middleware:middleware:middleware:middleware'}});
assert.notEqual(attack.status,200,'Middleware bypass header must not expose admin');
const callback=await fetch(base+'/auth/callback',{redirect:'manual'});
assert.equal(new URL(callback.headers.get('location')).pathname,'/login');
assert.equal((await fetch(base+'/login')).status,200);
console.log('PASS: all protected routes deny anonymous requests, forged middleware header does not expose admin, invalid callback redirects safely, login renders.');
