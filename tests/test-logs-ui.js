#!/usr/bin/env node
// Dependency-free browser event test of the Logs selector/submit controller.
// Exercises actual ui/admin.js, not a reimplementation.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const src = fs.readFileSync(path.join(__dirname, "../ui/admin.js"), "utf8");
const start = src.indexOf("// Logs use the same inventory-backed");
assert(start >= 0, "Logs UI controller missing");
const listeners = new Map();
function element(fields = {}) {
  const obj = {
    dataset: {}, checked: false, disabled: false, hidden: false,
    textContent: "", value: "", className: "", classList: {
      names: new Set(),
      add(name) { this.names.add(name); },
      remove(name) { this.names.delete(name); },
      contains(name) { return this.names.has(name); }
    },
    attributes: {},
    setAttribute(key, value) { this.attributes[key] = value; },
    getAttribute(key) { return this.attributes[key]; },
    removeAttribute(key) { delete this.attributes[key]; },
    addEventListener(name, cb) { (this.listeners ||= {})[name] = cb; },
    trigger(name, event = {}) { assert(this.listeners?.[name], name); this.listeners[name](event); },
    ...fields
  };
  return obj;
}
function scenario(saved, options = {}) {
  const host = element({value: "alpha.example", dataset: {site:"alpha.example"}});
  const alias = element({value: "www.alpha.example", dataset: {site:"alpha.example"}});
  const other = element({value: "beta.example", dataset: {site:"beta.example"}});
  const routes = [
    element({value:"prefix:/api", dataset:{site:"alpha.example"}}),
    element({value:"exact:/healthz", dataset:{site:"alpha.example"}}),
    element({value:"prefix:/", dataset:{site:"beta.example"}})
  ];
  for (const route of routes) {
    const wrapper = element({hidden: true});
    route.closest = (selector) => selector === "[data-log-route-item]" ? wrapper : null;
    route.wrapper = wrapper;
  }
  const type = element({name:"type",tagName:"SELECT",options:[{value:"all"},{value:"http"},{value:"waf"}],value:"all"});
  const term = element({name:"search",value:""});
  const max = element({name:"limit",value:"100"});
  const timestamp = element({name:"since",value:"0"});
  const inputs = [type,term,max,timestamp];
  const scopes = element({name:"scopes_json",value:"[]"});
  const form = element({dataset:{logInitialScopes:JSON.stringify(saved)}, 
    querySelectorAll(sel) {
      if (sel === "[data-log-host]") return [host, alias, other];
      if (sel === "[data-log-route]") return routes;
      if (sel === 'input[name], select[name]') return inputs;
      if (sel === 'input[name]:not([type="hidden"]), select[name]') return inputs;
      return [];
    },
    querySelector(sel) { return sel === 'input[name="scopes_json"]' ? scopes : null; }
  });
  const names = {
    logFilterForm:form,logHostButton:element(),logRouteButton:element(),
    logHostOptions:element(),logRouteOptions:element(),logSearchButton:element(),
    logSearchSpinner:element({hidden:true}),logSearchButtonLabel:element({textContent:"Search logs"}),
    logSearchFeedback:element({hidden:true})
  };
  let documentListeners = {};
  const context = {
    location: {search:options.query || ""},
    URLSearchParams,
    sessionStorage: {
      getItem(key) { return options.storage?.get(key) ?? null; },
      setItem(key, value) { options.storage?.set(key, value); }
    },
    document: {
      getElementById(name) { return names[name] || null; },
      addEventListener(name, fn) { documentListeners[name] = fn; }
    },
    window: {addEventListener(name, fn) {listeners.set(name, fn);}},
    JSON, Array, Set, String, Number
  };
  vm.runInNewContext(src.slice(start),context, {filename:"admin.js"});
  return {form,host,alias,other,routes,type,term,max,timestamp,scopes,names,documentListeners};
}
let t=scenario([]);
assert.equal(t.names.logRouteButton.disabled,true, "route selector initially disabled");
assert.equal(t.scopes.value,"[]");
let prevented=false;
t.form.trigger("submit",{preventDefault(){prevented=true;}});
assert.equal(prevented,true, "blank query prevented");
assert.match(t.names.logSearchFeedback.textContent,/Choose at least one filter/);
assert.equal(t.names.logSearchButton.disabled,false,"invalid form does not lock button");
t.type.value="http";
prevented=false;
t.form.trigger("submit",{preventDefault(){prevented=true;}});
assert.equal(prevented,false, "event-type filter permits submission");
assert.equal(t.names.logSearchButton.disabled,true);
assert.equal(t.form.attributes["aria-busy"],"true");
assert.equal(t.names.logSearchSpinner.hidden,false);
assert.equal(t.names.logSearchSpinner.classList.contains("d-none"),false);
assert.match(t.names.logSearchFeedback.textContent,/Searching/);
assert.equal(t.names.logSearchButtonLabel.textContent,"Searching…");
listeners.get("pageshow")();
assert.equal(t.names.logSearchButton.disabled,false, "back navigation resets button");
assert.equal(t.names.logSearchSpinner.hidden,true, "back navigation hides spinner");
assert.equal(t.names.logSearchSpinner.classList.contains("d-none"),true);
assert.equal(t.form.attributes["aria-busy"],undefined);
t.type.value="all";
t.alias.checked=true;
t.alias.trigger("change");
assert.equal(t.names.logRouteButton.disabled,false);
assert.equal(t.routes[0].wrapper.hidden,false);
assert.equal(t.routes[2].wrapper.hidden,true);
t.routes[0].checked=true;
t.routes[0].trigger("change");
assert.deepEqual(JSON.parse(t.scopes.value),[{
  host:"www.alpha.example",site:"alpha.example",routes:["prefix:/api"]
}]);
t.alias.checked=false;
t.alias.trigger("change");
assert.equal(t.routes[0].checked,false,"obsolete scoped route cleared");
t= scenario([{host:"alpha.example",site:"alpha.example",routes:["exact:/healthz"]}]);
assert.equal(t.host.checked,true,"reloaded filter restores host");
assert.equal(t.routes[1].checked,true,"reloaded filter restores route");
assert.equal(t.names.logRouteButton.disabled,false);
// Verify the form restores all settings after returning without a search URL.
const storage = new Map();
t = scenario([], {storage});
assert.equal(t.term.value, "", "search field starts empty");
t.term.value = "192.0.2.100";
t.max.value = "250";
t.type.value = "waf";
t.alias.checked = true;
t.alias.trigger("change");
t.routes[1].checked = true;
t.routes[1].trigger("change");
t.form.trigger("change");
t = scenario([], {storage});
assert.equal(t.term.value, "192.0.2.100", "search term restored after navigating away");
assert.equal(t.max.value, "250", "max results restored");
assert.equal(t.type.value, "waf", "event type restored");
assert.equal(t.alias.checked, true, "alias restored");
assert.equal(t.routes[1].checked, true, "route restored");
// Explicit GET query parameters win over previous tab settings.
t = scenario([{host:"beta.example",site:"beta.example",routes:["prefix:/"]}], {storage,query:"?apply=1&type=http"});
assert.equal(t.term.value, "", "old search must not override submitted search");
assert.equal(t.other.checked, true, "URL scopes win over session state");
assert.equal(t.alias.checked, false, "saved alias does not override URL scopes");
assert.equal(t.type.value, "all", "stored type does not override server-provided form on submitted search");
console.log("PASS Logs browser events: blank-filter prevention, loading state, BFCache restoration, host/route selection and persisted filters");
