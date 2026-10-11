/* LiteEdge SPA. UI owns presentation, API owns state and validation.
 * No server-generated HTML, native form submissions, or document reloads.
 * HTTP Basic credentials are managed by the browser (credentials:same-origin)
 * and verified independently by NGINX for every API request.
 */
(() => {
  "use strict";
  const root = document.getElementById("spa-root");
  const dialog = document.getElementById("spa-dialog");
  const feedback = document.getElementById("spa-feedback");
  const cache = {sites:[], site:null, plugins:[], catalog:null, rules:[], filters:{}};
  let crsCheckSequence = 0;
  const escape = (value) => String(value ?? "").replace(/[&<>"']/g, ch =>
    ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch]));
  const q = (value) => encodeURIComponent(String(value));
  const checked = (value) => value === "1" || value === true ? "checked" : "";
  const opts = (choices,value) => choices.map(([id,label]) =>
    '<option value="'+escape(id)+'" '+(String(id)===String(value)?"selected":"")+'>'+escape(label)+'</option>').join("");
  const navUrl = (view,host="") => "#/"+view+(host?"/"+q(host):"");
  const current = () => {
    const parts=(location.hash.replace(/^#\/?/,"")||"sites").split("/");
    return {view:parts[0]||"sites",host:decodeURIComponent(parts.slice(1).join("/"))};
  };
  const renderError = (err) => { root.innerHTML='<div class="alert alert-danger" role="alert">'+escape(err.message||err)+'</div>'; };
  function toast(message,kind="success") {
    feedback.innerHTML='<div class="alert alert-'+(kind==="danger"?"danger":"success")+' shadow d-flex gap-3">'
      +'<span class="flex-grow-1">'+escape(message)+'</span><button type="button" class="btn-close" data-toast-close aria-label="Dismiss"></button></div>';
  }
  async function api(path) {
    const response=await fetch("/api/v1/"+path,{credentials:"same-origin",cache:"no-store",headers:{Accept:"application/json"}});
    if (response.status===401) throw new Error("Authentication required. Sign in to LiteEdge again.");
    const body=await response.json().catch(()=>null);
    if (!response.ok || !body || body.ok===false) throw new Error(body?.error||"API request failed (HTTP "+response.status+")");
    return body;
  }
  async function act(name,values={}) {
    const params=new URLSearchParams();
    Object.entries(values).forEach(([key,val])=> {if(val!==null&&val!==undefined) params.set(key,String(val));});
    const response=await fetch("/api/v1/actions/"+name,{
      method:"POST",credentials:"same-origin",cache:"no-store",
      headers:{Accept:"application/json","Content-Type":"application/x-www-form-urlencoded","X-LiteEdge-API":"1"},
      body:params.toString()
    });
    if (response.status===401) throw new Error("Authentication required. Sign in again.");
    const result=await response.json().catch(()=>null);
    if(!response.ok||!result||result.ok!==true) throw new Error(result?.error||"Request failed (HTTP "+response.status+")");
    return result;
  }
  async function transfer(path,filename) {
    const response=await fetch("/api/v1/"+path,{credentials:"same-origin",cache:"no-store"});
    if(!response.ok) throw new Error("Export failed (HTTP "+response.status+")");
    const blob=await response.blob();
    const url=URL.createObjectURL(blob),anchor=document.createElement("a");
    anchor.href=url;anchor.download=filename;anchor.style.display="none";document.body.appendChild(anchor);
    anchor.click();anchor.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);
  }
  async function upload(path,file) {
    if(!file)throw new Error("Select an archive.");
    const response=await fetch("/api/v1/"+path,{
      method:"POST",credentials:"same-origin",cache:"no-store",
      headers:{"Content-Type":"application/octet-stream","X-LiteEdge-API":"1"},body:file
    });
    const result=await response.json().catch(()=>null);
    if(!response.ok||!result||result.ok!==true)throw new Error(result?.error||"Upload failed (HTTP "+response.status+")");
    return result;
  }
  function field(label,name,value="",type="text",extra="") {
    return '<label class="d-block"><span class="form-label">'+escape(label)+'</span><input class="form-control" name="'+escape(name)+'" type="'+escape(type)+'" value="'+escape(value)+'" '+extra+'></label>';
  }
  function textarea(label,name,value="",rows=6) {
    return '<label class="d-block"><span class="form-label">'+escape(label)+'</span><textarea class="form-control font-monospace" rows="'+rows+'" name="'+escape(name)+'">'+escape(value)+'</textarea></label>';
  }
  function select(label,name,choices,value) {
    return '<label class="d-block"><span class="form-label">'+escape(label)+'</span><select class="form-select" name="'+escape(name)+'">'+opts(choices,value)+'</select></label>';
  }
  function check(label,name,val) {
    return '<label class="spa-check"><input type="checkbox" class="form-check-input" name="'+escape(name)+'" value="1" '+checked(val)+'><span>'+escape(label)+'</span></label>';
  }
  function card(title,content,footer="") {
    return '<section class="card shadow-sm mb-3"><div class="card-header"><strong>'+escape(title)+'</strong></div><div class="card-body">'+content+'</div>'
      +(footer?'<div class="card-footer">'+footer+'</div>':"")+'</section>';
  }
  function form(name,content,submit="Save",css="") {
    return '<form data-api-action="'+escape(name)+'" class="'+css+'">'+content+
      '<div class="mt-3"><button class="btn btn-primary" type="submit">'+escape(submit)+'</button></div></form>';
  }
  function rowActions(actions) {
    return '<div class="d-flex flex-wrap gap-2">'+actions.map(a =>
      '<button type="button" class="btn btn-sm '+(a.danger?'btn-outline-danger':'btn-outline-primary')+'" data-operation="'+escape(a.op)+'" '
      +Object.entries(a.data||{}).map(([k,v])=>'data-'+escape(k)+'="'+escape(v)+'"').join(" ")+'>'+escape(a.label)+'</button>').join("")+'</div>';
  }
  function modal(title,body) {
    dialog.innerHTML='<div class="card border-0"><div class="card-header d-flex justify-content-between align-items-center">'
      +'<strong>'+escape(title)+'</strong><button class="btn-close" data-dismiss-dialog type="button" aria-label="Close"></button></div>'
      +'<div class="card-body">'+body+'</div></div>';
    dialog.showModal();
  }
  function loading() {
    root.innerHTML='<div class="d-flex gap-2 align-items-center text-secondary">'
      +'<div class="spinner-border spinner-border-sm" aria-hidden="true"></div>Loading…</div>';
  }
  async function refresh() {
    const page=current();
    document.querySelectorAll("[data-nav]").forEach(el=>el.classList.toggle("active",el.getAttribute("href")==="#/"+(page.view==="site"?"sites":page.view)));
    loading();
    try {
      if(page.view==="sites") return renderSites((await api("sites")).sites);
      if(page.view==="site") return renderSite((await api("site?host="+q(page.host))).site);
      if(page.view==="server") return renderServer(await api("server"));
      if(page.view==="alerts") return renderAlerts(await api("alerts"));
      if(page.view==="owasp") {
        renderOwasp(await api("owasp"));
        void checkCrsUpdates();
        return;
      }
      if(page.view==="logs") return renderLogs(await api("catalog"));
      root.innerHTML='<div class="alert alert-warning">Page not found.</div>';
    } catch(err){renderError(err);}
  }
  function renderSites(sites) {
    cache.sites=sites;
    root.innerHTML='<div class="d-flex justify-content-between align-items-center mb-3"><h1 class="h3">Sites</h1>'
      +rowActions([{op:"add-site",label:"Add site"},{op:"import",label:"Import"},{op:"export",label:"Export"}])+'</div>'
      +'<div class="card table-responsive"><table class="table table-hover align-middle mb-0"><thead><tr>'
      +'<th>Host</th><th>Aliases</th><th>Routes</th><th>TLS</th><th>Status</th><th>Actions</th></tr></thead><tbody>'
      +(sites.map(s=>'<tr><td><a href="'+navUrl("site",s.host)+'" data-nav>'+escape(s.host)+'</a></td>'
       +'<td>'+escape(s.aliases||"—")+'</td><td>'+s.route_count+'</td><td>'+escape(s.tls)+'</td>'
       +'<td>'+ (s.enabled?'Enabled':'Disabled')+'</td><td>'
       +rowActions([{op:"toggle-site",label:s.enabled?"Disable":"Enable",data:{host:s.host,enabled:s.enabled?"1":"0"}},
                    {op:"delete-site",label:"Delete",danger:true,data:{host:s.host}}])+'</td></tr>').join("")||
       '<tr><td colspan="6">No sites configured.</td></tr>')+'</tbody></table></div>';
  }
  function routeSummary(r) {
    return '<tr><td><code>'+escape(r.path)+'</code></td><td>'+escape(r.match)+'</td>'
      +'<td>'+escape([r.target,...String(r.backends||"").split(",").filter(Boolean)].join(", "))+'</td>'
      +'<td>'+escape(r.lb_mode||"round_robin")+'</td><td>'
      +rowActions([{op:"edit-route",label:"Configure",data:{id:r.id}},
                    {op:"delete-route",label:"Delete",danger:true,data:{id:r.id}}])+'</td></tr>';
  }
  function renderSite(site) {
    cache.site=site;
    root.innerHTML='<div class="d-flex justify-content-between align-items-center mb-3">'
      +'<div><h1 class="h3">'+escape(site.host)+'</h1><div class="small text-secondary">'
      +(site.enabled?"Enabled":"Disabled")+' · TLS '+escape(site.tls)+'</div></div>'
      +rowActions([{op:"toggle-site",label:site.enabled?"Disable site":"Enable site",data:{host:site.host,enabled:site.enabled?"1":"0"}}])+'</div>'
      +card("Hostnames",form("site/save",'<div class="spa-form-grid">'+field("Hostname","host",site.host,"text","readonly")
        +field("Aliases","aliases",site.aliases)+'</div>',"Save host"))
      +card("Routes",'<div class="mb-3">'+rowActions([{op:"add-route",label:"Add route"}])+'</div>'
        +'<div class="table-responsive"><table class="table table-sm align-middle"><thead><tr><th>Path</th><th>Match</th><th>Backends</th><th>Balancing</th><th></th></tr></thead><tbody>'
        +(site.routes.map(routeSummary).join("")||'<tr><td colspan="5">No routes configured yet.</td></tr>')+'</tbody></table></div>')
      +card("TLS certificate",'<p>Current: '+escape(site.tls)+'</p>'+form("cert/email/save",
          '<input type="hidden" name="host" value="'+escape(site.host)+'">'+field("ACME contact email","email",site.cert_email,"email"),"Save contact email")
        +'<div class="mt-3">'+rowActions([{op:"selfsigned",label:"Generate self-signed"}, {op:"letsencrypt",label:"Issue / renew Let’s Encrypt"}])+'</div>'
        +form("cert/import",'<input type="hidden" name="host" value="'+escape(site.host)+'"><div class="spa-form-grid">'
          +textarea("Certificate PEM chain","certificate","",9)+textarea("Private key PEM","private_key","",9)+'</div>',"Import PEM certificate"))
      +card("Site WAF rule exclusions",'<div class="mb-2">'+(site.disabled_rules.map(id=>'<span class="badge text-bg-light border me-2">'
           +escape(id)+' <button type="button" data-operation="enable-site-rule" data-rule-id="'+escape(id)+'" class="btn btn-sm p-0">×</button></span>').join("")||'No disabled rules')+'</div>'
           +form("waf/disable",'<input name="host" type="hidden" value="'+escape(site.host)+'">'+field("Rule ID to disable","rule_id","","text","required pattern=\"[0-9]{1,9}\""),"Disable rule"))
      +card("Advanced NGINX",'<p class="small text-secondary">Manual site configuration is validated and merged with generated configuration.</p>'
         +(site.conflict?'<div class="alert alert-warning">'+escape(site.conflict)+'</div>':"")
         +(site.delta?'<details><summary>Generated delta</summary><pre class="spa-code">'+escape(site.delta)+'</pre></details>':"")
         +form("config/save",'<input name="host" type="hidden" value="'+escape(site.host)+'">'
           +textarea("Effective configuration","config",site.configuration,24),"Validate and save")
         +rowActions([{op:"reset-config",label:"Reset to generated"}]))
      +card("Transfer configuration",rowActions([{op:"export-site",label:"Export site"},
           {op:"export-site-certs",label:"Export with certificates"},
           {op:"import-site",label:"Import site"}]));
  }
  const defaultRoute = {match:"prefix",path:"/",target:"",backends:"",timeout:"60",
    websocket:"1",force_https:"1",waf:"1",waf_pl:"1",waf_plugins:"",waf_disabled:"",
    lb_mode:"round_robin",max_fails:"3",fail_timeout:"30",
    health_enabled:"0",health_path:"/health",health_expect:"200",health_interval:"30",
    health_timeout:"5",health_fall:"3",health_rise:"2",health_cooldown:"300"};
  async function editRoute(route) {
    const r={...defaultRoute,...route};
    if(!cache.plugins.length){
      try {cache.plugins=(await api("owasp")).installed||[];}catch(_){}
    }
    const urls=[r.target,...String(r.backends||"").split(",").filter(Boolean)];
    const plugins=cache.plugins.map(p=>check(p.name,"plugin_"+p.name,
        String(r.waf_plugins||"").split(",").includes(p.name))).join("");
    modal(route?.id?"Configure route":"Add route",
      form(route?.id?"route/save":"route/add",
        '<input name="host" type="hidden" value="'+escape(cache.site.host)+'">'
        +(route?.id?'<input name="id" type="hidden" value="'+escape(route.id)+'">':"")
        +'<div class="spa-form-grid">'
        +select("Match","match",[["prefix","Prefix"],["exact","Exact"],["regex","Regex"]],r.match)
        +field("Route path","path",r.path,"text","required")
        +field("Timeout (seconds)","timeout",r.timeout,"number","min=1 max=86400 required")+'</div>'
        +'<fieldset class="border rounded p-3 my-3"><legend class="float-none fs-6">Backend pool</legend>'
        +'<div data-pool>'+urls.map(u=>poolRow(u)).join("")+'</div>'
        +'<button class="btn btn-sm btn-outline-secondary" type="button" data-operation="pool-add">+ Add backend</button>'
        +'<div class="form-text">At least one backend URL is required. A pool supports up to 16 URLs.</div></fieldset>'
        +'<div class="spa-form-grid">'
        +select("Load balancing","lb_mode",[["round_robin","Round robin"],["least_conn","Least connections"],["ip_hash","Client IP hash"],["cookie","Affinity cookie"]],r.lb_mode)
        +field("Passive failed attempts","max_fails",r.max_fails,"number","min=1 max=20")
        +field("Fail timeout (seconds)","fail_timeout",r.fail_timeout,"number","min=1 max=3600")+'</div>'
        +'<fieldset class="border rounded p-3 my-3"><legend class="float-none fs-6">Health probe</legend>'
        +check("Enable health probes","health_enabled",r.health_enabled)+'<div class="spa-form-grid">'
        +field("Probe path","health_path",r.health_path)+field("Expected status","health_expect",r.health_expect)
        +field("Interval (seconds)","health_interval",r.health_interval,"number")
        +field("Timeout (seconds)","health_timeout",r.health_timeout,"number")
        +field("Failures until down","health_fall",r.health_fall,"number")
        +field("Successes until up","health_rise",r.health_rise,"number")
        +field("Notification cooldown","health_cooldown",r.health_cooldown,"number")
        +'</div></fieldset>'
        +'<fieldset class="border rounded p-3"><legend class="float-none fs-6">WAF / route options</legend>'
        +check("OWASP CRS","waf",r.waf)+select("Paranoia level","waf_pl",
          [["1","PL1"],["2","PL2"],["3","PL3"],["4","PL4"]],r.waf_pl)
        +check("WebSocket upgrade","websocket",r.websocket)
        +check("HTTP to HTTPS redirect","force_https",r.force_https)
        +field("Excluded WAF rule IDs","waf_disabled",r.waf_disabled)
        +(plugins?'<div class="mt-2"><strong>Application and CRS plugins</strong>'+plugins+'</div>':"")
        +'</fieldset>',route?.id?"Save route":"Add route"));
  }
  function poolRow(url="") {
    return '<div class="spa-backend-row" data-pool-row>'
      +'<input class="form-control font-monospace" data-pool-url type="url" required placeholder="http://app:8080" value="'+escape(url)+'">'
      +'<button class="btn btn-sm btn-outline-danger" type="button" data-operation="pool-remove">Remove</button></div>';
  }

  function renderServer(data) {
    const v=data.settings||{},c=data.collector||{};
    root.innerHTML='<h1 class="h3 mb-3">Server Settings</h1>'
      +card("NGINX defaults",form("server/save",'<div class="spa-form-grid">'
        +field("Worker connections","worker_connections",v.worker_connections||"1024","number")
        +field("Keepalive timeout","keepalive_timeout",v.keepalive_timeout||"65","number")
        +field("Default route timeout","route_timeout",v.default_route_timeout||"60","number")
        +field("Client header timeout","header_timeout",v.client_header_timeout||"15","number")
        +field("Client body timeout","body_timeout",v.client_body_timeout||"15","number")
        +field("Send timeout","send_timeout",v.send_timeout||"30","number")
        +field("DNS resolver","resolver",v.resolver||"")+'</div>',"Save NGINX settings"))
      +card("SMTP email for alerts",form("server/smtp/save",'<div class="spa-form-grid">'
        +field("SMTP hostname","smtp_host",c.smtp_host||"")
        +field("STARTTLS port","smtp_port",c.smtp_port||587,"number","min=1 max=65535")
        +field("Sender address","mail_from",c.mail_from||"","email")
        +field("Username","smtp_user",c.smtp_user||"")
        +field("Password (blank keeps saved password)","smtp_password","","password","autocomplete=new-password")
        +'</div>',"Save SMTP settings"))
      +card("Log Export",form("collector/save",'<div class="spa-form-grid">'
        +select("Transport","mode",[["off","Disabled"],["syslog","RFC 5424 syslog"],["https","HTTPS collector"]],c.mode||"off")
        +field("Syslog hostname","host",c.host||"")
        +field("Syslog port","port",c.port||"514","number")
        +select("Syslog protocol","protocol",[["udp","UDP"],["tcp","TCP"],["tls","TLS"]],c.protocol||"udp")
        +select("HTTPS provider","provider",[["generic","Generic"],["splunk","Splunk HEC"],["datadog","Datadog"],["elastic","Elasticsearch"]],c.provider||"generic")
        +field("Collector endpoint","url",c.url||"","url")
        +field("API token (blank keeps saved token)","token","","password","autocomplete=new-password")
        +'</div>',"Save export configuration"))
      +card("Full Backup & Restore",'<p>Download all persistent LiteEdge configuration, sites, certificates, authentication, WAF rules, imported configuration, and alert settings. <strong>Logs are excluded.</strong></p>'
        +'<p class="small text-warning-emphasis">The archive includes private keys and administrator authentication data. Keep it secure. Restoring replaces the current saved configuration and may require signing in again; existing logs remain untouched.</p>'
        +rowActions([{op:"full-backup-download",label:"Download full backup"},{op:"full-backup-restore",label:"Restore from backup",danger:true}]))
      +card("Administrator password",form("password/change",'<div class="spa-form-grid">'
        +field("Current password","current_password","","password","required autocomplete=current-password")
        +field("New password","new_password","","password","minlength=10 required autocomplete=new-password")
        +field("Confirm new password","confirm_password","","password","minlength=10 required autocomplete=new-password")
        +'</div><p class="small text-secondary mt-2">Changing the password invalidates the previously cached Basic credentials. Authenticate again on your next API call.</p>',
        "Change administrator password"));
  }
  function renderAlerts(data) {
    cache.catalog=data.catalog||{hosts:[],routes:[]};
    cache.rules=data.rules||[];
    const listing=cache.rules.map(r=>'<tr><td>'+escape(r.name)+'</td><td>'+escape(r.type)
      +' / '+escape(r.action)+'</td><td>'+escape(r.threshold)+' in '+escape(r.window)+'s</td>'
      +'<td>'+escape(r.channel)+' / '+escape(r.target)+'</td><td>'
      +rowActions([{op:"edit-alert",label:"Edit",data:{id:r.id}},{op:"delete-alert",label:"Delete",danger:true,data:{id:r.id}}])
      +'</td></tr>').join("");
    root.innerHTML='<h1 class="h3 mb-3">Alerts</h1>'
      +card("Configured alert rules",'<div class="table-responsive"><table class="table table-sm">'
       +'<thead><tr><th>Name</th><th>Condition</th><th>Threshold</th><th>Delivery</th><th></th></tr></thead><tbody>'
       +(listing||'<tr><td colspan="5">No alerts configured.</td></tr>')+'</tbody></table></div>'
       +rowActions([{op:"add-alert",label:"Add alert"}]));
  }
  const defaultAlert={id:"",name:"",type:"http",action:"any",host:"",route:"",method:"",status:"",
    search:"",threshold:5,window:60,cooldown:300,channel:"email",target:"",scopes:[]};
  function editAlert(alert) {
    const a={...defaultAlert,...alert};
    const hosts=cache.catalog?.hosts||[];
    const routes=cache.catalog?.routes||[];
    const scopes=Array.isArray(a.scopes)?a.scopes:[];
    const selectedHosts=new Set(scopes.map(s=>s.host));
    const selectedRoutes=new Set(scopes.flatMap(s=>(s.routes||[]).map(v=>s.site+"|"+v)));
    const hostControls=hosts.map(h=>'<label class="spa-check"><input type="checkbox" class="form-check-input" data-alert-host data-site="'
      +escape(h.site)+'" value="'+escape(h.name)+'" '+(selectedHosts.has(h.name)?"checked":"")+'>'+escape(h.name)+' <span class="small text-secondary">('+escape(h.kind)+')</span></label>').join("");
    const routeControls=routes.map(r=>'<label class="spa-check"><input type="checkbox" class="form-check-input" data-alert-route data-site="'
      +escape(r.site)+'" value="'+escape(r.route)+'" '+(selectedRoutes.has(r.site+"|"+r.route)?"checked":"")+'>'+escape(r.site)+" "+escape(r.route)+'</label>').join("");
    modal(a.id?"Edit alert":"Add alert",form("alerts/save",'<div class="spa-form-grid">'
       +field("Rule ID","id",a.id,"text","required maxlength=48")
       +field("Name","name",a.name,"text","required")
       +select("Event type","type",[["all","Any"],["http","HTTP"],["waf","WAF"],["health","Health"]],a.type)
       +select("Action","action",[["any","Any"],["blocked","Blocked"],["matched","Matched"],["down","Backend down"],["up","Recovered"]],a.action)
       +select("HTTP method","method",[["","Any"],["GET","GET"],["POST","POST"],["PUT","PUT"],["DELETE","DELETE"],["PATCH","PATCH"]],a.method)
       +field("HTTP status / class","status",a.status)
       +field("Contains text","search",a.search)
       +field("Event count","threshold",a.threshold,"number","min=1")
       +field("Window seconds","window",a.window,"number","min=10")
       +field("Cooldown seconds","cooldown",a.cooldown,"number","min=10")
       +select("Notification type","channel",[["email","Email"],["webhook","HTTPS webhook"]],a.channel)
       +field("Notification destination","target",a.target,"text","required")
       +'</div><div class="spa-form-grid mt-3"><fieldset><legend class="fs-6">Hosts / aliases</legend>'+hostControls
       +'</fieldset><fieldset><legend class="fs-6">Routes</legend>'+routeControls+'</fieldset></div>',
       "Save alert"));
  }
  function renderOwasp(data) {
    cache.plugins=data.installed||[];
    cache.registry=data.registry||[];
    const installed=new Set(cache.plugins.map(x=>x.name));
    const catalog=cache.registry.map(p=>'<tr><td>'+escape(p.name)+'</td><td>'+escape(p.category)+'</td>'
      +'<td>'+escape(p.status)+'</td><td>'+rowActions([{op:installed.has(p.name)?"remove-plugin":"install-plugin",
       label:installed.has(p.name)?"Remove":"Install",data:{plugin:p.name},danger:installed.has(p.name)}])+'</td></tr>').join("");
    root.innerHTML='<h1 class="h3">OWASP CRS</h1>'
      +card("Core Rule Set",'<p>Installed '+escape(data.crs?.CURRENT_VERSION||"unknown")
        +' · Latest <span data-crs-latest>'+escape(data.crs?.LATEST_VERSION||"not checked")+'</span></p>'
        +'<p data-crs-check-status role="status" aria-live="polite" class="small text-secondary">Checking for CRS updates…</p>'
        +rowActions([{op:"crs-check",label:"Check updates"},{op:"crs-update",label:"Update CRS"},
          {op:"crs-reset",label:"Restore bundled CRS"}, {op:"owasp-import",label:"Import bundle"},{op:"owasp-crs-import",label:"Import CRS"},{op:"owasp-export",label:"Export OWASP"}]))
      +card("Default protection level",form("owasp/pl",
        select("Paranoia level","pl",[["1","PL1 Normal"],["2","PL2 Enhanced"],["3","PL3 High"],["4","PL4 Extreme"]],data.pl),
        "Save default"))
      +card("CRS plugin catalog",'<div class="table-responsive"><table class="table table-sm"><thead><tr>'
        +'<th>Name</th><th>Type</th><th>Status</th><th></th></tr></thead><tbody>'+catalog+'</tbody></table></div>'
        +rowActions([{op:"refresh-catalog",label:"Refresh registry"}]))
      +card("Plugin configuration",(data.plugin_configs||[]).map(c=>'<div class="border-bottom py-2 d-flex justify-content-between align-items-center"><span><code>'+escape(c.plugin)+'</code> · '+escape(c.file)+'</span>'
         +rowActions([{op:"edit-plugin-config",label:"Configure",data:{plugin:c.plugin,file:c.file}}])+'</div>').join("")||'<div class="text-secondary small">No installed plugin exposes an editable configuration file.</div>')
      +card("Core CRS rules",'<p class="text-secondary small">Browse, search, enable, and disable individual rules.</p>'
         +rowActions([{op:"manage-crs-rules",label:"Manage CRS rules"}]))
      +card("Globally disabled WAF rules",'<p>'+ (data.disabled?.map(id=>'<span class="badge text-bg-light border me-2">'
        +escape(id)+' <button type="button" class="btn btn-sm p-0" data-operation="enable-global-rule" data-id="'+escape(id)+'">×</button></span>').join("")||"None")+'</p>'
        +form("owasp/rule/disable",field("CRS rule ID","rule_id","","text","required pattern=\"[0-9]{1,9}\""),"Disable globally"))
      +card("Custom ModSecurity rules",'<div class="mb-3">'+rowActions([{op:"add-custom-rule",label:"Add custom rule"}])+'</div>'
        +(data.custom||[]).map(c=>'<div class="d-flex justify-content-between align-items-center border-bottom py-2"><span><code>'
        +escape(c.id)+'</code> '+escape(c.state)+'</span>'
        +rowActions([{op:"edit-custom-rule",label:"Edit",data:{id:c.id}},
                     {op:"toggle-custom-rule",label:c.state==="enabled"?"Disable":"Enable",data:{id:c.id,state:c.state}},
                     {op:"delete-custom-rule",label:"Delete",danger:true,data:{id:c.id}}])+'</div>').join(""));
    cache.owasp=data;
  }
  // Opening OWASP performs a check-only version query. Keep the rest of the
  // page interactive; never initiate the archive download/install here.
  async function checkCrsUpdates() {
    const sequence=++crsCheckSequence;
    const status=root.querySelector("[data-crs-check-status]");
    if(status) {
      status.textContent="Checking for CRS updates…";
      status.className="small text-secondary";
    }
    try {
      const response=await api("owasp/crs/check");
      if(sequence!==crsCheckSequence || current().view!=="owasp") return;
      const currentStatus=root.querySelector("[data-crs-check-status]");
      if(!currentStatus) return;
      const crs=response.crs||{};
      if(cache.owasp) cache.owasp.crs=crs;
      const latest=root.querySelector("[data-crs-latest]");
      if(latest) latest.textContent=crs.LATEST_VERSION||"not checked";
      const available=crs.UPDATE_AVAILABLE==="1";
      currentStatus.textContent=available
        ? "Update available: "+crs.LATEST_VERSION+" (installed: "+(crs.CURRENT_VERSION||"unknown")+")"
        : "OWASP CRS is up to date ("+(crs.CURRENT_VERSION||"unknown")+").";
      currentStatus.className="small "+(available?"text-warning-emphasis":"text-success");
      const install=root.querySelector('[data-operation="crs-update"]');
      if(install) install.disabled=!available;
    } catch(error) {
      if(sequence!==crsCheckSequence || current().view!=="owasp") return;
      const currentStatus=root.querySelector("[data-crs-check-status]");
      if(currentStatus) {
        currentStatus.textContent="CRS update check failed: "+(error.message||String(error));
        currentStatus.className="small text-danger";
      }
    }
  }
  function customRuleEditor(rule) {
    modal(rule?"Edit custom WAF rule":"New custom WAF rule",form("owasp/custom/save",
      field("Rule ID","rule_id",rule?.id||"","text","required pattern=\"[0-9]{1,9}\"")
      +textarea("ModSecurity rule text","rule_text",rule?.content||"",12),
      rule?"Save rule":"Add rule"));
  }
  function savedLogScopes(filters,catalog) {
    let scopes=[];
    try {
      const parsed=JSON.parse(filters.scopes_json||"[]");
      if(Array.isArray(parsed)) scopes=parsed;
    } catch(_) { /* Ignore stale/corrupt local filter selections. */ }
    // Older SPA releases stored a single scalar host and route.
    if(!scopes.length && filters.host) {
      const matched=(catalog.hosts||[]).find(h=>h.name===filters.host);
      if(matched) scopes=[{site:matched.site,host:matched.name,
        routes:filters.route?[filters.route]:[]}];
    }
    return scopes;
  }
  function logPicker(kind,title,entries,selectedHosts,selectedRoutes) {
    const isHost=kind==="hosts";
    const choices=entries.map(item=>{
      const identity=item.site+"|"+(isHost?item.name:item.route);
      const active=(isHost?selectedHosts:selectedRoutes).has(identity);
      const name=isHost?item.name:item.route;
      const label=isHost?(item.kind==="alias"?"Alias":"Site"):"Route";
      return '<label class="spa-log-option" data-log-option>'
        +'<input type="checkbox" class="form-check-input" data-log-'+(isHost?"host":"route")
        +' data-site="'+escape(item.site)+'" value="'+escape(name)+'" '+(active?"checked":"")+'>'
        +'<span class="text-break">'+escape(name)+'</span>'
        +'<span class="small text-secondary ms-auto">'+escape(isHost?label:item.site)+'</span></label>';
    }).join("");
    return '<div><label class="form-label">'+escape(title)+'</label>'
      +'<details class="spa-log-picker" data-log-picker="'+kind+'">'
      +'<summary class="form-select" data-log-summary>'+ (isHost?"All hosts (select to filter)":"All routes (select hosts first)")+'</summary>'
      +'<div class="spa-log-menu border rounded bg-body shadow p-2">'
      +'<input class="form-control form-control-sm mb-2" type="search" data-log-picker-search="'+kind+'"'
      +' aria-label="Search '+escape(title)+'" placeholder="Filter '+escape(kind)+'…">'
      +'<div class="spa-log-options" data-log-options="'+kind+'">'+(choices||'<div class="small text-secondary">No options available.</div>')+'</div>'
      +'<button type="button" class="btn btn-sm btn-link px-1 mt-2" data-log-clear="'+kind+'">Clear selection</button>'
      +'</div></details>'
      +'<div class="form-text">'+(isHost?"Select multiple configured hosts or aliases.":"Routes are limited to selected hosts; no routes selected means all their routes.")+'</div></div>';
  }
  function updateLogSelectors(form) {
    const hosts=[...form.querySelectorAll("[data-log-host]:checked")];
    const sites=new Set(hosts.map(input=>input.dataset.site));
    const routeInputs=[...form.querySelectorAll("[data-log-route]")];
    for(const input of routeInputs) {
      const available=sites.has(input.dataset.site);
      if(!available) input.checked=false;
      input.disabled=!available;
      const row=input.closest("[data-log-option]");
      const search=form.querySelector('[data-log-picker-search="routes"]')?.value.trim().toLowerCase()||"";
      if(row) row.hidden=!available||(search!==""&&!row.textContent.toLowerCase().includes(search));
    }
    const count=routeInputs.filter(input=>input.checked).length;
    const hostSummary=form.querySelector('[data-log-picker="hosts"] [data-log-summary]');
    const routeSummary=form.querySelector('[data-log-picker="routes"] [data-log-summary]');
    if(hostSummary) hostSummary.textContent=hosts.length?hosts.length+" hosts / aliases selected":"All hosts (select to filter)";
    if(routeSummary) routeSummary.textContent=!hosts.length?"Select hosts first":count?count+" routes selected":"All routes for selected hosts";
    const routesPicker=form.querySelector('[data-log-picker="routes"]');
    if(routesPicker) {
      if(!hosts.length) routesPicker.open=false;
      routesPicker.querySelector("summary")?.setAttribute("aria-disabled",hosts.length?"false":"true");
    }
  }
  function renderLogs(catalog) {
    cache.catalog=catalog;
    const f=cache.filters;
    const scopes=savedLogScopes(f,catalog);
    const selectedHosts=new Set(scopes.map(x=>x.site+"|"+x.host));
    const selectedRoutes=new Set(scopes.flatMap(x=>(x.routes||[]).map(route=>x.site+"|"+route)));
    root.innerHTML='<h1 class="h3 mb-3">Logs</h1>'+card("Search events",
      '<form data-log-search><div class="spa-form-grid">'
       +select("Event type","type",[["all","Any"],["http","HTTP"],["waf","WAF"],["health","Health"]],f.type||"all")
       +logPicker("hosts","Hosts and aliases",catalog.hosts||[],selectedHosts,selectedRoutes)
       +logPicker("routes","Routes",catalog.routes||[],selectedHosts,selectedRoutes)
       +field("Listener/upstream port","port",f.port||"")
       +select("HTTP method","method",[["","Any"],...["GET","POST","PUT","PATCH","DELETE","OPTIONS"].map(x=>[x,x])],f.method||"")
       +field("HTTP status / class","status",f.status||"")
       +field("Contains text","search",f.search||"")
       +field("Limit","limit",f.limit||100,"number","min=1 max=1000")
       +field("Since (Unix seconds)","since",f.since||0,"number")
       +'</div><div class="d-flex gap-2 mt-3"><button class="btn btn-primary" type="submit">Search logs</button>'
       +'<button class="btn btn-outline-secondary" type="button" data-operation="logs-csv">Export CSV</button>'
       +'<button class="btn btn-outline-secondary" type="button" data-operation="logs-jsonl">Export JSONL</button></div></form>')
       +'<div id="log-results" role="region" aria-live="polite"></div>';
    updateLogSelectors(root.querySelector("[data-log-search]"));
  }
  function renderEvents(events) {
    const container=document.getElementById("log-results");
    if(!container)return;
    container.innerHTML=card("Events ("+events.length+")",'<div class="table-responsive"><table class="table table-sm">'
      +'<thead><tr><th>Timestamp</th><th>Type</th><th>Host</th><th>Method</th><th>URI / route</th><th>Status</th><th>Details</th></tr></thead><tbody>'
      +(events.map(e=>'<tr><td>'+escape(e.timestamp||"")+'</td><td>'+escape(e.type||"")+'</td>'
        +'<td>'+escape(e.host||"")+'</td><td>'+escape(e.method||"")+'</td><td>'+escape(e.uri||e.route||"")+'</td>'
        +'<td>'+escape(e.status||"")+'</td><td>'+escape(e.message||e.rule_id||"")+'</td></tr>').join("")
       ||'<tr><td colspan="7">No matching events.</td></tr>')+'</tbody></table></div>');
  }
  function logQuery(form) {
    const values=Object.fromEntries(new FormData(form).entries());
    // The server validates each host, alias and route against its inventory.
    const hosts=[...form.querySelectorAll("[data-log-host]:checked")];
    const routes=[...form.querySelectorAll("[data-log-route]:checked")];
    values.scopes_json=JSON.stringify(hosts.map(input=>({
      host:input.value,site:input.dataset.site,
      routes:routes.filter(route=>route.dataset.site===input.dataset.site).map(route=>route.value)
    })));
    delete values.host;
    delete values.route;
    return values;
  }
  function logHasFilter(values) {
    return Object.entries(values).some(([k,v])=>
      k!=="limit"&&k!=="apply"&&k!=="format"&&
      (k==="scopes_json"?v!=="[]"&&!!v:k==="since"?Number(v)>0:v!==""&&v!=="all"&&v!=="0"));
  }
  async function searchLogs() {
    const form=document.querySelector("[data-log-search]");
    if(!form)return;
    const values=logQuery(form);
    cache.filters=values;
    if(!logHasFilter(values)){toast("Choose at least one filter before searching.","danger");return;}
    const button=form.querySelector('button[type="submit"]');
    if(button){button.disabled=true;button.textContent="Searching…";}
    try {
      const params=new URLSearchParams(values);
      const result=await api("logs?"+params.toString());
      if(current().view==="logs")renderEvents(result.events||[]);
    } finally {
      if(button){button.disabled=false;button.textContent="Search logs";}
    }
  }
  function uploadDialog(kind,host="") {
    const fileLabel=kind==="owasp-crs"?"OWASP CRS archive":kind==="owasp"?"OWASP configuration":"LiteEdge configuration";
    const path=kind==="owasp-crs"?"owasp/crs/import":kind==="owasp"?"owasp/import":"import";
    modal("Import "+fileLabel,
      '<form data-upload-path="'+escape(path)+'" data-upload-host="'+escape(host)+'">'
      +field(fileLabel,"archive","","file","required accept=\".tar.gz,.tgz,application/gzip\"")
      +(kind==="site"||kind==="sites"?check("Include certificates","certificates",false):"")
      +'<button class="btn btn-primary mt-3" type="submit">Import</button></form>');
  }
  function exportDialog() {
    modal("Export configuration",'<div class="d-flex flex-wrap gap-2">'
      +rowActions([{op:"export-all",label:"All sites (settings)"},{op:"export-all-certs",label:"All sites + certificates"}])+'</div>'
      +'<div class="mt-3">'+select("Single site","export_site",cache.sites.map(s=>[s.host,s.host]),cache.sites[0]?.host)
      +rowActions([{op:"export-selected-site",label:"Export selected site"}])+'</div>');
  }

  function formValues(form) {
    const values=Object.fromEntries(new FormData(form).entries());
    if(form.querySelector("[data-pool]")){
      const urls=[...form.querySelectorAll("[data-pool-url]")].map(x=>x.value.trim());
      if(!urls.length||urls.some(url=>!url))throw new Error("A route needs at least one valid backend URL.");
      if(urls.length>16)throw new Error("A route supports at most 16 backends.");
      values.target=urls[0];
      values.backends=urls.slice(1).join(",");
    }
    if(form.dataset.apiAction==="alerts/save"){
      const hosts=[...form.querySelectorAll("[data-alert-host]:checked")];
      const routes=[...form.querySelectorAll("[data-alert-route]:checked")];
      values.scopes_json=JSON.stringify(hosts.map(h=>({
        site:h.dataset.site,host:h.value,
        routes:routes.filter(r=>r.dataset.site===h.dataset.site).map(r=>r.value)
      })));
    }
    return values;
  }
  async function mutation(form) {
    const name=form.dataset.apiAction;
    const data=formValues(form);
    const button=form.querySelector('button[type="submit"]');
    const label=button?.textContent;
    if(button){button.disabled=true;button.textContent="Saving…";}
    try {
      const result=await act(name,data);
      if(dialog.open)dialog.close();
      toast("Saved successfully.");
      if(result.reauthenticate) {
        toast("Password changed. Your next API request will require new credentials.");
      }
      if(name==="site/save" && current().view==="sites"){
        location.hash=navUrl("site",data.host);
      } else await refresh();
    } finally {
      if(button){button.disabled=false;button.textContent=label;}
    }
  }
  async function command(op,el) {
    const host=el.dataset.host||cache.site?.host;
    const id=el.dataset.id;
    switch(op){
      case "full-backup-download":
        await transfer("backup/export","liteedge-full-backup.tar.gz");
        toast("Full backup downloaded. Store it securely; it contains private keys and authentication data.");
        break;
      case "full-backup-restore":
        modal("Restore full backup",'<p class="alert alert-warning">This will <strong>replace all current saved LiteEdge configuration</strong>, including sites, certificates, authentication, and WAF settings. Existing logs will not be changed. The restored administrator password may be different.</p>'
          +'<form data-full-backup-restore>'
          +field("Select LiteEdge full backup archive","archive","","file","required accept=\".tar.gz,.tgz,application/gzip\"")
          +field("Type RESTORE to confirm","confirmation","","text","required autocomplete=off")
          +'<button type="submit" class="btn btn-danger mt-3">Validate and restore backup</button></form>');
        break;
      case "add-site":
        modal("Add site",form("site/save",'<div class="spa-form-grid">'
          +field("Hostname","host","","text","required")
          +field("Aliases","aliases")+'</div>',"Add site"));
        break;
      case "toggle-site":
        await act(el.dataset.enabled==="1"?"site/disable":"site/enable",{host,return_to:"site"});
        toast("Site status updated.");await refresh();break;
      case "delete-site":
        if(!confirm("Delete site "+host+" and its saved configuration?"))return;
        await act("site/delete",{host});toast("Site deleted.");await refresh();break;
      case "add-route":await editRoute();break;
      case "edit-route":
        await editRoute(cache.site.routes.find(r=>r.id===id));break;
      case "delete-route":
        if(!confirm("Delete this route?"))return;
        await act("route/delete",{host,id});toast("Route deleted.");await refresh();break;
      case "pool-add": {
        const pool=el.closest("form").querySelector("[data-pool]");
        if(pool.children.length>=16){toast("Maximum 16 backends.","danger");return;}
        pool.insertAdjacentHTML("beforeend",poolRow());
        pool.lastElementChild.querySelector("input").focus();
        break;
      }
      case "pool-remove":{
        const pool=el.closest("[data-pool]");
        el.closest("[data-pool-row]").remove();
        if(!pool.children.length)pool.insertAdjacentHTML("beforeend",poolRow());
        break;
      }
      case "selfsigned":await act("cert/selfsigned",{host});toast("Certificate created.");await refresh();break;
      case "letsencrypt": {
        const email=cache.site?.cert_email||prompt("Contact email for Let’s Encrypt");
        if(!email)return;
        await act("cert/letsencrypt",{host,email});toast("Certificate updated.");await refresh();break;
      }
      case "enable-site-rule":await act("waf/enable",{host,rule_id:el.dataset.ruleId});await refresh();break;
      case "reset-config":
        if(!confirm("Discard manual changes and restore generated NGINX configuration?"))return;
        await act("config/reset",{host});await refresh();break;
      case "add-alert": editAlert();break;
      case "edit-alert": editAlert(cache.rules.find(r=>r.id===id));break;
      case "delete-alert":
        if(!confirm("Delete alert "+id+"?"))return;
        await act("alerts/delete",{id});await refresh();break;
      case "crs-check":await checkCrsUpdates();break;
      case "crs-update":
        if(!confirm("Download, validate, and activate the latest CRS?"))return;
        await act("owasp/crs/update");await refresh();break;
      case "crs-reset":await act("owasp/crs/reset");await refresh();break;
      case "install-plugin":await act("owasp/plugin/install",{plugin:el.dataset.plugin});await refresh();break;
      case "remove-plugin":
        if(!confirm("Remove plugin "+el.dataset.plugin+"?"))return;
        await act("owasp/plugin/remove",{plugin:el.dataset.plugin});await refresh();break;
      case "refresh-catalog":await act("owasp/catalog/refresh");await refresh();break;
      case "edit-plugin-config":{
        const c=(cache.owasp.plugin_configs||[]).find(x=>x.plugin===el.dataset.plugin && x.file===el.dataset.file);
        if(!c)throw new Error("Plugin configuration not found.");
        modal("Configure "+c.plugin+" / "+c.file,form("owasp/plugin/config-save",
          '<input type="hidden" name="plugin" value="'+escape(c.plugin)+'"><input type="hidden" name="file" value="'+escape(c.file)+'">'
          +textarea("Plugin configuration","config",c.content,18),"Validate and save"));
        break;
      }
      case "manage-crs-rules":{
        const data=await api("owasp/rules");
        cache.crsRules=data.rules||[];
        const disabled=new Set(cache.owasp.disabled||[]);
        modal("CRS rules",field("Search rule ID or description","rule_search","","search","data-rule-search")
          +'<div class="table-responsive" style="max-height:62vh;overflow:auto"><table class="table table-sm"><thead><tr><th>ID</th><th>Rule</th><th>PL</th><th>Status</th><th></th></tr></thead><tbody>'
          +cache.crsRules.map(rule=>'<tr data-rule-row data-search="'+escape((rule.id+" "+rule.message+" "+rule.source).toLowerCase())+'">'
          +'<td>'+escape(rule.id)+'</td><td>'+escape(rule.message)+'</td><td>'+escape(rule.pl)+'</td><td>'
          +(disabled.has(rule.id)?"Disabled":"Enabled")+'</td><td>'
          +rowActions([{op:"toggle-crs-rule",label:disabled.has(rule.id)?"Enable":"Disable",data:{id:rule.id,state:disabled.has(rule.id)?"disabled":"enabled"}}])
          +'</td></tr>').join("")+'</tbody></table></div>');
        break;
      }
      case "toggle-crs-rule":{
        await act("owasp/rule/"+(el.dataset.state==="enabled"?"disable":"enable"),{rule_id:el.dataset.id});
        dialog.close();toast("WAF rule updated.");await refresh();break;
      }
      case "enable-global-rule":await act("owasp/rule/enable",{rule_id:el.dataset.id});await refresh();break;
      case "add-custom-rule":customRuleEditor();break;
      case "edit-custom-rule":customRuleEditor(cache.owasp.custom.find(x=>x.id===id));break;
      case "toggle-custom-rule":await act("owasp/custom/"+(el.dataset.state==="enabled"?"disable":"enable"),{rule_id:id});await refresh();break;
      case "delete-custom-rule":
        if(!confirm("Delete custom rule "+id+"?"))return;
        await act("owasp/custom/delete",{rule_id:id});await refresh();break;
      case "import": uploadDialog("sites");break;
      case "import-site":uploadDialog("site",host);break;
      case "owasp-import":uploadDialog("owasp");break;
      case "owasp-crs-import":uploadDialog("owasp-crs");break;
      case "owasp-export":await transfer("owasp/export","owasp-config.tar.gz");break;
      case "export":exportDialog();break;
      case "export-site":await transfer("export?scope=site&host="+q(host)+"&certificates=0",host+"-settings.tar.gz");break;
      case "export-site-certs":await transfer("export?scope=site&host="+q(host)+"&certificates=1",host+"-with-certificates.tar.gz");break;
      case "export-selected-site":{
        const selected=dialog.querySelector('[name="export_site"]')?.value;
        if(selected)await transfer("export?scope=site&host="+q(selected)+"&certificates=0",selected+"-settings.tar.gz");
        break;
      }
      case "export-all":await transfer("export?scope=all&certificates=0","liteedge-settings.tar.gz");break;
      case "export-all-certs":await transfer("export?scope=all&certificates=1","liteedge-with-certificates.tar.gz");break;
      case "logs-csv":case "logs-jsonl":{
        const f=document.querySelector("[data-log-search]");
        if(!f)return;
        const values=logQuery(f);
        cache.filters=values;
        if(!logHasFilter(values)){toast("Choose at least one filter before exporting logs.","danger");return;}
        const fmt=op==="logs-csv"?"csv":"jsonl";
        const params=new URLSearchParams({...values,apply:"1",format:fmt});
        await transfer("logs/export?"+params,"liteedge-events."+fmt);
        break;
      }
      default:throw new Error("Unsupported UI operation "+op);
    }
  }
  document.addEventListener("change",event=>{
    if(!event.target.matches("[data-log-host], [data-log-route]"))return;
    const form=event.target.closest("[data-log-search]");
    if(!form)return;
    updateLogSelectors(form);
    cache.filters=logQuery(form);
  });
  document.addEventListener("input",event=>{
    const search=event.target.closest("[data-log-picker-search]");
    if(search){
      const form=search.closest("[data-log-search]");
      const kind=search.dataset.logPickerSearch;
      const term=search.value.trim().toLowerCase();
      for(const row of form.querySelectorAll('[data-log-options="'+kind+'"] [data-log-option]')){
        const checkbox=row.querySelector("input");
        const siteVisible=kind==="hosts"||!checkbox.disabled;
        row.hidden=!siteVisible||!row.textContent.toLowerCase().includes(term);
      }
      return;
    }
    if(!event.target.matches("[data-rule-search]"))return;
    const term=event.target.value.trim().toLowerCase();
    dialog.querySelectorAll("[data-rule-row]").forEach(row=>{row.hidden=!row.dataset.search.includes(term);});
  });
  // Native <details> elements do not dismiss each other or close on outside
  // clicks. Treat the host/route pickers as a single dropdown group.
  function closeOtherLogPickers(target) {
    const activePicker=target.closest?.("[data-log-picker]");
    for(const picker of document.querySelectorAll("[data-log-picker][open]")){
      if(picker!==activePicker) picker.open=false;
    }
  }
  document.addEventListener("click",async(event)=>{
    closeOtherLogPickers(event.target);
    const clear=event.target.closest("[data-log-clear]");
    if(clear){
      const form=clear.closest("[data-log-search]");
      for(const input of form.querySelectorAll(clear.dataset.logClear==="hosts"?"[data-log-host]":"[data-log-route]"))input.checked=false;
      updateLogSelectors(form);
      cache.filters=logQuery(form);
      return;
    }
    const routeSummary=event.target.closest('[data-log-picker="routes"] > summary');
    if(routeSummary?.getAttribute("aria-disabled")==="true"){event.preventDefault();return;}
    if(event.target.closest("[data-toast-close]")){feedback.replaceChildren();return;}
    const close=event.target.closest("[data-dismiss-dialog]");
    if(close){dialog.close();return;}
    const el=event.target.closest("[data-operation]");
    if(!el)return;
    event.preventDefault();
    try {
      await command(el.dataset.operation,el);
    } catch(err){toast(err.message||String(err),"danger");}
  });
  function closeLogPickersOnEscape(event) {
    if(event.key!=="Escape")return;
    const openPickers=[...document.querySelectorAll("[data-log-picker][open]")];
    if(!openPickers.length)return;
    // Return keyboard focus to the dropdown trigger after dismissal.
    const active=event.target.closest?.("[data-log-picker]");
    for(const picker of openPickers) picker.open=false;
    (active||openPickers[openPickers.length-1]).querySelector("summary")?.focus();
    event.preventDefault();
  }
  document.addEventListener("keydown",closeLogPickersOnEscape);
  document.addEventListener("submit",async(event)=>{
    const formEl=event.target;
    if(!formEl.matches("form"))return;
    // Every application form is handled here. No native HTML postbacks.
    event.preventDefault();
    if(formEl.matches("[data-full-backup-restore]")){
      if(formEl.querySelector('[name="confirmation"]').value !== "RESTORE") {
        toast("Type RESTORE exactly to confirm replacing the saved configuration.","danger");
        return;
      }
      const button=formEl.querySelector('button[type="submit"]');
      button.disabled=true;
      const original=button.textContent;
      button.textContent="Validating and restoring…";
      try {
        const file=formEl.querySelector('[name="archive"]').files[0];
        await upload("backup/restore",file);
        dialog.close();
        toast("Full backup restored successfully. Your credentials may have changed.");
        await refresh();
      } catch(error) {
        toast(error.message||String(error),"danger");
      } finally {
        button.disabled=false;
        button.textContent=original;
      }
      return;
    }
    if(formEl.matches("[data-log-search]")){
      try{await searchLogs();}catch(err){toast(err.message,"danger");}
      return;
    }
    if(formEl.dataset.uploadPath){
      try{
        const file=formEl.querySelector('input[type="file"]')?.files?.[0];
        const params=new URLSearchParams();
        const host=formEl.dataset.uploadHost;
        if(host){params.set("scope","site");params.set("host",host);}
        if(formEl.querySelector('[name="certificates"]:checked'))params.set("certificates","1");
        const query=params.size?"?"+params.toString():"";
        await upload(formEl.dataset.uploadPath+query,file);
        dialog.close();toast("Import completed successfully.");await refresh();
      } catch(err){toast(err.message||String(err),"danger");}
      return;
    }
    if(formEl.dataset.apiAction){
      try{await mutation(formEl);}catch(err){toast(err.message||String(err),"danger");}
    }
  });
  window.addEventListener("hashchange",refresh);
  if(!location.hash || location.hash==="#") history.replaceState(null,"","#/sites");
  refresh();
})();
