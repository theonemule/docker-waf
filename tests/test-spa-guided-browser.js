"use strict";
// Optional real-browser QA: PLAYWRIGHT_MODULE=playwright-core CHROMIUM_PATH=/path/to/chromium node ...
const assert=require("node:assert/strict"), fs=require("node:fs"), http=require("node:http"), path=require("node:path");
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||"playwright-core");
const ui=path.join(__dirname,"../ui");
const route={id:"0123456789abcdef",path:"/api",match:"prefix",target:"http://app:8080",backends:"",waf:"1",waf_pl:"1",weights:[],features:{schemes:["http","https"]}};
const sites=[{host:"manual.test",aliases:"",enabled:true,tls:"none",provider:"",route_count:1},{host:"managed.test",aliases:"",enabled:true,tls:"manual",provider:"cluster-a",route_count:1}];
let reads=[],writes=[];
const server=http.createServer((req,res)=>{
  const u=new URL(req.url,"http://localhost");
  if(u.pathname.startsWith("/api/v1/")){
    const endpoint=u.pathname.slice(8);
    reads.push(endpoint);
    const s=sites.find(s=>s.host===u.searchParams.get("host"));
    let body={ok:true};
    if(endpoint==="site-inventory")body.sites=sites;
    else if(endpoint==="site-overview")body.site={...s,routes:[route],listeners:["http","https"],tls_listeners:{},disabled_rules:[]};
    else if(endpoint==="site-configuration")body.configuration="# current nginx";
    else if(endpoint==="route-detail"){body.route=route;body.provider=s.provider;}
    else if(endpoint==="installed-plugins")body.installed=[{name:"test-plugin"}];
    else if(endpoint.startsWith("actions/")){let raw="";req.on("data",chunk=>raw+=chunk);req.on("end",()=>{writes.push(Object.fromEntries(new URLSearchParams(raw)));res.setHeader("Content-Type","application/json");res.end(JSON.stringify(body));});return;}
    else{res.statusCode=404;body.ok=false;body.error="Unknown "+endpoint;}
    res.setHeader("Content-Type","application/json");res.end(JSON.stringify(body));return;
  }
  const file=path.join(ui,u.pathname==="/"?"index.html":u.pathname.replace(/^\/assets\//,""));
  if(!fs.existsSync(file)){res.statusCode=404;res.end();return;}
  res.setHeader("Content-Type",file.endsWith(".js")?"application/javascript":file.endsWith(".css")?"text/css":"text/html");
  res.end(fs.readFileSync(file));
});
(async()=>{
  await new Promise(resolve=>server.listen(0,"127.0.0.1",resolve));
  let browser;
  try{
    browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||undefined,args:["--no-sandbox","--disable-dev-shm-usage"]});
    const page=await browser.newPage();
    const errors=[];page.on("pageerror",e=>errors.push(e.message));
    await page.goto("http://127.0.0.1:"+server.address().port+"/");
    await page.getByRole("link",{name:"manual.test"}).click();
    await page.getByRole("heading",{name:"manual.test"}).waitFor();
    assert.deepEqual(reads,["site-inventory","site-overview"]);
    await page.getByRole("button",{name:"Advanced",exact:true}).click();
    await page.locator('[name="config"]').waitFor();
    assert.equal(reads.at(-1),"site-configuration");
    await page.getByRole("button",{name:"Routes",exact:true}).click();
    await page.getByRole("button",{name:"Advanced",exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('[name="config"]')?.value==="# current nginx");
    assert.equal(reads.filter(x=>x==="site-configuration").length,2);
    await page.getByRole("button",{name:"Routes",exact:true}).click();
    await page.getByRole("button",{name:"Add route",exact:true}).click();
    const form=page.locator("form[data-route-editor]");
    await form.waitFor();
    const next=()=>form.getByRole("button",{name:"Continue"}).click();
    const step=async n=>assert.equal(await form.getAttribute("data-route-step-index"),String(n));
    await step(0);
    assert.equal(await form.locator('[data-route-step]:visible').count(),1);
    await next();await step(1);
    await next();await step(1); // a missing destination blocks progression
    await form.locator("[data-pool-url]").fill("http://backend:8080");
    await next();await step(2);
    await form.locator('[name="waf"]').uncheck();
    assert.equal(await form.locator("[data-waf-extra]").isVisible(),false);
    await form.locator('[name="waf"]').check();
    await next();await step(3);
    assert.equal(await form.locator("[data-tls-option]").isVisible(),false);
    await next();await step(4);
    assert.match(await form.locator("[data-route-review]").innerText(),/http:\/\/backend:8080/);
    await form.getByRole("button",{name:"Add route",exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector("#spa-dialog").open);
    assert.equal(writes.length,1);assert.equal(writes[0].target,"http://backend:8080");assert.equal(writes[0].waf,"1");
    await page.getByRole("button",{name:"Configure",exact:true}).click();
    await form.waitFor();assert.equal(await form.getAttribute("data-route-mode"),"all");
    assert.equal(await form.locator("[data-pool-url]").inputValue(),"http://app:8080");
    await form.locator('[name="route_purpose"]').selectOption("redirect");
    assert.equal(await form.locator("[data-pool]").isVisible(),false);
    await form.locator('[name="redirect_host"]').fill("new.test");
    await form.getByRole("button",{name:"Save route"}).click();
    await page.waitForFunction(()=>!document.querySelector("#spa-dialog").open);
    assert.equal(JSON.parse(writes[1].features_json).redirect.hostname,"new.test");assert.equal(writes[1].target,"");
    // A gRPC route hides incompatible HTTP-only fields but submits protocol correctly.
    await page.getByRole("button",{name:"Add route",exact:true}).click();await form.waitFor();
    await form.locator('[name="route_purpose"]').selectOption("grpc");await next();
    await form.locator("[data-pool-url]").fill("http://grpc:50051");await next();await next();
    assert.equal(await form.locator("[data-http-option]:visible").count(),0);
    await next();await form.getByRole("button",{name:"Add route",exact:true}).click();
    await page.waitForFunction(()=>!document.querySelector("#spa-dialog").open);
    assert.equal(JSON.parse(writes[2].features_json).grpc,true);
    await page.getByRole("link",{name:"All sites"}).click();
    await page.getByRole("link",{name:"managed.test"}).click();
    await page.getByRole("heading",{name:"managed.test"}).waitFor();
    assert.equal(await page.getByRole("button",{name:"Add route",exact:true}).count(),0);
    assert.equal(await page.getByRole("button",{name:"Advanced",exact:true}).count(),0);
    await page.getByRole("button",{name:"View details"}).click();
    await page.getByText("Read-only configuration").waitFor();
    assert.equal(writes.length,3);assert.deepEqual(errors,[]);
    console.log("PASS real browser: scoped reads, fresh advanced reads, wizard steps, validation, proxy/redirect/gRPC saves, managed read-only");
  }finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(e=>{console.error(e);process.exitCode=1;});
