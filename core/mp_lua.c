#include <assert.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <libavutil/avutil.h>

#include "talloc.h"

#include "mp_lua.h"
#include "mp_core.h"
#include "mp_msg.h"
#include "m_property.h"
#include "m_option.h"
#include "command.h"
#include "input/input.h"
#include "sub/sub.h"
#include "osdep/timer.h"

static const char lua_defaults[] =
// Generated from defaults.lua
#include "lua_defaults.h"
;

struct lua_ctx {
    lua_State *state;
    unsigned int start_time;
};

static struct MPContext *get_mpctx(lua_State *L)
{
    lua_getfield(L, LUA_REGISTRYINDEX, "mpctx");
    struct MPContext *ctx = lua_touserdata(L, -1);
    lua_pop(L, 1);
    assert(ctx);
    return ctx;
}

static void report_error(lua_State *L)
{
    const char *err = lua_tostring(L, -1);
    mp_msg(MSGT_CPLAYER, MSGL_WARN, "[lua] Error: %s\n",
           err ? err : "[unknown]");
    lua_pop(L, 1);
}

static void add_functions(struct MPContext *mpctx);

void mp_lua_run(struct MPContext *mpctx, const char *source)
{
    if (!mpctx->lua_ctx)
        return;
    lua_State *L = mpctx->lua_ctx->state;
    if (luaL_loadstring(L, source) || lua_pcall(L, 0, 0, 0))
        report_error(L);
    assert(lua_gettop(L) == 0);
}

void mp_lua_load_file(struct MPContext *mpctx, const char *fname)
{
    if (!mpctx->lua_ctx)
        return;
    lua_State *L = mpctx->lua_ctx->state;
    if (luaL_loadfile(L, fname) || lua_pcall(L, 0, 0, 0))
        report_error(L);
    assert(lua_gettop(L) == 0);
}

void mp_lua_init(struct MPContext *mpctx)
{
    mpctx->lua_ctx = talloc(mpctx, struct lua_ctx);
    lua_State *L = mpctx->lua_ctx->state = luaL_newstate();
    if (!L)
        goto error_out;

    // For avoiding wrap arounds and loss of precission
    mpctx->lua_ctx->start_time = GetTimerMS();

    // used by get_mpctx()
    lua_pushlightuserdata(L, mpctx); // mpctx
    lua_setfield(L, LUA_REGISTRYINDEX, "mpctx"); // -

    luaL_openlibs(L);

    lua_newtable(L); // mp
    lua_pushvalue(L, -1); // mp mp
    lua_setglobal(L, "mp"); // mp

    add_functions(mpctx); // mp

    lua_pop(L, 1); // -

    if (luaL_loadstring(L, lua_defaults) || lua_pcall(L, 0, 0, 0))
        report_error(L);

    assert(lua_gettop(L) == 0);

    if (mpctx->opts.lua_file)
        mp_lua_load_file(mpctx, mpctx->opts.lua_file);

    return;

error_out:
    if (mpctx->lua_ctx->state)
        lua_close(mpctx->lua_ctx->state);
    talloc_free(mpctx->lua_ctx);
    mpctx->lua_ctx = NULL;
}

void mp_lua_uninit(struct MPContext *mpctx)
{
    if (!mpctx->lua_ctx)
        return;
    lua_close(mpctx->lua_ctx->state);
    talloc_free(mpctx->lua_ctx);
    mpctx->lua_ctx = NULL;
}

static int run_update(lua_State *L)
{
    lua_getglobal(L, "mp_update");
    if (lua_isnil(L, -1))
        return 0;
    lua_call(L, 0, 0);
    return 0;
}

void mp_lua_update(struct MPContext *mpctx)
{
    if (!mpctx->lua_ctx)
        return;
    lua_State *L = mpctx->lua_ctx->state;
    if (lua_cpcall(L, run_update, NULL) != 0)
        report_error(L);
}

static int send_command(lua_State *L)
{
    struct MPContext *mpctx = get_mpctx(L);
    const char *s = luaL_checkstring(L, 1);

    mp_cmd_t *cmd = mp_input_parse_cmd(bstr0((char*)s), "<lua>");
    if (!cmd)
        luaL_error(L, "error parsing command");
    mp_input_queue_cmd(mpctx->input, cmd);

    return 0;
}

