"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs");
const vm=require("node:vm");
const path=require("node:path");
const src=fs.readFileSync(path.join(__dirname,"../ui/spa.js"),"utf8");
const start=src.indexOf("  function formValues(form) {");
const end=src.indexOf("  async function mutation(form)",start);
const ctx={FormData:class {constructor(form){this.form=form;}entries(){return Object.entries(this.form.values);}}};
vm.createContext(ctx);
vm.runInContext(src.slice(start,end),ctx);
function form(values,urls=["http://app:8080","http://canary:8080"],weights=[3,1]){
  return {values,dataset:{apiAction:"route/save"},
    querySelector(s){return s==="[data-pool]"||s==="[data-route-methods]"?{}:null;},
    querySelectorAll(s){if(s==="[data-route-method]:checked")return ["GET","POST"].map(value=>({value}));
      if(s==="[data-pool-url]")return urls.map(value=>({value}));
      if(s==="[data-pool-weight]")return weights.map(value=>({value:String(value)}));throw Error(s);}
  };
}
const f={host:"example.test",path:"/app",feature_action:"rewrite",feature_schemes:"http",feature_method:"GET",feature_precedence:"10",feature_headers:"X-Mode=canary",feature_queries:"version=two",feature_header_ops:"set X-Set=ok\nadd X-Mix=added\nremove X-Remove",feature_response_ops:"set X-Response=ok\nremove X-Remove",rewrite_host:"backend.example.test",typed_rewrite_path_type:"prefix",typed_rewrite_path:"/v2"};
let data=ctx.formValues(form(f));
let features=JSON.parse(data.features_json);
assert.equal(data.target,"http://app:8080");
assert.equal(data.backends,"http://canary:8080");
assert.equal(data.backend_weights,"3,1");
assert.deepEqual(features.rewrite,{hostname:"backend.example.test",path:{type:"prefix",value:"/v2"}});
assert.deepEqual(features.query_matches,[{name:"version",value:"two"}]);
assert.equal(features.request_headers.length,3);
assert.equal(features.response_headers.length,2);
assert.equal(features.method,"GET");
assert.equal(features.precedence,10);
assert.equal(data.methods,"GET,POST");
assert(!("feature_action" in data));
data=ctx.formValues(form({feature_action:"redirect",feature_schemes:"http",redirect_scheme:"https",redirect_status:"308",redirect_path_type:"full",redirect_path:"/new"},[],[]));
features=JSON.parse(data.features_json);
assert.equal(data.target,"");
assert.equal(data.backend_weights,"");
assert.equal(data.force_https,"0");
assert.equal(features.redirect.status_code,308);
assert.deepEqual(features.redirect.path,{type:"full",value:"/new"});
assert.throws(()=>ctx.formValues(form(f,["http://app:8080"],[0])),/weights/);
assert.throws(()=>ctx.formValues(form({...f,feature_queries:"bad"})),/name=value/);
assert(src.includes("routeSummary(r,true)"),"managed routes must use common detailed summary");
assert(src.includes("updateRouteActionFields(dialog.querySelector"),"route editor initializes action-specific controls");
data=ctx.formValues(form({feature_action:"proxy",feature_mirrors:"http://shadow:8080\nhttp://shadow2:8080"}));
assert.deepEqual(JSON.parse(data.features_json).mirrors,[{target:"http://shadow:8080",basis_points:10000},{target:"http://shadow2:8080",basis_points:10000}]);
assert.throws(()=>ctx.formValues(form({feature_action:"proxy",feature_mirrors:"a\nb\nc\nd\ne"})),/four/);
console.log("PASS SPA advanced route form serialization, validation and managed display");

