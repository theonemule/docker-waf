"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const path=require("node:path");
const source=fs.readFileSync(path.join(__dirname,"../ui/spa.js"),"utf8");
const start=source.indexOf("  function savedLogScopes(filters,catalog) {");
const end=source.indexOf("  function uploadDialog(kind,host=\"\") {",start);
assert(start>=0&&end>start,"Cannot find real SPA log controller");
class FakeFormData {
  constructor(form){this.form=form;}
  *entries(){yield* this.form.fields;}
}
const context={
  FormData:FakeFormData,
  cache:{filters:{}},
  escape:x=>String(x).replace(/[&<>"']/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch])),
  select:()=>"",
  field:()=>"",
  card:()=>"",
  root:{innerHTML:"",querySelector:()=>null}
};
vm.createContext(context);
vm.runInContext(source.slice(start,end),context,{filename:"ui/spa.js"});
const catalog={hosts:[
  {name:"alpha.test",site:"alpha.test",kind:"site"},
  {name:"www.alpha.test",site:"alpha.test",kind:"alias"},
  {name:"beta.test",site:"beta.test",kind:"site"}
],routes:[
  {site:"alpha.test",route:"prefix:/api/"},
  {site:"beta.test",route:"exact:/health"}
]};
assert.deepEqual(JSON.parse(JSON.stringify(context.savedLogScopes({host:"www.alpha.test",route:"prefix:/api/"},catalog))),
  [{host:"www.alpha.test",site:"alpha.test",routes:["prefix:/api/"]}]);
const markup=context.logPicker("hosts","Hosts",catalog.hosts,new Set(),new Set());
assert(markup.includes("data-log-host")&&markup.includes("data-log-picker-search")&&markup.includes("www.alpha.test"));
assert(!markup.includes('name="host"'),"Log host selection must use scopes_json, not scalar host");
const summaries={host:{textContent:""},route:{textContent:"",attributes:{},setAttribute(name,val){this.attributes[name]=val;}}};
const routePicker={open:false,querySelector(){return summaries.route;}};
function fakeCheckbox(value,site){
 const row={hidden:false,textContent:value+" "+site};
 return {value,dataset:{site},checked:false,disabled:false,closest:()=>row,row};
}
const hosts=catalog.hosts.map(v=>fakeCheckbox(v.name,v.site));
const routes=catalog.routes.map(v=>fakeCheckbox(v.route,v.site));
const form={
 fields:[["type","all"],["limit","100"],["since","0"]],
 querySelectorAll(selector){
  if(selector==="[data-log-host]:checked")return hosts.filter(x=>x.checked);
  if(selector==="[data-log-route]:checked")return routes.filter(x=>x.checked);
  if(selector==="[data-log-host]")return hosts;
  if(selector==="[data-log-route]")return routes;
  return [];
 },
 querySelector(selector){
  switch(selector){
   case '[data-log-picker-search="routes"]':return {value:""};
   case '[data-log-picker="hosts"] [data-log-summary]':return summaries.host;
   case '[data-log-picker="routes"] [data-log-summary]':return summaries.route;
   case '[data-log-picker="routes"]':return routePicker;
  }
  return null;
 }
};
context.updateLogSelectors(form);
assert(routes.every(x=>x.disabled),"Cannot select routes without a host");
assert.equal(context.logHasFilter(context.logQuery(form)),false,"No filters should not search event logs");
hosts[0].checked=true;
context.updateLogSelectors(form);
assert.equal(routes[0].disabled,false);
assert.equal(routes[1].disabled,true);
routes[0].checked=true;
hosts[1].checked=true;
context.updateLogSelectors(form);
let query=context.logQuery(form);
let scopes=JSON.parse(query.scopes_json);
assert.equal(scopes.length,2);
assert.equal(scopes[0].host,"alpha.test");
assert.equal(scopes[1].host,"www.alpha.test");
assert.deepEqual(scopes[0].routes,["prefix:/api/"]);
assert.deepEqual(scopes[1].routes,["prefix:/api/"]);
assert.equal(context.logHasFilter(query),true);
hosts[2].checked=true;
context.updateLogSelectors(form);
assert.equal(routes[1].disabled,false);
routes[1].checked=true;
query=context.logQuery(form);scopes=JSON.parse(query.scopes_json);
assert.equal(scopes.length,3);
assert.deepEqual(scopes[2].routes,["exact:/health"]);
assert.equal(JSON.parse(JSON.stringify(context.savedLogScopes(query,catalog))).length,3);
hosts[0].checked=false;
hosts[1].checked=false;
context.updateLogSelectors(form);
assert.equal(routes[0].disabled,true,"Unrelated route must be disabled");
assert.equal(routes[0].checked,false,"Unrelated route must be deselected");
assert.equal(routes[1].checked,true);
assert.equal(context.logHasFilter({type:"all",limit:"100",since:"0",scopes_json:"[]"}),false);
assert.equal(context.logHasFilter({type:"http",limit:"100",since:"0",scopes_json:"[]"}),true);
assert.equal(context.logHasFilter({type:"all",limit:"100",since:"1790000000",scopes_json:"[]"}),true);
console.log("PASS SPA Logs multi-select: hosts, aliases, dependent routes, scope serialization, persistence, stale-route removal, blank query guard");
