import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const root=new URL('../supabase/migrations/',import.meta.url),db=new PGlite({extensions:{pgcrypto}});
try{
 await db.exec(`create schema auth;create schema extensions;create schema cron;create role anon;create role authenticated;create role service_role bypassrls;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth,extensions,public to anon,authenticated,service_role;create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;`);
 for(const name of ['20261119000000_network.sql','20261119000001_login_limits.sql'])await db.exec((await readFile(new URL(name,root),'utf8')).replace('create extension if not exists pg_cron;',''));
 const uid='11111111-1111-4111-8111-111111111111',single='22222222-2222-4222-8222-222222222222',average='33333333-3333-4333-8333-333333333333';
 const replay={format:'fto-replay-v1',size:3,complete:true,solveMs:100,events:[{at:0,type:'start'}],solver:{username:'VerifiedSolver'}};
 await db.query('insert into auth.users values ($1,$2,now())',[uid,'abid.ibn.ashraf@gmail.com']);await db.query('insert into public.profiles(id,username) values($1,$2)',[uid,'VerifiedSolver']);
 await db.query('insert into public.attempts(user_id,session_id,ms,dnf,completed_at,recording) values($1,$1,100,false,now(),$2)',[uid,replay]);
 for(const [id,metric,status] of [[single,'single','approved'],[average,'ao5','pending']])await db.query('insert into public.submissions(id,user_id,metric,ms,status,evidence) values($1,$2,$3,100,$4,$5)',[id,uid,metric,status,[{ms:100,dnf:false,recording:replay}]]);
 await db.query("insert into public.short_links(id,user_id,recording_hash,recording) values('existing-link',$1,public.recording_fingerprint($2),$2)",[uid,replay]);
 await db.exec(await readFile(new URL('20261119000002_recording_references.sql',root),'utf8'));
 const rows=await db.query('select * from public.recording_objects');assert.equal(rows.rows.length,1);assert.deepEqual(rows.rows[0].payload,replay);assert.equal(rows.rows[0].verified,true);
 assert.deepEqual((await db.query("select public.get_short_link('existing-link') as replay")).rows[0].replay,replay);
 assert.deepEqual((await db.query('select public.public_replay($1) as replay',[single])).rows[0].replay,replay);
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[uid]);assert.deepEqual((await db.query('select public.review_evidence($1) as evidence',[average])).rows[0].evidence,[{ms:100,dnf:false,recording:replay}]);
 await db.exec('delete from public.attempts;');await db.query('delete from public.submissions where id=$1',[single]);await db.exec('select public.collect_recordings();');assert.equal((await db.query('select count(*)::int n from public.recording_objects')).rows[0].n,1,'A pending average retains the shared recording');
 await db.exec('delete from public.submissions;select public.collect_recordings();');assert.equal((await db.query('select count(*)::int n from public.recording_objects')).rows[0].n,1,'An active share retains the same recording');
 await db.exec("update public.short_links set expires_at=now()-interval '1 second';select public.prune_recordings();");assert.equal((await db.query('select count(*)::int n from public.recording_objects')).rows[0].n,0,'The final reference disappearing releases the payload');
 const untrusted={...replay,solver:{username:'Unverified'}};await db.query('select public.store_recording($1,false)',[untrusted]);await db.query('select public.store_recording($1,true)',[replay]);await db.query('select public.store_recording($1,false)',[untrusted]);assert.deepEqual((await db.query('select payload from public.recording_objects')).rows[0].payload,replay,'Unverified shares cannot replace trusted solve attribution');
 console.log('Recording upgrade checks passed: existing links/evidence preserved, one payload across memberships, reference-safe cleanup, and verified attribution.');
}finally{await db.close();}