const sampled=ctx.formValues(form({feature_action:"proxy",feature_mirrors:"http://shadow:8080 | 33.33"}));
assert.equal(JSON.parse(sampled.features_json).mirrors[0].basis_points,3333);
assert.throws(()=>ctx.formValues(form({feature_action:"proxy",feature_mirrors:"http://shadow:8080 | "})),/percentage/);
assert.throws(()=>ctx.formValues(form({feature_action:"proxy",feature_mirrors:"http://shadow:8080 | 33.333"})),/percentage/);

assert.deepEqual(JSON.parse(ctx.formValues(form({...f,feature_schemes:"http,http:8080"})).features_json).schemes,["http","http:8080"]);
assert.throws(()=>ctx.formValues(form({...f,feature_schemes:"http:9443"})),/listener list/);
assert.throws(()=>ctx.formValues(form({...f,feature_schemes:"http,http"})),/listener list/);

const retry=JSON.parse(ctx.formValues(form({...f,feature_retry_attempts:"2",feature_retry_codes:"502,503",feature_retry_budget:"400"})).features_json).retry;
assert.deepEqual(retry,{attempts:2,codes:[502,503],budget_ms:400});
assert.throws(()=>ctx.formValues(form({...f,feature_retry_attempts:"0",feature_retry_codes:"503"})),/retry policy/);
const tlsForm={feature_action:"proxy",feature_backend_tls_host:"backend.example.test",feature_backend_tls_ca:"-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----"};
const tlsFeatures=JSON.parse(ctx.formValues(form(tlsForm,["https://app:8443","https://canary:8443"])).features_json);
assert.equal(tlsFeatures.backend_tls.hostname,"backend.example.test");
assert(tlsFeatures.backend_tls.ca_certificate.endsWith("\n"));
assert.throws(()=>ctx.formValues(form(tlsForm)),/HTTPS origins/);
assert.throws(()=>ctx.formValues(form({...tlsForm,feature_backend_tls_host:""},["https://app:8443"],[1])),/DNS identity/);

assert.deepEqual(JSON.parse(ctx.formValues(form({...f,feature_schemes:"http,https:8443"})).features_json).schemes,["http","https:8443"]);
assert.throws(()=>ctx.formValues(form({...f,feature_schemes:"https:9443"})),/listener list/);

const timing=JSON.parse(ctx.formValues(form({...f,feature_request_ms:"1000",feature_backend_ms:"250",feature_retry_attempts:"1",feature_retry_backoff:"100"})).features_json);
assert.deepEqual(timing.deadlines,{request_ms:1000,backend_ms:250});
assert.equal(timing.retry.backoff_ms,100);
assert.throws(()=>ctx.formValues(form({...f,feature_request_ms:"100",feature_backend_ms:"200"})),/Backend deadline/);

const peerTrust={"https://one.example.test:8443":{hostname:"one.example.test",ca_certificate:"PEM"}};
const peerForm=form({...f,feature_backend_tls_peers:JSON.stringify(peerTrust)});
const previousQuery=peerForm.querySelectorAll.bind(peerForm);
peerForm.querySelectorAll=(selector)=>selector==="[data-pool-url]"?[{value:"https://one.example.test:8443"},{value:"http://two.example.test:8080"}]:selector==="[data-pool-weight]"?[{value:"1"},{value:"2"}]:previousQuery(selector);
assert.deepEqual(JSON.parse(ctx.formValues(peerForm).features_json).backend_tls_peers,peerTrust);

const grpc=ctx.formValues(form({feature_action:"proxy",feature_grpc:"1",feature_method:"GET"}));
assert.equal(JSON.parse(grpc.features_json).grpc,true);
assert.equal(JSON.parse(grpc.features_json).method,"POST");
assert.equal(grpc.websocket,"0");
assert.throws(()=>ctx.formValues(form({...f,feature_grpc:"1"})),/gRPC/);
assert.throws(()=>ctx.formValues(form({feature_action:"proxy",feature_grpc:"1",feature_request_ms:"1000"})),/gRPC/);
assert(src.includes('form("stream/save"'),"transport editor uses native API");
