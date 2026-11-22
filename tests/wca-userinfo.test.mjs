import {test} from 'node:test';
import assert from 'node:assert/strict';
import {wcaUserinfo} from '../supabase/functions/wca-userinfo/handler.js';
const request=()=>new Request('https://backend.test/wca-userinfo',{headers:{Authorization:'Bearer test-wca-token'}});
test('public WCA identity is flattened without leaking tokens or private information',async()=>{
 const response=await wcaUserinfo(request(),async(url,options)=>{
  assert.equal(url,'https://www.worldcubeassociation.org/api/v0/me');
  assert.equal(options.headers.Authorization,'Bearer test-wca-token');
  assert.equal(options.redirect,'error');
  return Response.json({me:{id:42,name:'Solver',wca_id:'2015TEST01',email:'private@example.com',avatar:{thumb_url:'https://cdn.example.com/avatar.png'}}});
 });
 assert.equal(response.status,200);assert.equal(response.headers.get('Cache-Control'),'no-store');
 assert.deepEqual(await response.json(),{sub:'42',name:'Solver',picture:'https://cdn.example.com/avatar.png',wca_id:'2015TEST01',wca_user_id:'42'});
});
test('accounts without a person ID work; non-HTTPS pictures are excluded',async()=>{
 const response=await wcaUserinfo(request(),async()=>Response.json({me:{id:12,name:'New cuber',wca_id:null,avatar:{url:'javascript:alert(1)'}}}));
 assert.deepEqual(await response.json(),{sub:'12',name:'New cuber',wca_id:null,wca_user_id:'12'});
});
test('missing tokens and unexpected methods cannot call WCA',async()=>{
 const noFetch=()=>{throw Error('Must not fetch');};
 assert.equal((await wcaUserinfo(new Request('https://backend.test'),noFetch)).status,401);
 assert.equal((await wcaUserinfo(new Request('https://backend.test',{method:'POST'}),noFetch)).status,405);
});
test('expired tokens, invalid identities and upstream outages produce safe failures',async()=>{
 for(const [upstream,status] of [[()=>new Response('',{status:401}),401],[()=>Response.json({me:{id:'42',name:'Bad'}}),502],[()=>{throw Error('secret upstream details');},502]]){
  const response=await wcaUserinfo(request(),upstream);assert.equal(response.status,status);assert.doesNotMatch(await response.text(),/secret|test-wca-token/);
 }
});
