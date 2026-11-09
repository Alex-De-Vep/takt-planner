import { mkdtemp,rm,writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadConfig } from '../dist/config.js';
import { Database } from '../dist/db.js';
import { completeOpenAPI } from '../dist/contract.js';
import { buildApp } from '../dist/app.js';
const data=await mkdtemp(join(tmpdir(),'planner-contract-'));
const config=loadConfig({NODE_ENV:'test',DATABASE_URL:'postgres://unused:unused@localhost/unused',AUTH_SECRET:'0'.repeat(64),PUBLIC_BASE_URL:'http://localhost',DATA_DIR:data});
const db=new Database(config.databaseUrl);
try{const {app}=await buildApp(config,db);await app.ready();const spec=completeOpenAPI(app.swagger());spec.servers=[{url:'https://YOUR-SERVER.ts.net'}];await writeFile(new URL('../docs/openapi.json',import.meta.url),JSON.stringify(spec,null,2)+'\n');await app.close();}finally{await db.close();await rm(data,{recursive:true,force:true});}
