import Fastify, { LogController } from 'fastify';
import { contractSchemas,routeContract,isPublicRoute,completeOpenAPI } from './contract.js';
import { SERVER_VERSION,PROTOCOL_VERSION } from './version.js';
import { digest,rateLimit } from './security.js';
import { recordProxyProbe } from './diagnostics.js';
import swagger from '@fastify/swagger';
import { access } from 'node:fs/promises';
import { constants } from 'node:fs';
import type { Config } from './config.js';
import { Database } from './db.js';
import { ApiError } from './errors.js';
import { installAuth } from './auth.js';
import { installSync } from './sync.js';
import { FileStore,installFiles,PART_BYTES } from './files.js';
export async function buildApp(config:Config,db:Database){
 const app=Fastify({logger:config.test?false:{level:'info'},logController:new LogController({disableRequestLogging:true}),trustProxy:config.trustedProxyCIDRs.length?config.trustedProxyCIDRs:false,ajv:{customOptions:{removeAdditional:false,coerceTypes:false,useDefaults:false}},bodyLimit:4*1024*1024,requestTimeout:60000,connectionTimeout:15000,routerOptions:{maxParamLength:100}});
 await app.register(swagger,{refResolver:{buildLocalReference:(schema)=>String(schema.$id)},openapi:{info:{title:'Planner Server API',version:SERVER_VERSION},servers:[{url:config.publicBaseUrl}],components:{securitySchemes:{bearerAuth:{type:'http',scheme:'bearer'}}}}});
 for(const schema of contractSchemas)app.addSchema(schema);
 app.addHook('onRoute',route=>{route.schema={...route.schema,...routeContract(String(route.method),route.url)};});
 app.addHook('onRequest',async request=>{
   await recordProxyProbe(db,request);
   const path=request.routeOptions.url??request.url.split('?')[0]!;
   if(path.startsWith('/health/'))return;
   if(isPublicRoute(path)||!path.startsWith('/v1/')) {
     await rateLimit(db,`http-public:${digest(request.ip)}`,config.publicRequestsPerMinute,60);
   } else {
     try{await auth.authenticate(request);}catch(error){
       if(error instanceof ApiError && error.status===401)await rateLimit(db,`http-public:${digest(request.ip)}`,config.publicRequestsPerMinute,60);
       throw error;
     }
   }
 });
 app.addHook('onSend',async(_r,reply,payload)=>{reply.header('X-Content-Type-Options','nosniff').header('Cache-Control','no-store');return payload;});
 app.setErrorHandler((error,request,reply)=>{
   const e=error as any;
   const status=error instanceof ApiError?error.status:e.statusCode>=400&&e.statusCode<500?e.statusCode:503;
   const code=error instanceof ApiError?error.code:status===429?'rate_limited':status===413?'request_too_large':status<500?'invalid_request':'server_unavailable';
   const message=error instanceof ApiError?error.message:status<500?'Некорректный запрос':'Сервер временно недоступен';
   if(status>=500)app.log.error({event:'request_failed',code,requestId:request.id});
   const retryAfter=status===429?Math.max(1,Math.ceil(error instanceof ApiError?error.retryAfterSeconds??1:1)):undefined;
   if(retryAfter!==undefined)reply.header('Retry-After',String(retryAfter));
   reply.code(status).send({error:{code,message,requestId:request.id,...(retryAfter!==undefined?{retryAfterSeconds:retryAfter}:{})}});
 });
 const store=new FileStore(config.dataDir);await store.initialize();
 app.get('/health/live',async()=>({status:'ok',version:SERVER_VERSION}));
 app.get('/health/ready',async(_request,reply)=>{
   try{
     const r=await db.pool.query("SELECT value FROM settings WHERE key='maintenance'");await access(config.dataDir,constants.W_OK);
     if(!r.rowCount||r.rows[0].value===true)return reply.code(503).send({status:'maintenance'});
     return {status:'ready',version:SERVER_VERSION};
   }catch{return reply.code(503).send({status:'unavailable'});}
 });
 app.get('/v1/config',async()=>({protocolVersion:PROTOCOL_VERSION,serverVersion:SERVER_VERSION,serverTime:new Date().toISOString(),registrationMode:config.publicRegistration?'open':'allowlist',limits:{maxFileBytes:config.maxFileBytes,accountQuotaBytes:config.quotaBytes,partBytes:PART_BYTES,maxBatchOperations:100,maxRequestBytes:4194304}}));
 const auth=await installAuth(app,db,config);installSync(app,db,auth);installFiles(app,db,auth,config,store);
 app.get('/v1/openapi.json',async()=>completeOpenAPI(app.swagger()));
 return {app,store,auth};
}
