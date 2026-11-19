import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {readFile,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url));
const db=new PGlite({extensions:{pgcrypto}});
await db.exec(`
create schema auth;create schema extensions;create schema cron;
create role anon;create role authenticated;create role service_role bypassrls;
create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema auth,extensions,public to anon,authenticated,service_role;
create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$;
`);
for(const file of (await readdir(root+'/supabase/migrations')).filter(f=>f.endsWith('.sql')).sort()){
 let sql=await readFile(root+'/supabase/migrations/'+file,'utf8');sql=sql.replace('create extension if not exists pg_cron;','-- pg_cron scheduling is stubbed in WASM; production Supabase provides it.');
 try{await db.exec(sql);console.log('Applied',file);}catch(error){console.error('MIGRATION FAILED:',error.message,error.position,error.internalQuery);await db.close();process.exit(1);}
}
// Pure-PL/pgSQL assertions execute the pgTAP-style tests without requiring the
// pgTAP extension in WASM. Any failing assertion raises an exception.
await db.exec(`
create function extensions.no_plan() returns text language sql as $$select 'begin tests'$$;
create function extensions.finish() returns text language sql as $$select 'end tests'$$;
create function extensions.is(actual anyelement,expected anyelement,label text) returns text language plpgsql as $$begin if actual is distinct from expected then raise exception 'FAIL %: actual %, expected %',label,actual,expected;end if;return 'PASS '||label;end$$;
create function extensions.lives_ok(command text,label text) returns text language plpgsql as $$begin execute command;return 'PASS '||label;exception when others then raise exception 'FAIL %: %',label,sqlerrm;end$$;
create function extensions.throws_ok(command text,code text,message text,label text) returns text language plpgsql as $$declare caught boolean:=false;begin begin execute command;exception when others then caught:=true;if sqlstate<>code or (message is not null and sqlerrm<>message) then raise exception 'FAIL %: got % (%), expected % (%)',label,sqlerrm,sqlstate,message,code;end if;end;if not caught then raise exception 'FAIL %: no exception',label;end if;return 'PASS '||label;end$$;
`);
let sql=await readFile(root+'/supabase/tests/network.test.sql','utf8');sql=sql.replace('create extension if not exists pgtap with schema extensions;','-- assertion functions already installed');
try{const results=await db.exec(sql);let count=0;for(const result of results)for(const row of result.rows??[])for(const value of Object.values(row))if(typeof value==='string'&&value.startsWith('PASS ')){console.log(value);count++;}console.log('Database assertions passed:',count);}catch(error){console.error('DATABASE TEST FAILED:',error.message,error.where,error.internalQuery);process.exitCode=1;}finally{await db.close();}
