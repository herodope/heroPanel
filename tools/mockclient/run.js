// Boots harness.lua inside fengari.
//
// It also hands the harness heroPanel's .toc as a string, because fengari's io
// library has no `open` - `loadfile` works, so Lua chunks can be read, but
// plain text cannot. The harness needs the manifest so its load order is the
// addon's load order rather than a list that goes stale whenever a file is
// added, which is a failure that surfaces as a nil somewhere unrelated.
const { lua, lauxlib, lualib, to_luastring } = require('fengari');
const fs = require('fs');
const path = require('path');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const addonDir = process.env.HP_ADDON || '../../heroPanel/';
const tocPath = path.join(addonDir, 'heroPanel.toc');

let toc;
try {
  toc = fs.readFileSync(tocPath, 'utf8');
} catch (err) {
  console.error('ERROR: cannot read ' + tocPath + ': ' + err.message);
  process.exit(1);
}

lua.lua_pushstring(L, to_luastring(toc));
lua.lua_setglobal(L, to_luastring('HP_TOC'));

const harness = process.argv[2];
if (lauxlib.luaL_dofile(L, to_luastring(harness)) !== lua.LUA_OK) {
  console.error('ERROR: ' + lua.lua_tojsstring(L, -1));
  process.exit(1);
}
process.exit(0);
