"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const path=require("node:path");
const source=fs.readFileSync(path.join(__dirname,"../ui/spa.js"),"utf8");
function extract(from,to){
 const start=source.indexOf(from),end=source.indexOf(to,start);
 assert(start>=0&&end>start,"SPA function not found: "+from);
 return source.slice(start,end);
}
const code=extract("  function closeOtherLogPickers(target) {","  document.addEventListener(\"click\",async(event)=>{")
 +extract("  function closeLogPickersOnEscape(event) {","  document.addEventListener(\"keydown\",closeLogPickersOnEscape);");
function picker(name){
 const summary={focusCalled:false,focus(){this.focusCalled=true;}};
 return {name,open:false,summary,querySelector(sel){assert.equal(sel,"summary");return summary;}};
}
const hosts=picker("hosts"),routes=picker("routes");
const document={querySelectorAll(sel){
 assert.equal(sel,"[data-log-picker][open]");
 return [hosts,routes].filter(x=>x.open);
}};
const sandbox={document};
vm.runInNewContext(code,sandbox);
const targetOf=(element)=>({closest(sel){assert.equal(sel,"[data-log-picker]");return element;}});
function keyboard(element,key="Escape"){
 return {key,target:targetOf(element),prevented:false,preventDefault(){this.prevented=true;}};
}
hosts.open=true;
sandbox.closeOtherLogPickers(targetOf(hosts));
assert.equal(hosts.open,true,"Click inside menu must not close it");
routes.open=true;
sandbox.closeOtherLogPickers(targetOf(routes));
assert.equal(hosts.open,false,"Opening routes must close hosts");
assert.equal(routes.open,true,"Current picker remains open");
sandbox.closeOtherLogPickers(targetOf(null));
assert.equal(routes.open,false,"Click outside closes dropdown");
assert.equal(hosts.summary.focusCalled,false,"Mouse dismissal must not move focus");
hosts.open=true;
const escape=keyboard(hosts);
sandbox.closeLogPickersOnEscape(escape);
assert.equal(hosts.open,false);
assert.equal(hosts.summary.focusCalled,true,"Escape returns focus to summary");
assert.equal(escape.prevented,true);
const noMenu=keyboard(null);
sandbox.closeLogPickersOnEscape(noMenu);
assert.equal(noMenu.prevented,false,"Escape without menu stays available to dialogs");
hosts.open=true;routes.open=true;
const second=keyboard(routes);
sandbox.closeLogPickersOnEscape(second);
assert.equal(hosts.open,false);
assert.equal(routes.open,false);
assert.equal(routes.summary.focusCalled,true);
console.log("PASS SPA dropdown dismissal: outside click, mutual exclusivity, inside click, Escape, focus, and no dialog interference");
