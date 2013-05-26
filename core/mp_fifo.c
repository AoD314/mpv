/*
 * This file is part of MPlayer.
 *
 * MPlayer is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * MPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with MPlayer; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#include <stdlib.h>
#include <assert.h>
#include <stdbool.h>
#include "osdep/timer.h"
#include "input/input.h"
#include "input/keycodes.h"
#include "mp_fifo.h"
#include "talloc.h"
#include "core/options.h"


struct mp_fifo {
    struct MPOpts *opts;
    struct input_ctx *input;
    int last_key_down;
    double last_down_time;
};

struct mp_fifo *mp_fifo_create(struct input_ctx *input, struct MPOpts *opts)
{
    struct mp_fifo *fifo = talloc_zero(NULL, struct mp_fifo);
    fifo->input = input;
    fifo->opts = opts;
    return fifo;
}

static void put_double(struct mp_fifo *fifo, int code)
{
  if (code >= MP_MOUSE_BTN0 && code <= MP_MOUSE_BTN2)
      mp_input_feed_key(fifo->input, code - MP_MOUSE_BTN0 + MP_MOUSE_BTN0_DBL);
}

void mplayer_put_key(struct mp_fifo *fifo, int code)
{
    double now = mp_time_sec();
    int doubleclick_time = fifo->opts->doubleclick_time;
    // ignore system-doubleclick if we generate these events ourselves
    if (doubleclick_time
        && (code & ~MP_KEY_STATE_DOWN) >= MP_MOUSE_BTN0_DBL
        && (code & ~MP_KEY_STATE_DOWN) < MP_MOUSE_BTN_DBL_END)
        return;
    mp_input_feed_key(fifo->input, code);
    if (code & MP_KEY_STATE_DOWN) {
        code &= ~MP_KEY_STATE_DOWN;
        if (fifo->last_key_down == code
            && now - fifo->last_down_time < doubleclick_time / 1000.0)
            put_double(fifo, code);
        fifo->last_key_down = code;
        fifo->last_down_time = now;
    }
}

void mplayer_put_key_utf8(struct mp_fifo *fifo, int mods, struct bstr t)
{
    while (t.len) {
        int code = bstr_decode_utf8(t, &t);
        if (code < 0)
            break;
        mplayer_put_key(fifo, code | mods);
    }
}
