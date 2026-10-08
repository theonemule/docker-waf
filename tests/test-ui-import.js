const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

(async () => {
  const handlers = {};
  const calls = [];
  const sandbox = {
    URLSearchParams,
    document: {
      addEventListener: (type, handler) => { handlers[type] = handler; },
      getElementById: () => null,
      createElement: () => ({ className: '', textContent: '' })
    },
    fetch: async (url) => {
      calls.push(url);
      return { ok: true, text: async () => 'Imported.' };
    },
    window: { location: { assign: () => {} } }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../ui/admin.js'), 'utf8'), sandbox);

  async function submitImport(dataset) {
    const status = {};
    const button = { disabled: false };
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
