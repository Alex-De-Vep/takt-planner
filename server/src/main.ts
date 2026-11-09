import { loadConfig } from './config.js';
import { Database } from './db.js';
import { buildApp } from './app.js';
import { FileStore } from './files.js';
import { runWorker } from './worker.js';
import { stageBackup,verifyBackup,restoreFiles } from './backup.js';
import nodemailer from 'nodemailer';
import { diagnostics,recordMail,recordOperation,startProxyProbe } from './diagnostics.js';
import { email } from './security.js';
async function main(){
 const config=loadConfig(),db=new Database(config.databaseUrl),command=process.argv[2]??'serve';
 if(command==='migrate'){try{await db.migrate();console.log('Миграции применены');}finally{await db.close();}return;}
 if(command==='maintenance'){try{if(!['on','off'].includes(process.argv[3]??''))throw new Error('Use on/off');await db.maintenance(process.argv[3]==='on');console.log('Режим обслуживания изменён');}finally{await db.close();}return;}
 const store=new FileStore(config.dataDir);await store.initialize();
 if(command.startsWith('backup-')||command==='restore-files'){
   try{
     const root=process.env.BACKUP_ROOT||'/backup',arg=process.argv[3]??'';
     if(command==='backup-stage')console.log(JSON.stringify(await stageBackup(db,store,root,arg)));
     else if(command==='backup-verify'){const r=await verifyBackup(root,arg);console.log(JSON.stringify({backupId:r.manifest.backupId,files:r.manifest.files.length,valid:true}));}
     else if(command==='restore-files')console.log(JSON.stringify(await restoreFiles(db,store,root,arg)));
     else throw new Error('Unknown command');
   }finally{await db.close();}return;
 }
 if(command==='diagnose'||command==='proxy-probe-start'){
   try{console.log(JSON.stringify(command==='diagnose'?await diagnostics(db,config):await startProxyProbe(db)));}finally{await db.close();}return;
 }
 if(command==='record-backup'){
   try{const [status,snapshot,verified]=process.argv.slice(3);if(!['success','failed'].includes(status??'')||(snapshot&&!/^[a-f0-9]{8,64}$/.test(snapshot)))throw new Error('Invalid backup result');
     await recordOperation(db,'backup',status==='success'?{lastSuccessAt:new Date().toISOString(),snapshotId:snapshot,fullDataCheck:verified==='full'}:{lastFailureAt:new Date().toISOString(),errorCode:'BACKUP_FAILED'});
   }finally{await db.close();}return;
 }
 if(command==='mail-test'){
   try{const to=email(process.argv[3]);const smtp=nodemailer.createTransport({host:config.smtpHost,port:config.smtpPort,secure:config.smtpSecure,auth:config.smtpUser?{user:config.smtpUser,pass:config.smtpPassword}:undefined,connectionTimeout:10000,socketTimeout:20000});try{await smtp.sendMail({from:config.mailFrom,to,subject:'Проверка сервера Задачи',text:'Сервер успешно отправил это тестовое письмо.',disableFileAccess:true,disableUrlAccess:true});await recordMail(db,true);console.log('Тестовое письмо отправлено');}catch(error){await recordMail(db,false,error);throw error;}finally{smtp.close();}}finally{await db.close();}return;
 }
 const controller=new AbortController();
 process.once('SIGTERM',()=>controller.abort());process.once('SIGINT',()=>controller.abort());
 if(command==='worker'){await runWorker(db,config,store,controller.signal);await db.close();return;}
 if(command!=='serve')throw new Error('Unknown command');
 const {app}=await buildApp(config,db);await app.listen({port:config.port,host:'0.0.0.0'});
 controller.signal.addEventListener('abort',()=>{void app.close().then(()=>db.close());},{once:true});
}
main().catch(()=>{console.error('Не удалось выполнить команду сервера. Проверьте конфигурацию, базу и права каталогов.');process.exitCode=1;});
