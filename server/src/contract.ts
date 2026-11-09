import { uuidPattern } from './security.js';
const str={type:'string'},bool={type:'boolean'},integer={type:'integer',minimum:0,maximum:Number.MAX_SAFE_INTEGER};
const id={type:'string',pattern:uuidPattern},revision={type:'string',pattern:'^[0-9]+$'},time={type:'string',format:'date-time'},day={type:'string',format:'date'};
const nullable=(schema:any)=>({anyOf:[schema,{type:'null'}]});
const ref=(name:string)=>({$ref:`${name}#`});
const array=(items:any)=>({type:'array',items});
const object=(properties:Record<string,any>,required=Object.keys(properties))=>({type:'object',additionalProperties:false,properties,required});
const named=(name:string,schema:any)=>({$id:name,...schema});
export const stampSchema=named('Stamp',object({physicalMillis:integer,logicalCounter:{type:'integer',minimum:0,maximum:2147483647},deviceId:id,operationId:id}));
const placement={oneOf:[object({kind:{enum:['inbox','week','month']}}),object({kind:{enum:['folder']},folderId:id})]};
const deadline=nullable({oneOf:[object({includesTime:{const:false},date:day,timeZoneId:str}),object({includesTime:{const:true},instant:time,timeZoneId:str})]});
const fields:Record<string,Record<string,any>>={
 task:{title:str,description:str,createdAt:time,completedAt:nullable(time),focusDay:nullable(day),placement,deadline,planning:nullable(object({kind:{enum:['week','month']},anchor:time}))},
 folder:{name:str,sortOrder:integer},checklistItem:{taskId:id,title:str,isCompleted:bool,sortOrder:integer},attachment:{taskId:id,filename:str,mimeType:str,size:integer,sha256:{type:'string',pattern:'^[a-f0-9]{64}$'}}
};
const entities=Object.entries(fields).map(([type,properties])=>named(`${type[0]!.toUpperCase()+type.slice(1)}Entity`,object({
 id,type:{const:type},fields:object(properties,[]),versions:{type:'object',additionalProperties:ref('Stamp')},deleted:bool,revision,...(type==='attachment'?{fileReady:bool}:{})
},['id','type','fields','versions','deleted','revision'])));
const entity=named('Entity',{oneOf:entities.map(e=>ref(e.$id))});
// Semantic errors remain per-operation results in protocol 1, not a whole-batch HTTP 400.
export const mutationSchema=named('Mutation',object({operationId:id,libraryId:id,deviceId:id,entityId:id,entityType:{enum:Object.keys(fields)},kind:{enum:['create','update','delete']},changes:{type:'object',minProperties:1,maxProperties:8,additionalProperties:object({value:{},version:ref('Stamp')})},deleteVersion:ref('Stamp')},['operationId','libraryId','deviceId','entityId','entityType','kind']));
mutationSchema.description='Changes contain fields of the selected entity type: see TaskFields, FolderFields, ChecklistItemFields, AttachmentFields. Omission means unchanged; null clears nullable fields. Semantic errors are returned per operation.';
const error=named('ErrorResponse',object({error:object({code:str,message:str,requestId:str,retryAfterSeconds:{type:'integer',minimum:1}},['code','message','requestId'])}));
const ok=named('Ok',object({ok:{const:true}}));
const tokens=object({accessToken:str,refreshToken:str,expiresIn:integer,tokenType:{const:'Bearer'}});
const result={oneOf:[object({operationId:id,status:{enum:['applied','deleted']},entity:ref('Entity')}),object({operationId:nullable(id),status:{const:'rejected'},error:object({code:str,message:str})})]};
export const contractSchemas=[stampSchema,mutationSchema,...entities,entity,error,ok,
 ...Object.entries(fields).map(([type,properties])=>named(`${type[0]!.toUpperCase()+type.slice(1)}Fields`,object(properties,[]))),
 named('ChallengeResponse',object({message:str,challengeId:id})),named('TokenResponse',tokens),
 named('LoginResponse',object({...tokens.properties,sessionId:id,user:object({id,email:str})})),
 named('MeResponse',object({id,email:str,libraryId:id})),
 named('DevicesResponse',object({devices:array(object({id,deviceId:id,name:str,createdAt:time,lastUsedAt:time})),currentSessionId:id})),
 named('LibraryResponse',object({id,initialized:bool,revision})),
 named('SnapshotResponse',object({protocolVersion:{const:1},libraryId:id,cursor:revision,initialized:bool,entities:array(ref('Entity'))})),
 named('ChangesResponse',object({libraryId:id,changes:array(object({revision,entity:ref('Entity')})),nextCursor:revision,hasMore:bool})),
 named('MutationsResponse',object({results:array(result)})),named('ImportResponse',object({importId:id,committed:bool})),named('ImportBatchResponse',object({accepted:integer})),
 named('UploadResponse',object({uploadId:id,ready:bool,partBytes:integer,expiresIn:integer},['uploadId','ready','partBytes'])),
 named('UploadStateResponse',object({uploadId:id,attachmentId:id,ready:bool,expiresAt:time,partBytes:integer,parts:array(object({part:integer,size:integer,sha256:str}))})),
 named('PartResponse',object({ok:{const:true},sha256:str})),named('CompleteResponse',object({ok:{const:true},attachment:ref('Entity')})),
 named('StorageResponse',object({quotaBytes:integer,maxFileBytes:integer,activeBytes:integer,retainedBytes:integer,reservedBytes:integer})),
 named('HealthResponse',object({status:str,version:str},['status'])),
 named('ConfigResponse',object({protocolVersion:{const:1},serverVersion:str,serverTime:time,registrationMode:{enum:['open','allowlist']},limits:object({maxFileBytes:integer,accountQuotaBytes:integer,partBytes:integer,maxBatchOperations:integer,maxRequestBytes:integer})}))
];
const email={type:'string',minLength:3,maxLength:254},password={type:'string',minLength:12,maxLength:128};
const mutations={type:'array',minItems:1,maxItems:100,items:ref('Mutation')};
export const requestSchemas:Record<string,any>={
 '/v1/auth/register':object({email,password}),'/v1/auth/verify-email':object({challengeId:id,code:{type:'string',pattern:'^\\d{8}$'},password}),
 '/v1/auth/resend-verification':object({email}),'/v1/auth/login':object({email,password,deviceId:id,deviceName:{type:'string',minLength:1,maxLength:100}}),
 '/v1/auth/refresh':object({refreshToken:{type:'string',minLength:32,maxLength:128}}),'/v1/auth/password-reset/request':object({email}),
 '/v1/auth/password-reset/confirm':object({challengeId:id,code:{type:'string',pattern:'^\\d{8}$'},newPassword:password}),
 '/v1/account':object({password}),'/v1/sync/mutations':object({mutations}),'/v1/library/imports':object({importId:id}),
 '/v1/library/imports/:id/mutations':object({mutations}),'/v1/attachments/:id/uploads':object({uploadId:id})
};
const responses:Record<string,string>={
 '/health/live':'HealthResponse','/health/ready':'HealthResponse','/v1/config':'ConfigResponse',
 '/v1/auth/register':'ChallengeResponse','/v1/auth/resend-verification':'ChallengeResponse','/v1/auth/password-reset/request':'ChallengeResponse',
 '/v1/auth/verify-email':'Ok','/v1/auth/password-reset/confirm':'Ok','/v1/auth/login':'LoginResponse','/v1/auth/refresh':'TokenResponse','/v1/auth/logout':'Ok',
 '/v1/me':'MeResponse','/v1/devices':'DevicesResponse','/v1/devices/:id':'Ok','/v1/account':'Ok','/v1/library':'LibraryResponse',
 '/v1/sync/snapshot':'SnapshotResponse','/v1/sync/changes':'ChangesResponse','/v1/sync/mutations':'MutationsResponse',
 '/v1/library/imports':'ImportResponse','/v1/library/imports/:id/mutations':'ImportBatchResponse','/v1/library/imports/:id/commit':'Ok',
 '/v1/attachments/:id/uploads':'UploadResponse','/v1/uploads/:id':'UploadStateResponse','/v1/uploads/:id/parts/:part':'PartResponse',
 '/v1/uploads/:id/complete':'CompleteResponse','/v1/storage':'StorageResponse'
};
export function isPublicRoute(path:string) {return path.startsWith('/health/')||path==='/v1/config'||path==='/v1/openapi.json'||(path.startsWith('/v1/auth/')&&path!=='/v1/auth/logout');}
export function routeContract(method:string,path:string) {
 const response:Record<string,any>={};for(const status of [400,401,403,404,409,410,413,415,429,500,503])response[status]=ref('ErrorResponse');
 if(responses[path])response[200]=ref(responses[path]!);
 if(path==='/health/ready')response[503]={anyOf:[ref('HealthResponse'),ref('ErrorResponse')]};
 if(path==='/v1/attachments/:id/content')response[200]={type:'string',format:'binary'};
 if(path==='/v1/openapi.json')response[200]={type:'object',additionalProperties:true};
 const params:Record<string,any>={};for(const match of path.matchAll(/:([A-Za-z]+)/g))params[match[1]!]=match[1]==='part'?{type:'string',pattern:'^[0-9]{1,4}$'}:id;
 return {tags:[path.startsWith('/health/')?'health':path.split('/')[2]??'api'],security:isPublicRoute(path)?[]:[{bearerAuth:[]}],response,
   ...(requestSchemas[path]&&method!=='GET'?{body:requestSchemas[path]}:{}),...(Object.keys(params).length?{params:object(params)}:{}),
   ...(path==='/v1/sync/changes'?{querystring:object({cursor:{type:'string',pattern:'^[0-9]{1,19}$'}})}:{}),
   ...(path==='/v1/attachments/:id/content'?{produces:['application/octet-stream']}:{}),...(path==='/v1/uploads/:id/parts/:part'?{consumes:['application/octet-stream']}:{}),
 };
}
export function completeOpenAPI(spec:any) {
 const doc=structuredClone(spec);
 doc.paths['/v1/uploads/{id}/parts/{part}'].put.requestBody={required:true,content:{'application/octet-stream':{schema:{type:'string',format:'binary'}}}};
 for(const [path,methods]of Object.entries(doc.paths) as [string,any][])for(const op of Object.values(methods) as any[]) {
   if(!op.responses)continue;
   if(op.responses['429'])op.responses['429'].headers={'Retry-After':{description:'Seconds until the exceeded limit permits retrying.',schema:{type:'integer',minimum:1}}};
   if(path==='/v1/attachments/{id}/content')op.responses['200']={description:'Original file bytes; verify SHA-256 before installing into cache.',content:{'application/octet-stream':{schema:{type:'string',format:'binary'}}},headers:{'X-Content-SHA256':{schema:{type:'string'}},'Content-Disposition':{schema:{type:'string'}}}};
 }return doc;
}
