const assert=require("node:assert/strict");
const fs=require("node:fs");
const path=require("node:path");
const root=path.resolve(__dirname,"..");
const read=file=>fs.readFileSync(path.join(root,file),"utf8");
const html=read("ui/index.html"),spa=read("ui/spa.js"),api=read("cgi/api.sh"),admin=read("cgi/admin.sh");
for(const file of ["nginx/admin.conf","nginx/admin-http.conf"]){
  const nginx=read(file);
  assert.match(nginx,/location = \/index\.html \{/,"SPA static entrypoint must be protected");
  assert.match(nginx,/auth_basic_user_file @DATA_DIR@\/auth\/\.htpasswd/);
  assert.match(nginx,/location \/ \{[\s\S]*fastcgi_pass/,"CGI still handles versioned API");
}
assert.match(html,/id="spa-root"/);
assert.match(html,/src="\/assets\/spa\.js"/);
assert.doesNotMatch(html,/<form\b/,"static shell cannot contain server-backed postback forms");
assert.doesNotMatch(html,/<script(?![^>]*src=)/,"no inline scripts for CSP");
assert.doesNotMatch(spa,/location\.reload\s*\(|location\.assign\s*\(|window\.location\.href\s*=/);
assert.doesNotMatch(spa,/['"]\/admin\//,"SPA must not call legacy HTML handlers");
assert.match(spa,/credentials:\s*["']same-origin["']/,"browser Basic auth on every fetch");
assert.match(spa,/X-LiteEdge-API/);
assert.match(spa,/addEventListener\(["']submit["']/);
assert.match(spa,/preventDefault\(\)/,"UI submits through JavaScript");
assert.match(spa,/hashchange/,"client-side router");
for(const view of ["sites","site","server","alerts","owasp","logs"]){
  assert(spa.includes('page.view==="'+view+'"'),"SPA route "+view);
}
for(const name of ["site/save","route/add","route/save","server/save","server/smtp/save","collector/save","alerts/save","owasp/pl","config/save","password/change"]){
  assert(spa.includes(name),"UI action missing "+name);
}
assert.match(spa,/data-log-host/);
assert.match(spa,/data-log-route/);
assert.match(spa,/data-log-picker-search/);
assert.match(spa,/function closeOtherLogPickers\(target\)/);
assert.match(spa,/picker!==activePicker/);
assert.match(spa,/function closeLogPickersOnEscape\(event\)/);
assert.match(spa,/scopes_json/);
assert.match(spa,/checkCrsUpdates\(\)/);
assert.match(spa,/api\("owasp\/crs\/check"\)/);
assert.doesNotMatch(spa,/act\("owasp\/crs\/check"\)/);
assert.match(api,/api_crs_check\(\)/);
assert.match(api,/crsctl\.sh check/);
assert.match(spa,/Full Backup & Restore/);
assert.match(spa,/full-backup-download/);
assert.match(spa,/full-backup-restore/);
assert.match(spa,/data-full-backup-restore/);
assert.match(api,/api\/v1\/backup\/export/);
assert.match(api,/api\/v1\/backup\/restore/);
assert.match(api,/api_authz_mutation/);
assert.match(api,/HTTP_X_LITEEDGE_API/);
assert.match(api,/HTTP_ORIGIN/);
assert.match(api,/HTTP_SEC_FETCH_SITE/);
assert.match(admin,/LITEEDGE_ALLOW_LEGACY_UI/);
assert.match(admin,/api_entry "\$path"/);
console.log("PASS SPA source contract: no postback/no reload, six views, JSON API, authenticated requests, CSRF, compatibility redirects");
