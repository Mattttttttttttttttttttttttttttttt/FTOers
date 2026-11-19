import {build} from 'esbuild';
import {copyFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
await build({entryPoints:[fileURLToPath(import.meta.resolve('@supabase/supabase-js'))],outfile:'public/shared/supabase.js',bundle:true,format:'esm',platform:'browser',minify:true});
await copyFile(new URL('../node_modules/@supabase/supabase-js/LICENSE',import.meta.url),new URL('../public/shared/SUPABASE-LICENSE',import.meta.url));
