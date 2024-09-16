/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavutil/common.h>

#include "mpv_talloc.h"

#include "ao.h"
#include "ao_libmpv.h"
#include "audio/format.h"
#include "common/msg.h"
#include "internal.h"
#include "options/m_option.h"
#include "osdep/timer.h"

struct priv {
    bool init;
    struct m_channels channel_layouts;
    int samplerate;
    int format;
};

int libmpv_audio_callback(struct ao *ao, void *buffer, int len)
{
    struct priv *priv;
    priv = ao->priv;

    if (priv->init == false)
    {
        MP_ERR(ao, "libmpv audio output not initialized\n");
        return -4;
    }

    if (len % ao->sstride) {
        MP_ERR(ao, "libmpv audio callback not sample aligned.\n");
    }

    // Time this buffer will take, plus assume 1 period (1 callback invocation)
    // fixed latency.
    double delay = 2 * len / (double)ao->bps;

    // int ao_read_data(struct ao *ao, void **data, int samples, int64_t out_time_ns, bool *eof, bool pad_silence, bool blocking)
    return ao_read_data(ao, &buffer, len / ao->sstride, mp_time_ns() + 1000000LL * delay, NULL, true, true);
}

static void uninit(struct ao *ao)
{
    struct priv *priv = ao->priv;
    priv->init = false;
    return;
}

static int init(struct ao *ao)
{
    struct priv *priv = ao->priv;
    priv->init = true;

    /* Only error if user explicitly asks for planar output audio. */
    if (af_fmt_is_planar(priv->format)) {
        MP_ERR(ao, "planar format not supported\n");
    }

    if (priv->format) {
        ao->format = priv->format;
    } else {
        /* Required as planar audio causes arithmetic exceptions in pull API. */
        ao->format = af_fmt_from_planar(ao->format);
    }

    if (priv->samplerate) {
        ao->samplerate = priv->samplerate;
    }

    struct mp_chmap_sel sel = {.tmp = ao};
    if (priv->channel_layouts.num_chmaps) {
        for (int n = 0; n < priv->channel_layouts.num_chmaps; n++) {
            mp_chmap_sel_add_map(&sel, &priv->channel_layouts.chmaps[n]);
        }
    } else {
        mp_chmap_sel_add_any(&sel);
    }

    if (!ao_chmap_sel_adjust(ao, &sel, &ao->channels)){
        MP_ERR(ao, "unable to set channel map\n");
    }

    return 1;
}

static void reset(struct ao *ao)
{
    // struct priv *priv = ao->priv;
    // if (!priv->paused)
    //     SDL_PauseAudio(SDL_TRUE);
    // priv->paused = 1;
}

static void start(struct ao *ao)
{
    // struct priv *priv = ao->priv;
    // if (priv->paused)
    //     SDL_PauseAudio(SDL_FALSE);
    // priv->paused = 0;
}

#define OPT_BASE_STRUCT struct priv

const struct ao_driver audio_out_libmpv = {
    .description = "Audio callback for libmpv",
    .name      = "libmpv",
    .init      = init,
    .uninit    = uninit,
    .reset     = reset,
    .start     = start,
    .priv_size = sizeof(struct priv),
    .priv_defaults = &(const struct priv) {
        .init = false,
    },
    .options = (const struct m_option[]) {
        {"channel-layouts", OPT_CHANNELS(channel_layouts)},
        {"samplerate", OPT_INT(samplerate)},
        {"format", OPT_INT(format)},
        {0}
    },
    .options_prefix = "ao-libmpv",
};


// const struct ao_driver audio_out_sdl = {
//     .description = "SDL Audio",
//     .name      = "sdl",
//     .init      = init,
//     .uninit    = uninit,
//     .reset     = reset,
//     .start     = start,
//     .priv_size = sizeof(struct priv),
//     .priv_defaults = &(const struct priv) {
//         .buflen = 0, // use SDL default
//     },
//     .options = (const struct m_option[]) {
//         {"buflen", OPT_FLOAT(buflen)},
//         {0}
//     },
//     .options_prefix = "sdl",
// };
