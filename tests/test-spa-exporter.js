"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const path=require("node:path");
const source=fs.readFileSync(path.join(__dirname,"../ui/spa.js"),"utf8");
const start=source.indexOf("  function updateExporterFields(form) {");
const end=source.indexOf("  function renderAlerts(data) {",start);
assert(start>=0 && end>start,"Missing real SPA exporter controller");
const fieldsByMode=Object.fromEntries(["syslog","https","otlp"].map(mode=>[
  mode,{dataset:{exportMode:mode},hidden:false,style:{},controls:[{disabled:false},{disabled:false}],
    querySelectorAll(selector){assert.equal(selector,"input,select,textarea");return this.controls;}}
]));
let selected="otlp";
const form={
  querySelector(selector){assert.equal(selector,'select[name="mode"]');return {value:selected};},
  querySelectorAll(selector){assert.equal(selector,"[data-export-mode]");return Object.values(fieldsByMode);}
};
const root={innerHTML:"",querySelector(selector){
  assert.equal(selector,'form[data-api-action="collector/save"]');
  return form;
}};
const context={root,
  card:(title,body)=>'<section><h3>'+title+'</h3>'+body+'</section>',
  form:(name,body)=>'<form data-api-action="'+name+'">'+body+'</form>',
  field:(label,name,value="",type="text",extra="")=>'<input name="'+name+'" value="'+value+'" type="'+type+'" '+extra+'>',
  select:(label,name,choices,value)=>'<select name="'+name+'">'+choices.map(([id,text])=>'<option value="'+id+'"'+(id===value?' selected':'')+'>'+text+'</option>').join("")+'</select>',
  rowActions:()=>""};
vm.createContext(context);
vm.runInContext(source.slice(start,end),context,{filename:"ui/spa.js"});
context.renderServer({settings:{},collector:{mode:"otlp",url:"http://otel.internal:4318/v1/logs",service_name:"liteedge.proxy"}});
assert.match(root.innerHTML,/OpenTelemetry \(OTLP\/HTTP JSON\)/);
assert.match(root.innerHTML,/value="http:\/\/otel.internal:4318\/v1\/logs"/);
assert.match(root.innerHTML,/name="service_name" value="liteedge.proxy"/);
assert.match(root.innerHTML,/data-export-mode="syslog"/);
assert.match(root.innerHTML,/data-export-mode="https"/);
assert.match(root.innerHTML,/data-export-mode="otlp"/);
assert.match(root.innerHTML,/name="protocol"/);
assert.match(root.innerHTML,/gRPC is not supported/);
function assertMode(mode){
  selected=mode;
  context.updateExporterFields(form);
  for(const group of Object.values(fieldsByMode)){
    const active=group.dataset.exportMode===mode;
    assert.equal(group.hidden,!active,group.dataset.exportMode+" visibility");
    assert.equal(group.style.display,active?"":"none",group.dataset.exportMode+" CSS visibility");
    for(const field of group.controls)assert.equal(field.disabled,!active,group.dataset.exportMode+" form participation");
  }
}
assertMode("off");
assertMode("syslog");
assertMode("https");
assertMode("otlp");
assert.match(source,/data-api-action="collector\/save"] select\[name="mode"]/,"Mode change must invoke exporter-field update");
console.log("PASS exporter SPA: OTLP form, mode-specific transport fields, visibility, disabled inactive controls");
