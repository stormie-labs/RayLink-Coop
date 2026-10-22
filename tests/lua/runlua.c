/* Anomaly Coop temp tool: run/syntax-check Lua files with the engine's LuaJIT (static lua51.lib). */
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(int argc, char** argv)
{
	int rc = 0, i, check_only = 0;
	for (i = 1; i < argc; ++i)
	{
		lua_State* L;
		if (!strcmp(argv[i], "-c")) { check_only = 1; continue; }
		L = luaL_newstate();
		luaL_openlibs(L);
		if (luaL_loadfile(L, argv[i]) != 0)
		{
			printf("SYNTAX ERROR: %s\n", lua_tostring(L, -1));
			rc = 1;
		}
		else if (check_only)
			printf("syntax ok: %s\n", argv[i]);
		else if (lua_pcall(L, 0, 0, 0) != 0)
		{
			printf("RUNTIME ERROR: %s\n", lua_tostring(L, -1));
			rc = 2;
		}
		lua_close(L);
	}
	return rc;
}
