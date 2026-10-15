// Build half of the ts2dart pipeline: app_ts/*.ts --ts2dart--> app_dart/lib/*.dart;
// hand-written app_ts/*.dart are copied over as-is (main.dart -> app_dart/web/).
// A hand-written .dart next to a .ts wins and the .ts is not transpiled at all (the rule
// from angular/angular's broccoli-ts2dart.ts); no such pair is left here.
const fs = require('fs'), path = require('path');
const ts = require('typescript');
// Windows fix: ts2dart keys its conversion tables by ts.getDefaultLibFilePath(), which returns backslashes here.
const origLib = ts.getDefaultLibFilePath;
ts.getDefaultLibFilePath = o => origLib(o).replace(/\\/g, '/');
const ts2dart = require('ts2dart');

const SRC = 'app_ts';
const PKG = path.join('app_dart', 'lib');
const WEB = path.join('app_dart', 'web');

// .d.ts files are TypeScript-side declarations only and are never transpiled.
const all = fs.readdirSync(SRC).sort();
const tsFiles = all.filter(f => f.endsWith('.ts') && !f.endsWith('.d.ts')).map(f => SRC + '/' + f);
const dartFiles = all.filter(f => f.endsWith('.dart'));

// Historical guard: a hand-written .dart next to a .ts makes the .ts compile-free (no pair exists now).
const overridden = tsFiles.filter(f => dartFiles.indexOf(path.basename(f).replace(/\.ts$/, '.dart')) >= 0);
const toTranspile = tsFiles.filter(f => overridden.indexOf(f) < 0);
console.log('hand-written .dart sources      : ' + JSON.stringify(dartFiles.map(f => SRC + '/' + f)));
console.log('transpiled by ts2dart           : ' + JSON.stringify(toTranspile));
if (overridden.length > 0) {
  console.log('skipped (a hand-written .dart wins): ' + JSON.stringify(overridden));
}

fs.mkdirSync(PKG, { recursive: true });
const transpiler = new ts2dart.Transpiler({
  generateLibraryName: true, generateSourceMap: false, translateBuiltins: true,
  tsconfig: 'tsconfig.json', basePath: SRC
});
transpiler.transpile(toTranspile, PKG);

// Hand-written Dart: main.dart is the entry point (web/), the rest are library facades (lib/).
fs.mkdirSync(WEB, { recursive: true });
for (const f of dartFiles) {
  const target = f === 'main.dart' ? path.join(WEB, f) : path.join(PKG, f);
  fs.copyFileSync(path.join(SRC, f), target);
  console.log('hand-written Dart copied        : ' + SRC + '/' + f + ' -> ' + target);
}

// API shims: ts2dart emits 2016-era "angular2" imports, this app targets ngdart 8.x.
const SHIMS = [
  ['package:angular2/core.dart', 'package:ngdart/angular.dart'],
  ['package:angular2/common.dart', 'package:ngdart/angular.dart'],
  ['package:angular2/platform/browser.dart', 'package:ngdart/angular.dart'],
  ['ViewEncapsulation.None', 'ViewEncapsulation.none'],
];

// Workaround for ts2dart/lib/literal.ts:21 - it escapes only the FIRST '$' of a string (no
// /g flag) and any leftover '$' becomes Dart interpolation, so the generated file stops
// compiling. Escape what it missed (skipping '$' already preceded by a backslash); only
// generated files are touched.
function escapeTemplateDollars(text) {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    const prev = i > 0 ? text[i - 1] : '';
    const next = text[i + 1] || '';
    if (ch === '$' && prev !== '\\' && /[A-Za-z_]/.test(next)) {
      out += '\\$';
    } else {
      out += ch;
    }
  }
  return out;
}

for (const f of toTranspile.map(f => path.basename(f).replace(/\.ts$/, '.dart'))) {
  const p = path.join(PKG, f);
  if (!fs.existsSync(p)) continue;
  let text = fs.readFileSync(p, 'utf8'), before = text;
  for (const [from, to] of SHIMS) text = text.split(from).join(to);
  text = escapeTemplateDollars(text);
  if (text !== before) { fs.writeFileSync(p, text); console.log('patched                         : ' + p); }
}
console.log('frontend tree ready: ' + PKG + ' + ' + WEB);
