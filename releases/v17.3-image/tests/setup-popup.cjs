const fs=require('fs'),path=require('path'),assert=require('assert');
const {JSDOM}=require(process.env.JSDOM_PATH||'jsdom');
const html=fs.readFileSync(path.join(__dirname,'../program/app.html'),'utf8').replace('__MAIL_RENDERER__','');
async function scenario(role,configured=true){let tick,errors=[],calls=[];let state={role,release:'bridge-v17.3',keyReady:false,configured,transferReady:false,busy:false,connecting:false,inbox:role==='External'?'C:\\FTC_downloads':'D:\\FTC_downloads',mails:[],calendar:{items:[]},collectionFilter:{mode:'recent'},chat:{result:{},providers:{}}};
 const d=new JSDOM(html,{url:'http://127.0.0.1:8765',runScripts:'dangerously',beforeParse(w){w.setInterval=f=>(tick=f,1);w.addEventListener('error',e=>errors.push(e.message));w.HTMLDialogElement.prototype.showModal=function(){this.open=true};w.HTMLDialogElement.prototype.close=function(){this.open=false};w.fetch=async(p,opt)=>{if(p==='/api/state')return{ok:true,json:async()=>structuredClone(state)};calls.push({path:p,body:JSON.parse(opt.body)});return{ok:true,json:async()=>({ok:true})}}}});const $=id=>d.window.document.getElementById(id),wait=()=>new Promise(r=>setTimeout(r,35));
 try{await wait();assert($('firstTransferSetup').open);assert.equal(calls.length,0);assert($('firstTransferSetupFolder').textContent.includes(state.inbox));
 $('firstTransferSetupLater').click();await tick();assert(!$('firstTransferSetup').open);assert(!$('warn').hidden);state.transferReady=true;state.configured=true;await tick();assert(!$('firstTransferSetup').open);state.transferReady=false;state.configured=configured;await tick();assert($('firstTransferSetup').open);
 $('firstTransferSetupStart').click();await wait();assert(!$('firstTransferSetup').open);assert($('settingsDialog').open);assert.equal(calls[0].path,'/api/setup');assert.equal(calls[0].body.action,'enter');
 if(configured){assert(calls.some(c=>c.body.action==='test'));assert(!$('setupStep2').hidden)}else{assert(!calls.some(c=>c.body.action==='test'));assert(!$('setupStep1').hidden)}
 assert.deepEqual(errors,[]);console.log('PASS',role,'configured='+configured,'initial prompt → explicit Start → '+(configured?'image test request':'required folder step')+', Later does not nag');
 }finally{d.window.close()}
}
(async()=>{await scenario('Internal');await scenario('External');await scenario('Internal',false);await scenario('External',false)})().catch(e=>{console.error(e);process.exitCode=1});
