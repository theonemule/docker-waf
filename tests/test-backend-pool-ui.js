const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Exercise the pool controller against a minimal DOM so this stays dependency-free.
class Element {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.attrs = {};
    this.style = {};
    this.value = "";
    this.textContent = "";
    this.disabled = false;
    this.hidden = false;
    this.parent = null;
    this.focused = false;
  }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k] ?? null; }
  matches(selector) {
    if (selector === "form") return this.tagName === "FORM";
    const x = selector.match(/^(\w+)?\[([\w-]+)(?:="([^"]*)")?\]$/);
    if (!x) return false;
    const [, tag, attr, value] = x;
    return (!tag || tag.toUpperCase() === this.tagName) &&
      this.attrs[attr] !== undefined && (value === undefined || this.attrs[attr] === value);
  }
  closest(sel) {
    let el = this;
    while (el) { if (el.matches(sel)) return el; el = el.parent; }
    return null;
  }
  querySelectorAll(sel) {
    const result = [];
    for (const child of this.children) {
      if (child.matches(sel)) result.push(child);
      result.push(...child.querySelectorAll(sel));
    }
    return result;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  append(...els) { for (const el of els) { el.parent = this; this.children.push(el); } }
  appendChild(el) { this.append(el); }
  remove() {
    if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1);
    this.parent = null;
  }
  focus() { this.focused = true; }
}
function named(tag, attr, val = "") {
  const el = new Element(tag);
  if (attr) el.setAttribute(attr, val);
  return el;
}
function formWithPool(urls) {
  const form = new Element("form");
  const pool = named("div", "data-backend-pool");
  const target = named("input", "name", "target");
  const backends = named("input", "name", "backends");
  const list = named("div", "data-backend-list");
  const add = named("button", "data-backend-add");
  const error = named("div", "data-backend-error");
  pool.append(target, backends, list, add, error);
  form.append(pool);
  function row(value) {
    const wrapper = named("div", "data-backend-row");
    const label = named("span", "data-backend-label");
    const input = named("input", "data-backend-url");
    input.value = value;
    const remove = named("button", "data-backend-remove");
    wrapper.append(label, input, remove);
    list.append(wrapper);
  }
  urls.forEach(row);
  return { form, pool, list, add, error, target, backends };
}
const handlers = {};
const source = fs.readFileSync(path.join(__dirname, "../ui/admin.js"), "utf8")
  .split("(() => {\n  function showStatus")[0];
vm.runInNewContext(source, { document: {
  createElement: (tag) => new Element(tag),
  addEventListener: (type, handler) => { (handlers[type] ||= []).push(handler); }
}}, {filename:"backend-pool.js"});
assert.equal(handlers.click.length, 1);
assert.equal(handlers.submit.length, 1);
const click = (target) => handlers.click[0]({target});
function submit(form) {
  const event = {
    target:form, prevented:false, stopped:false,
    preventDefault(){this.prevented=true;},
    stopImmediatePropagation(){this.stopped=true;}
  };
  handlers.submit[0](event);
  return event;
}
const p = formWithPool(["http://a:80","http://b:80","http://c:80"]);
assert.equal(submit(p.form).prevented,false);
assert.equal(p.target.value,"http://a:80");
assert.equal(p.backends.value,"http://b:80,http://c:80");
click(p.list.children[1].querySelector("[data-backend-remove]"));
assert.equal(p.list.children.length,2);
assert.equal(p.list.children[1].querySelector("[data-backend-url]").value,"http://c:80");
assert.equal(p.target.value,"http://a:80");
assert.equal(p.backends.value,"http://c:80");
click(p.add);
assert.equal(p.list.children.length,3);
assert.equal(p.list.children[2].querySelector("[data-backend-url]").value,"");
assert.equal(p.list.children[2].querySelector("[data-backend-label]").textContent,"Backend 3");
assert.equal(submit(p.form).prevented,true,"blank newly added URL is rejected");
p.list.children[2].querySelector("[data-backend-url]").value="http://d:80";
assert.equal(submit(p.form).prevented,false);
assert.equal(p.backends.value,"http://c:80,http://d:80");
const single = formWithPool(["https://single.example"]);
assert.equal(submit(single.form).prevented,false);
assert.equal(single.target.value,"https://single.example");
assert.equal(single.backends.value,"");
click(single.list.children[0].querySelector("[data-backend-remove]"));
assert.equal(single.list.children.length,0,"last backend can be removed");
assert.equal(submit(single.form).prevented,true,"cannot submit an empty pool");
assert.equal(single.target.value,"");
click(single.add);
assert.equal(single.list.children.length,1);
const cap = formWithPool(["http://one:80"]);
for (let i=1; i<16; i++) click(cap.add);
assert.equal(cap.list.children.length,16);
assert.equal(cap.add.disabled,true);
click(cap.add);
assert.equal(cap.list.children.length,16);
console.log("PASS backend pool add/remove, serialization, renumbering, validation, single URL, and 16 endpoint limit");
