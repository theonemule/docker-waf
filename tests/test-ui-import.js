const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

(async () => {
  const handlers = {};
  const calls = [];
  function node() {
    return { className: '', textContent: '', style:{}, isConnected:true,
      setAttribute() {}, removeAttribute() {}, addEventListener() {},
      append() {}, replaceChildren() {}, remove() {} };
  }
  const memory = new Map();
  const sandbox = {
    URLSearchParams,
    sessionStorage: {
      getItem:key=> memory.get(key) || null,
      setItem:(key,value)=> memory.set(key,value),
      removeItem:key=> memory.delete(key)
    },
    document: {
      body:{appendChild() {}},
      addEventListener: (type, handler) => { handlers[type] = handler; },
      getElementById: () => null,
      createElement: () => node()
    },
    fetch: async (url) => {
      calls.push(url);
      return { ok: true, text: async () => 'Imported.' };
    },
    window: { location: { assign: () => {} }, setTimeout() {} }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/admin.js'), 'utf8'), sandbox);

  async function submitImport(dataset) {
    const status = {};
    const button = { disabled: false, setAttribute() {}, removeAttribute() {} };
    const file = { name: 'sites.tar.gz' };
    const form = {
      dataset,
      querySelector: (selector) => ({
        '.upload-status': status,
        'input[type="file"]': { files: [file] },
        'input[name="certificates"]': { checked: true },
        'button[type="submit"]': button
      })[selector],
      appendChild: () => {}
    };
    await handlers.submit({ target: { closest: (selector) => selector === '.bundle-import-form' ? form : null }, preventDefault: () => {} });
    assert.equal(button.disabled, false);
    return new URL(calls.at(-1), 'https://localhost');
  }

  let url = await submitImport({ scope: 'site', host: 'example.com', redirect: '/' });
  assert.equal(url.searchParams.get('scope'), 'site');
  assert.equal(url.searchParams.get('host'), 'example.com');
  assert.equal(url.searchParams.get('certificates'), '1');

  url = await submitImport({ redirect: '/' });
  assert.equal(url.searchParams.has('scope'), false);
  assert.equal(url.searchParams.has('host'), false);
  console.log('PASS: site and global import form forwarding');
})().catch(error => { console.error(error); process.exitCode = 1; });

(function(){
const vm=require("node:vm"); const fs=require("node:fs"); const path=require("node:path"); const assert=require("node:assert/strict");
(async()=>{
  const handlers={};
  const fetched=[];
  const notifications=[];
  const flash=new Map();
  const creates=[];
  let navigate=null;
  let response={ok:true,redirected:true,url:'https://liteedge.test/admin/site?host=alpha.example',text:async()=>'<h1>Sites</h1>'};
  function dom(){return {id:'',className:'',style:{},textContent:'',isConnected:true,attributes:{},
    setAttribute(k,v){this.attributes[k]=v;},removeAttribute(k){delete this.attributes[k];},
    addEventListener(){},append(){},replaceChildren(child){if(child){notifications.push(child);}},remove(){},
    querySelector(){return null},querySelectorAll(){return []}};}
  const region=dom();
  const button={tagName:'BUTTON',name:'',value:'',disabled:false,textContent:'Save email',attributes:{},
    getAttribute(k){return k==='formaction'?'/admin/cert/email/save':null;},
    setAttribute(k,v){this.attributes[k]=v;},removeAttribute(k){delete this.attributes[k];}};
  const form={method:'post',dataset:{},getAttribute(k){return k==='action'?'/admin/cert/letsencrypt':null;},
    querySelectorAll(){return [button];},querySelector(k){return k.includes('file')?null:button;},matches(){return false;}};
  const sandbox={URL,URLSearchParams,
    location:{href:'https://liteedge.test/admin/site?host=alpha.example'},
    sessionStorage:{getItem:k=>flash.get(k)||null,setItem:(k,v)=>flash.set(k,v),removeItem:k=>flash.delete(k)},
    FormData:class {constructor(){this.data=new Map([['host','alpha.example'],['email','site@example.net']]);}
      set(k,v){this.data.set(k,v);}*[Symbol.iterator](){yield* this.data;}},
    DOMParser:class {parseFromString(){return {querySelector(){return null;}};}},
    document:{body:{appendChild(){}},createElement(){const n=dom();creates.push(n);return n;},
      getElementById(k){return k==='liteedge-action-feedback'?region:null;},
      addEventListener:(name,cb)=>handlers[name]=cb},
    window:{location:{assign(v){navigate=v;}},setTimeout(){}},
    fetch:async (url,options)=>{fetched.push({url,options});return response;}
  };
  const source=fs.readFileSync(path.resolve(__dirname,'../ui/admin.js'),'utf8');
  vm.runInNewContext(source,sandbox,{filename:'admin.js'});
  const event={target:{closest(sel){return sel==='form'?form:null;}},submitter:button,preventDefault(){this.prevented=true;}};
  await handlers.submit(event);
  assert.equal(event.prevented,true);
  assert.equal(fetched[0].url,'https://liteedge.test/admin/cert/email/save','button formaction must override form action');
  assert.match(String(fetched[0].options.body),/email=site%40example.net/);
  assert.equal(button.disabled,false);
  assert.equal(navigate,response.url);
  assert.match(flash.get('liteedge:last-action'),/completed successfully/);
  response={ok:false,redirected:false,url:'https://liteedge.test/error',text:async()=>'<h1>Request failed</h1>'};
  navigate=null;
  await handlers.submit(event);
  assert.equal(navigate,null,'failed action must not navigate');
  assert.equal(button.disabled,false,'failed action must enable form');
  assert.ok(notifications.some(n=>String(n.className).includes('alert-danger')),'failed action must show visible error');
  console.log('PASS admin UI action progress, button-specific form actions, successful redirect, and error feedback');
})().catch(e=>{console.error(e);process.exitCode=1;});

})();
