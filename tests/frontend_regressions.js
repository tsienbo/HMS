// Original application scripts with a small DOM/API double. No real network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
function environment() {
  const data = {}, els = {};
  const storage = { getItem:k=>data[k] ?? null, setItem:(k,v)=>{data[k]=String(v);}, removeItem:k=>{delete data[k];} };
  const field = (id, value='') => els[id] = { value, style:{}, textContent:'', innerHTML:'', querySelectorAll:()=>[], focus(){} };
  const ctx = { console, window:{addEventListener(){}}, document:{getElementById:id=>els[id]||null},
    localStorage:storage, setTimeout:()=>0, clearTimeout(){}, setInterval:()=>0, clearInterval(){},
    fetch:async()=>({ok:true,text:async()=> '{}'}), alert(){}, confirm:()=>true };
  vm.createContext(ctx);
  for (const file of ['i18n.js','i18n_data.js','app.js'])
    vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/js',file),'utf8'),ctx);
  return {ctx,field,els,run:source=>vm.runInContext(source,ctx)};
}
async function main() {
  {
    const {run,field}=environment();
    field('pxSchedule','S_TEST'); field('proxyTip'); field('pxName'); field('pxDoc'); field('pxEmail'); field('captchaWhy');
    run(`readName=()=>({ok:true,name:'Test Patient'});readDoc=()=>({ok:true,idType:'PASSPORT',nationality:'US',idCard:'TESTPASS1',sex:'M'});
         readPhone=()=>({ok:true,phoneCc:'1',phone:'2025550100'});readEmail=()=>({ok:true,email:''});
         proxyDeptChange=()=>{};var calls=0;var received=null;
         apiProxyBooking=async(s,p,token,answer)=>{calls++;received={s,p,token,answer};
           if(calls===1){var e=new Error('captcha');e.code='CAPTCHA_REQUIRED';throw e;}return {id:'AT',seqNo:1};};
         openCaptcha=async()=>({token:'T',answer:'3'});`);
    await run('submitProxy()');
    assert.equal(run('calls'),2); assert.equal(run('received.token'),'T');
    assert.equal(run('received.p.idCard'),'TESTPASS1');
    run(`apiProxyBooking=async()=>{var e=new Error('captcha');e.code='CAPTCHA_REQUIRED';throw e;};openCaptcha=async()=>null;`);
    assert.equal((await run(`bookWithCaptcha('S',{},'proxy')`)).cancelled,true);
  }
  {
    const {run}=environment(); run('request=async(method,url)=>url');
    for(const status of ['booked','completed','cancelled']) {
      const url=await run(`apiAppointments({idCard:'P:US:TESTPASS1',status:'${status}',limit:200})`);
      assert.equal(new URL(url,'http://test').searchParams.get('status'),status);
      assert.equal(new URL(url,'http://test').searchParams.get('limit'),'200');
    }
  }
  {
    const {run,field}=environment(); field('doctorList');
    run(`doctors=[{id:'DR01',deptId:'D01',name:'Test Doctor',title:'',fee:1}];bookingState.deptId='D01';
         allSchedules.DR01=[{id:'S',remain:0}];var loads=0;
         apiDoctorSchedules=async()=>{loads++;return [{id:'S',remain:10}]};`);
    await run('renderStep2({innerHTML:""})');
    assert.equal(run('loads'),1); assert.equal(run('allSchedules.DR01[0].remain'),10);
    await run('renderStep2({innerHTML:""})'); assert.equal(run('loads'),2);
  }
  {
    const {run,field,els}=environment();
    run(`saveSession({name:'Test Patient',idType:'PASSPORT',nationality:'US',idCard:'TESTPASS1',phoneCc:'1',phone:'2025550100'});`);
    field('pNameEdit','Test Patient');field('pePhoneCc','1');field('pePhone','2025550101');field('pEmailEdit');field('profileSaveTip');
    run(`apiUpdatePatient=async()=>({ok:true});showPage=()=>{};renderBookingStep=()=>{};`);
    await run('saveProfile()');run('startBooking()');
    assert.equal(run('loadSession().phone'),'2025550101');
    assert.equal(run('bookingState.patient.phone'),'2025550101');
    for(let i=0;i<11;i++) run(`savePatientToken('P:US:TEST${i}','TOKEN_${i}')`);
    assert.ok(run(`allPatientTokens().split(',').includes('TOKEN_10')`));
    run(`saveSession({docKey:'P:US:TEST0'});`);
    assert.equal(run(`allPatientTokens().split(',')[0]`),'TOKEN_0');
    run(`savePatientToken('P:US:TEST10','TOKEN_REFRESHED')`);
    assert.ok(run(`allPatientTokens().split(',').includes('TOKEN_REFRESHED')`));

    for(const id of ['wlMask','patientAuthMask','captchaMask','voucherMask','routeMask','timelineMask']) {
      field(id); els[id].style.display='flex';
    }
    field('wlName','Test Patient');field('wlIdCard','TESTPASS1');field('voucherBody');els.voucherBody.textContent='Test Patient';
    els.wlMask.querySelectorAll=selector=>selector==='input, textarea' ? [els.wlName,els.wlIdCard] : [];
    run(`rememberOn=()=>false;goHome=()=>{};var authResult=null,capResult='unset';
         patientAuthResolve=r=>{authResult=r};captchaResolve=r=>{capResult=r};voucherApt={patientName:'Test Patient'};forgetPatient();`);
    assert.equal(els.wlMask.style.display,'none');assert.equal(els.wlName.value,'');assert.equal(els.wlIdCard.value,'');
    assert.equal(els.voucherBody.textContent,'');assert.equal(run('voucherApt'),null);
    assert.equal(run('authResult'),false);assert.equal(run('capResult'),null);
  }
  {
    const {run,ctx}=environment();
    let resolve;
    ctx.fetch=()=>new Promise(r=>{resolve=r});
    const request=run(`request('GET','/patients/mine?idCard=TESTPASS1')`);
    run(`rememberOn=()=>false;goHome=()=>{};forgetPatient()`);
    resolve({ok:true,text:async()=>JSON.stringify({name:'Previous Patient'})});
    await assert.rejects(request);
  }
  console.log('PASS: proxy/captcha, status filters, refreshed slots, profile phone, active tokens, kiosk cleanup and stale requests');
}
main().catch(e=>{console.error(e);process.exitCode=1});
