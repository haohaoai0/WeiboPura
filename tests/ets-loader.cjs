const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
// Use the local DevEco SDK TypeScript compiler; override for CI/other machines.
const sdk = process.env.DEVECO_SDK_HOME || 'D:/DevEco Studio/sdk';
const ts = require(process.env.WEIBO_TEST_TYPESCRIPT || path.join(sdk,
  'default/openharmony/ets/build-tools/ets-loader/bin/ark/build-win/legacy_api8/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
function createLoader(mocks = {}, globals = {}) {
  const cache = new Map();
  function load(name, parent = root) {
    if (Object.hasOwn(mocks, name)) return mocks[name];
    if (name.startsWith('@')) throw new Error(`Missing SDK mock: ${name}`);
    const file = path.resolve(parent, name.endsWith('.ets') ? name : `${name}.ets`);
    if (cache.has(file)) return cache.get(file).exports;
    const source = fs.readFileSync(file, 'utf8');
    if (/\bstruct\s/.test(source)) throw new Error('UI DSL must be built by Hvigor, not this loader');
    const compiled = ts.transpileModule(source, { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
    }, fileName: file, reportDiagnostics: true });
    const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
    if (errors.length) throw new Error(ts.flattenDiagnosticMessageText(errors[0].messageText, '\n'));
    const module = { exports: {} }; cache.set(file, module);
    vm.runInNewContext(`(function(require,module,exports){${compiled.outputText}\n})`, {
      console, setTimeout, clearTimeout, ArrayBuffer, Uint8Array, Map, Error, ...globals
    }, { filename: file })(n => load(n, path.dirname(file)), module, module.exports);
    return module.exports;
  }
  return name => load(name);
}
// Extract only ordinary TypeScript methods from a UI file. UI builders are still
// compiled exclusively by Hvigor; this harness executes the actual async logic.
function createMethodHarness(file, names, globals = {}) {
  const source = fs.readFileSync(path.resolve(root, file), 'utf8');
  const methods = names.map(name => {
    const match = new RegExp('^  (?:private )?(?:async )?' + name + '\\(', 'm').exec(source);
    if (!match) throw new Error(`Missing method ${name}`);
    const parsed = ts.createSourceFile(file, 'class Harness {\n' + source.slice(match.index), ts.ScriptTarget.Latest, true);
    const method = parsed.statements[0].members[0];
    if (!ts.isMethodDeclaration(method) || !method.body) throw new Error(`Invalid method ${name}`);
    return method.getText(parsed);
  });
  const compiled = ts.transpileModule('class Harness {\n' + methods.join('\n') + '\n}\nmodule.exports = Harness;', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, reportDiagnostics: true
  });
  const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
  if (errors.length) throw new Error(ts.flattenDiagnosticMessageText(errors[0].messageText, '\n'));
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, { module, console, setTimeout, clearTimeout, ...globals });
  return new module.exports();
}
module.exports = { createLoader, createMethodHarness };
