const { lua, lauxlib, lualib, to_luastring } = require('fengari');
const fs = require('fs');
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const harness = process.argv[2];
if (lauxlib.luaL_dofile(L, to_luastring(harness)) !== lua.LUA_OK) {
  console.error('ERROR: ' + lua.lua_tojsstring(L, -1));
  process.exit(1);
}
process.exit(0);
