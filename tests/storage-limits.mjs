import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {readFile,readdir} from 'node:fs/promises';
import assert from 'node:assert/strict';
const db=new PGlite({extensions:{pgcrypto}}),root=new URL('../supabase/migrations/',import.meta.url);
const user='11111111-1111-4111-8111-111111111111',other='22222222-2222-4222-8222-222222222222',admin='33333333-3333-4333-8333-333333333333';
const replay=(key,padding=0)=>({format:'fto-replay-v1',size:3,complete:true,createdAt:key,solveMs:100,events:[],initial:{padding:'x'.repeat(padding)}});
const size=async r=>(await db.query('select octet_length($1::jsonb::text) as n',[r])).rows[0].n;
const short=async r=>(await db.query('select public.create_short_link($1) as id',[r])).rows[0].id;
const usage=async uid=>(await db.query('select bytes from public.short_link_daily_usage where user_id=$1',[uid])).rows[0]?.bytes??0;
const identity=async uid=>{await db.query("select set_config('request.jwt.claim.sub',$1,false)",[uid]);};
async function reject(task,pattern){await assert.rejects(task,pattern);}
try{
 await db.exec(`create schema auth;create schema extensions;create schema cron;create role anon;create role authenticated;create role service_role bypassrls;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth,extensions,public to anon,authenticated,service_role;create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;`);
 for(const name of (await readdir(root)).filter(n=>n.endsWith('.sql')).sort())await db.exec((await readFile(new URL(name,root),'utf8')).replace('create extension if not exists pg_cron;',''));
 for(const [uid,name,email] of [[user,'Solver','solver@example.com'],[other,'OtherSolver','other@example.com'],[admin,'Owner','abid.ibn.ashraf@gmail.com']]){await db.query('insert into auth.users values($1,$2,now())',[uid,email]);await db.query('insert into public.profiles(id,username) values($1,$2)',[uid,name]);}
 await identity(user);const a=replay('first',200000),b=replay('second',200000),c=replay('third',120000);const code=await short(a),aBytes=await size(a);assert.equal(await usage(user),aBytes);const expiry=(await db.query('select expires_at from public.short_links where id=$1',[code])).rows[0].expires_at;
 assert.equal(await short(a),code);assert.equal(await usage(user),aBytes);assert.deepEqual((await db.query('select expires_at from public.short_links where id=$1',[code])).rows[0].expires_at,expiry);
 await short(b);await reject(()=>short(c),/Daily short-link limit reached/);assert.equal((await db.query('select count(*)::int n from public.short_links')).rows[0].n,2);assert.equal(await usage(user),aBytes+await size(b));
 await identity(other);assert.equal(await short(a),code);assert.equal(await usage(other),0);await short(c);assert.equal(await usage(other),await size(c));
 await identity(user);await db.query('delete from public.short_links where id=$1',[code]);await reject(()=>short(replay('after-delete',120000)),/Daily short-link limit reached/);assert.equal(await usage(user),aBytes+await size(b));
 // UTC calendar-day reset: set a non-UTC database timezone and yesterday's ledger.
 await db.exec("set timezone='Asia/Dhaka';update public.short_link_daily_usage set day=(clock_timestamp() at time zone 'UTC')::date-1 where user_id='11111111-1111-4111-8111-111111111111';");
 await short(a);assert.equal(await usage(user),aBytes);assert.equal((await db.query("select day=(clock_timestamp() at time zone 'UTC')::date as utc from public.short_link_daily_usage where user_id=$1",[user])).rows[0].utc,true);
 // Exact boundary and UTF-8 bytes, not JavaScript string length.
 const boundary=replay('boundary');const left=500000-await size(boundary);await db.query('update public.short_link_daily_usage set bytes=$1 where user_id=$2',[left,user]);await short(boundary);assert.equal(await usage(user),500000);await reject(()=>short(replay('over')),/Daily short-link limit reached/);assert.equal(await short(boundary),await short(boundary));
 const unicode={...replay('unicode'),initial:{padding:'বাংলা'}};assert.ok(await size(unicode)>JSON.stringify(unicode).length);
 // Quota is private. Internal guards cannot be invoked to hold the global lock.
 await db.exec('set role authenticated;');await reject(()=>db.query('select * from public.short_link_daily_usage'),/permission denied/);await reject(()=>db.query('select public.database_storage_bytes()'),/permission denied/);await reject(()=>db.query('select public.check_database_capacity(1)'),/permission denied/);await reject(()=>db.query('select public.storage_status()'),/Administrator access required/);await identity(admin);const status=(await db.query('select public.storage_status() as status')).rows[0].status;assert.equal(status.daily_short_link_limit_bytes,500000);assert.equal(status.database_write_stop_bytes,350000000);await db.exec('reset role;');
 // Simulate a database at the write stop; exercise the actual production guards.
 await identity(other);await db.exec('create or replace function public.database_storage_bytes() returns bigint language sql volatile security definer set search_path=\'\' as $$select 350000000::bigint$$;');const before=await usage(other);
 await reject(()=>short(replay('full')),/Database storage is nearly full/);assert.equal(await usage(other),before);assert.equal(await short(boundary),await short(boundary));assert.ok((await db.query('select public.get_short_link($1) as replay',[await short(boundary)])).rows[0].replay);
 await reject(()=>db.query("select public.begin_attempt('88888888-8888-4888-8888-888888888888')"),/Database storage is nearly full/);
 // Cleanup must work when full, including shrinking approved evidence refs.
 await db.exec('alter table public.submissions disable trigger submissions_storage_guard;');await db.query("insert into public.submissions(user_id,metric,ms,status,evidence_refs) values($1,'ao5',100,'approved',$2)",[other,[{recording_hash:'a'.repeat(64)}]]);await db.exec('alter table public.submissions enable trigger submissions_storage_guard;select public.prune_recordings();');assert.equal((await db.query("select evidence_refs from public.submissions where metric='ao5'")).rows[0].evidence_refs,null);
 await db.query('delete from public.short_links where id=$1',[code]);
 console.log('Storage limit checks passed: byte accounting, exact boundary, deduplication, account isolation, UTC reset, no deletion refunds, private metrics, database stop, and readable/prunable existing data.');
}finally{await db.close();}