static int property_list(lua_State *L)
{
    const struct m_option *props = mp_get_property_list();
    lua_newtable(L);
    for (int i = 0; props[i].name; i++) {
        lua_pushinteger(L, i + 1);
        lua_pushstring(L, props[i].name);
        lua_settable(L, -3);
    }
    return 1;
}

static int property_string(lua_State *L)
{
    const struct m_option *props = mp_get_property_list();
    struct MPContext *mpctx = get_mpctx(L);
    const char *name = luaL_checkstring(L, 1);
    int type = lua_tointeger(L, lua_upvalueindex(1))
               ? M_PROPERTY_PRINT : M_PROPERTY_GET_STRING;

    char *result = NULL;
    if (m_property_do(props, name, type, &result, mpctx) >= 0 && result) {
        lua_pushstring(L, result);
        talloc_free(result);
        return 1;
    }
    if (type == M_PROPERTY_PRINT) {
        lua_pushstring(L, "");
        return 1;
    }
    return 0;
}

static int set_osd_ass(lua_State *L)
{
    struct MPContext *mpctx = get_mpctx(L);
    const char *text = luaL_checkstring(L, 1);
    if (!mpctx->osd->external || strcmp(mpctx->osd->external, text) != 0) {
        talloc_free(mpctx->osd->external);
        mpctx->osd->external = talloc_strdup(mpctx->osd, text);
        vo_osd_changed(OSDTYPE_EXTERNAL);
    }
    return 0;
}

static int get_osd_resolution(lua_State *L)
{
    struct MPContext *mpctx = get_mpctx(L);
    int w, h;
    osd_object_get_resolution(mpctx->osd, mpctx->osd->objs[OSDTYPE_EXTERNAL],
                              &w, &h);
    lua_pushnumber(L, w);
    lua_pushnumber(L, h);
    return 2;
}

static int get_mouse_pos(lua_State *L)
{
    struct MPContext *mpctx = get_mpctx(L);
    float px, py;
    mp_get_osd_mouse_pos(mpctx, &px, &py);
    osd_object_pos_to_native(mpctx->osd, mpctx->osd->objs[OSDTYPE_EXTERNAL],
                             &px, &py);
    lua_pushnumber(L, px);
    lua_pushnumber(L, py);
    return 2;
}

static int get_timer(lua_State *L)
{
    struct MPContext *mpctx = get_mpctx(L);
    lua_pushnumber(L, (GetTimerMS() - mpctx->lua_ctx->start_time) / 1000.0);
    return 1;
}

static int get_chapter_list(lua_State *L)
{
    struct MPContext *mpctx = get_mpctx(L);
    lua_newtable(L); // list
    int num = get_chapter_count(mpctx);
    for (int n = 0; n < num; n++) {
        double time = chapter_start_time(mpctx, n);
        char *name = chapter_display_name(mpctx, n);
        lua_newtable(L); // list ch
        lua_pushnumber(L, time); // list ch time
        lua_setfield(L, -2, "time"); // list ch
        lua_pushstring(L, name); // list ch name
        lua_setfield(L, -2, "name"); // list ch
        lua_pushinteger(L, n + 1); // list ch n1
        lua_insert(L, -2); // list n1 ch
        lua_settable(L, -3); // list
    }
    return 1;
}

// On stack: mp table
static void add_functions(struct MPContext *mpctx)
{
    lua_State *L = mpctx->lua_ctx->state;

    lua_pushcfunction(L, send_command);
    lua_setfield(L, -2, "send_command");

    lua_pushcfunction(L, property_list);
    lua_setfield(L, -2, "property_list");

    lua_pushinteger(L, 0);
    lua_pushcclosure(L, property_string, 1);
    lua_setfield(L, -2, "property_get");

    lua_pushinteger(L, 1);
    lua_pushcclosure(L, property_string, 1);
    lua_setfield(L, -2, "property_get_string");

    lua_pushcfunction(L, set_osd_ass);
    lua_setfield(L, -2, "set_osd_ass");

    lua_pushcfunction(L, get_osd_resolution);
    lua_setfield(L, -2, "get_osd_resolution");

    lua_pushcfunction(L, get_mouse_pos);
    lua_setfield(L, -2, "get_mouse_pos");

    lua_pushcfunction(L, get_timer);
    lua_setfield(L, -2, "get_timer");

    lua_pushcfunction(L, get_chapter_list);
    lua_setfield(L, -2, "get_chapter_list");
}
