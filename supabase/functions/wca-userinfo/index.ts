import {wcaUserinfo} from './handler.js';
Deno.serve(request=>wcaUserinfo(request));
