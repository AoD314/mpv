-- osc.lua

local assdraw = require 'mp.assdraw'

--
-- Parameters
--

local osc_param = {
    -- user-safe
    scaleWindow = 1,                        -- scaling of the controller when windowed
    scaleFS = 1,                            -- scaling of the controller when fullscreen
    vidscale = true,                        -- scale the controller with the video?
    valign = 0.8,                           -- vertical alignment, -1 (top) to 1 (bottom)
    halign = 0,                             -- horizontal alignment, -1 (left) to 1 (right)
    deadzonedist = 0.15,                    -- distance between OSC and deadzone
    iAmAProgrammer = false,                 -- start counting stuff at 0 and disable OSC internal playlist management (and some functions that depend on it)

    -- not user-safe
    osc_w = 550,                            -- width, height, corner-radius, padding of the OSC box
    osc_h = 138,
    osc_r = 10,
    osc_p = 15,

    -- calculated by osc_init()
    playresy = 0,                           -- canvas size Y
    playresx = 0,                           -- canvas size X
    posX, posY = 0,0,                       -- position of the controler
    pos_offsetX, pos_offsetY = 0,0,         -- vertical/horizontal position offset for contents aligned at the borders of the box
}

local osc_styles = {
    bigButtons = "{\\bord0\\1c&HFFFFFF\\1a&H00&\\3c&HFFFFFF\\3a&HFF&\\fs50\\fnmpv-osd-symbols}",
    smallButtonsL = "{\\bord0\\1c&HFFFFFF\\1a&H00&\\3c&HFFFFFF\\3a&HFF&\\fs20\\fnmpv-osd-symbols}",
    smallButtonsLlabel = "{\\fs17\\fn" .. mp.property_get("options/osd-font") .. "}",
    smallButtonsR = "{\\bord0\\1c&HFFFFFF\\1a&H00&\\3c&HFFFFFF\\3a&HFF&\\fs30\\fnmpv-osd-symbols}",

    elementDown = "{\\1c&H999999}",
    elementDisab = "{\\1a&H88&}",
    timecodes = "{\\bord0\\1c&HFFFFFF\\1a&H00&\\3c&HFFFFFF\\3a&HFF&\\fs20}",
    vidtitle = "{\\bord0\\1c&HFFFFFF\\1a&H00&\\3c&HFFFFFF\\3a&HFF&\\fs12}",
    box = "{\\bord1\\1c&H000000\\1a&H50&\\3c&HFFFFFF\\3a&H50&}",
}

-- internal states, do not touch
local state = {
    osc_visible = false,
    mouse_down_counter = 0,                 -- used for softrepeat
    active_element = nil,                   -- nil = none, 0 = background, 1+ = see elements[]
    active_event_source = nil,              -- the "button" that issued the current event
    rightTC_trem = true,                    -- if the left timcode should display total or remaining time
    tc_ms = false,                          -- Should the timecodes display their time with milliseconds
    mp_screen_sizeX, mp_screen_sizeY,       -- last screen-resolution, to detect resolution changes to issue reINITs
    initREQ = false,                        -- is a re-init request pending?
    last_seek,                              -- last seek position, to avoid deadlocks by repeatedly seeking to the same position
    message_text,
    message_timeout,
}

--
-- Helperfunctions
--

function scale_value(x0, x1, y0, y1, val)
    local m = (y1 - y0) / (x1 - x0)
    local b = y0 - (m * x0)
    return (m * val) + b
end

-- returns hitbox spanning coordinates (top left, bottom right corner) according to alignment
function get_hitbox_coords(x, y, an, w, h)

    local alignments = {
      [1] = function () return x, y-h, x+w, y end,
      [2] = function () return x-(w/2), y-h, x+(w/2), y end,
      [3] = function () return x-w, y-h, x, y end,

      [4] = function () return x, y-(h/2), x+w, y+(h/2) end,
      [5] = function () return x-(w/2), y-(h/2), x+(w/2), y+(h/2) end,
      [6] = function () return x-w, y-(h/2), x, y+(h/2) end,

      [7] = function () return x, y, x+w, y+h end,
      [8] = function () return x-(w/2), y, x+(w/2), y+h end,
      [9] = function () return x-w, y, x, y+h end,
    }

    return alignments[an]()
end

function get_element_hitbox(element)
    return element.hitbox.x1, element.hitbox.y1, element.hitbox.x2, element.hitbox.y2
end

function mouse_hit(element)
    local mX, mY = mp.get_mouse_pos()
    local bX1, bY1, bX2, bY2 = get_element_hitbox(element)

    return (mX >= bX1 and mX <= bX2 and mY >= bY1 and mY <= bY2)
end

function limit_range(min, max, val)
    if val > max then
        val = max
    elseif val < min then
        val = min
    end
    return val
end

function get_slider_value(element)
    local fill_offsetV = element.metainfo.slider.border + element.metainfo.slider.gap
    local paddingH = (element.h - (2*fill_offsetV)) / 2

    local b_x1, b_x2 = element.hitbox.x1 + paddingH, element.hitbox.x2 - paddingH
    local s_min, s_max = element.metainfo.slider.min, element.metainfo.slider.max

    local pos = scale_value(b_x1, b_x2, s_min, s_max, mp.get_mouse_pos())

    return limit_range(s_min, s_max, pos)
end

function countone(val)
    if not (osc_param.iAmAProgrammer) then
        val = val + 1
    end
    return val
end

-- align:  -1 .. +1
-- frame:  size of the containing area
-- obj:    size of the object that should be positioned inside the area
-- margin: min. distance from object to frame (as long as -1 <= align <= +1)
function get_align(align, frame, obj, margin)
    return (frame / 2) + (((frame / 2) - margin - (obj / 2)) * align)
end

--
-- Tracklist Management
--

local nicetypes = {video = "Video", audio = "Audio", sub = "Subtitle"}

-- updates the OSC internal playlists, should be run each time the track-layout changes
function update_tracklist()
    local tracktable = mp.get_track_list()

    -- by osc_id
    tracks_osc = {}
    tracks_osc.video, tracks_osc.audio, tracks_osc.sub = {}, {}, {}
    -- by mpv_id
    tracks_mpv = {}
    tracks_mpv.video, tracks_mpv.audio, tracks_mpv.sub = {}, {}, {}
    for n = 1, #tracktable do
        if not (tracktable[n].type == "unkown") then
            local type = tracktable[n].type
            local mpv_id = tonumber(tracktable[n].id)

            -- by osc_id
            table.insert(tracks_osc[type], tracktable[n])

            -- by mpv_id
            tracks_mpv[type][mpv_id] = tracktable[n]
            tracks_mpv[type][mpv_id].osc_id = #tracks_osc[type]
        end
    end
end

-- return a nice list of tracks of the given type (video, audio, sub)
function get_tracklist(type)
    local msg = "Available " .. nicetypes[type] .. " Tracks: "
    local select_scale = 100
    if #tracks_osc[type] == 0 then
        msg = msg .. "none"
    else
        for n = 1, #tracks_osc[type] do
            local track = tracks_osc[type][n]
            local lang, title, selected = "unkown", "", "{\\fscx" .. select_scale .. "\\fscy" .. select_scale .. "}○{\\fscx100\\fscy100}"
            if not(track.language == nil) then lang = track.language end
            if not(track.title == nil) then title = track.title end
            if (track.id == tonumber(mp.property_get(type))) then
                selected = "{\\fscx" .. select_scale .. "\\fscy" .. select_scale .. "}●{\\fscx100\\fscy100}"
            end
            msg = msg .. "\n" .. selected .. " " .. n .. ": [" .. lang .. "] " .. title
        end
    end
    return msg
end

-- relatively change the track of given <type> by <next> tracks (+1 -> next, -1 -> previous)
function set_track(type, next)
    local current_track_mpv, current_track_osc
    if (mp.property_get(type) == "no") then
        current_track_osc = 0
    else
        current_track_mpv = tonumber(mp.property_get(type))
        current_track_osc = tracks_mpv[type][current_track_mpv].osc_id
    end
    local new_track_osc = (current_track_osc + next) % (#tracks_osc[type] + 1)
    local new_track_mpv
    if new_track_osc == 0 then
        new_track_mpv = "no"
    else
        new_track_mpv = tracks_osc[type][new_track_osc].id
    end

    mp.send_command("no-osd set " .. type .. " " .. new_track_mpv)

        if (new_track_osc == 0) then
        show_message(nicetypes[type] .. " Track: none")
    else
        show_message(nicetypes[type]  .. " Track: " .. new_track_osc .. "/" .. #tracks_osc[type]
            .. " [" .. (tracks_osc[type][new_track_osc].language or "unkown") .. "] " .. (tracks_osc[type][new_track_osc].title or ""))
    end
end

-- get the currently selected track of <type>, OSC-style counted
function get_track(type)
    local current_track_mpv, current_track_osc
    if (mp.property_get(type) == "no") then
        return 0
    else
        return tracks_mpv[type][tonumber(mp.property_get(type))].osc_id
    end
end


--
-- Element Management
--

-- do not use this function, use the wrappers below
function register_element(type, x, y, an, w, h, style, content, eventresponder, metainfo2)
    -- type             button, slider or box
    -- x, y             position
    -- an               alignment (see ASS standard)
    -- w, h             size of hitbox
    -- style            main style
    -- content          what the element should display, can be a string or a function(ass)
    -- eventresponder   A table containing functions mapped to events that shall be run on those events
    -- metainfo         A table containing additional parameters for the element

    -- set default metainfo
    local metainfo = {}
    if not (metainfo2 == nil) then metainfo = metainfo2 end
    if metainfo.visible == nil then metainfo.visible = true end         -- element visible at all?
    if metainfo.enabled == nil then metainfo.enabled = true end         -- element clickable?
    if metainfo.styledown == nil then metainfo.styledown = true end     -- should the element be styled with the elementDown style when clicked?
    if metainfo.softrepeat == nil then metainfo.softrepeat = false end  -- should the *_down event be executed with "hold for repeat" behaviour?

    if metainfo.visible then
        local ass = assdraw.ass_new()

        ass:append("{}") -- shitty hack to troll the new_event function into inserting a \n
        ass:new_event()
        ass:pos(x, y) -- positioning
        ass:an(an)
        ass:append(style) -- styling

        -- if the element is supposed to be disabled, style it accordingly and kill the eventresponders
        if metainfo.enabled == false then
            ass:append(osc_styles.elementDisab)
            eventresponder = nil
        end

        -- Calculate the hitbox
        local bX1, bY1, bX2, bY2 = get_hitbox_coords(x, y, an, w, h)
        local hitbox
        if type == "slider" then
            -- if it's a slider, cut the border and gap off, as those aren't of interest for eventhandling
            local fill_offset = metainfo.slider.border + metainfo.slider.gap
            hitbox = {x1 = bX1 + fill_offset, y1 = bY1 + fill_offset, x2 = bX2 - fill_offset, y2 = bY2 - fill_offset}
        else
            hitbox = {x1 = bX1, y1 = bY1, x2 = bX2, y2 = bY2}
        end

        local element = {
            type = type,
            elem_ass = ass,
            hitbox = hitbox,
            w = w,
            h = h,
            content = content,
            eventresponder = eventresponder,
            metainfo = metainfo,
        }

        table.insert(elements, element)
    end
end

function register_button(x, y, an, w, h, style, content, eventresponder, metainfo)
    register_element("button", x, y, an, w, h, style, content, eventresponder, metainfo)
end

function register_box(x, y, an, w, h, r, style, metainfo2)
    local ass = assdraw.ass_new()
    ass:draw_start()
    ass:round_rect_cw(0, 0, w, h, r)
    ass:draw_stop()

    local metainfo = {}
        if not (metainfo2 == nil) then metainfo = metainfo2 end

    metainfo.styledown = false

    register_element("box", x, y, an, w, h, style, ass, nil, metainfo)
end

function register_slider(x, y, an, w, h, style, min, max, markerF, posF, eventresponder, metainfo2)
    local metainfo = {}
    if not (metainfo2 == nil) then metainfo = metainfo2 end
    local slider1 = {}
    if (metainfo.slider == nil) then metainfo.slider = slider1 end

    -- defaults
    if min == nil then metainfo.slider.min = 0 else metainfo.slider.min = min end
    if max == nil then metainfo.slider.max = 100 else metainfo.slider.max = max end
    if metainfo.slider.border == nil then metainfo.slider.border = 1 end
    if metainfo.slider.gap == nil then metainfo.slider.gap = 2 end
    if metainfo.slider.type == nil then metainfo.slider.type = "slider" end

    metainfo.slider.markerF = markerF
    metainfo.slider.posF = posF

    -- prepare the box with markers
    local ass = assdraw.ass_new()
    local border, gap = metainfo.slider.border, metainfo.slider.gap
    local fill_offsetV = border + gap       -- Vertical offset between element outline and drag-area
    local fill_offsetH = h / 2              -- Horizontal offset between element outline and drag-area

    ass:draw_start()

    -- the box
    ass:rect_cw(0, 0, w, h);

    -- the "hole"
    ass:rect_ccw(border, border, w - border, h - border)

    -- marker nibbles
    if not (markerF == nil) and gap > 0 then
        local markers = markerF()
        for n = 1, #markers do
            if (markers[n] > min) and (markers[n] < max) then

                local coordL, coordR = fill_offsetH, (w - fill_offsetH)

                local s = scale_value(min, max, coordL, coordR, markers[n])

                if gap > 1 then
                    -- draw triangles
                    local a = gap / 0.5 --0.866
                    --top
                    ass:move_to(s - (a/2), border)
                    ass:line_to(s + (a/2), border)
                    ass:line_to(s, border + gap)

                    --bottom
                    ass:move_to(s - (a/2), h - border)
                    ass:line_to(s, h - border - gap)
                    ass:line_to(s + (a/2), h - border)

                else
                    -- draw 1px nibbles
                    ass:rect_cw(s - 0.5, border, s + 0.5, border*2);
                    ass:rect_cw(s - 0.5, h - border*2, s + 0.5, h - border);
                end

            end
        end
    end

    register_element("slider", x, y, an, w, h, style, ass, eventresponder, metainfo)
end

--
-- Element Rendering
--

function render_elements(master_ass)

    for n = 1, #elements do

        local element = elements[n]
        local elem_ass1 = element.elem_ass
        local elem_ass = assdraw.ass_new()
        elem_ass:merge(elem_ass1)

        if state.active_element == n then

            -- run render event functions
            if not (element.eventresponder.render == nil) then
                element.eventresponder.render(element)
            end

            if mouse_hit(element) then
                -- mouse down styling
                if element.metainfo.styledown then
                    elem_ass:append(osc_styles.elementDown)
                end

                if (element.metainfo.softrepeat == true) and (state.mouse_down_counter >= 15 and state.mouse_down_counter % 5 == 0) then
                    element.eventresponder[state.active_event_source .. "_down"](element)
                end
                state.mouse_down_counter = state.mouse_down_counter + 1
            end

        end

        if element.type == "slider" then

            elem_ass:merge(element.content) -- ASS objects
            -- draw pos marker

            local pos = element.metainfo.slider.posF()

            if not (pos == nil) then

                if pos > element.metainfo.slider.max then
                    pos = element.metainfo.slider.max
                elseif pos < element.metainfo.slider.min then
                     pos = element.metainfo.slider.min
                end

                local fill_offsetV = element.metainfo.slider.border + element.metainfo.slider.gap
                local fill_offsetH = element.h/2

                local coordL, coordR = fill_offsetH, (element.w - fill_offsetH)

                local xp = scale_value(element.metainfo.slider.min, element.metainfo.slider.max, coordL, coordR, pos)

                -- the filling, draw it only if positive
                local innerH = element.h - (2*fill_offsetV)

                if element.metainfo.slider.type == "bar" then
                    elem_ass:rect_cw(fill_offsetV, fill_offsetV, xp, element.h - fill_offsetV)
                    --elem_ass:round_rect_cw(xp-(innerH/2), fill_offsetV, xp+(innerH/2), element.h - fill_offsetV, innerH*1.25)
                else
                    elem_ass:move_to(xp, fill_offsetV)
                    elem_ass:line_to(xp+(innerH/2), (innerH/2)+fill_offsetV)
                    elem_ass:line_to(xp, (innerH)+fill_offsetV)
                    elem_ass:line_to(xp-(innerH/2), (innerH/2)+fill_offsetV)
                end
            end

            elem_ass:draw_stop()

        elseif element.type == "box" then
            elem_ass:merge(element.content) -- ASS objects
        elseif type(element.content) == "function" then
            element.content(elem_ass) -- function objects
        else
            elem_ass:append(element.content) -- text objects
        end

        master_ass:merge(elem_ass)
    end
end

--
-- Message display
--

function show_message(text, duration)

    if duration == nil then
        duration = tonumber(mp.property_get("options/osd-duration")) / 1000
    end

    -- cut the text short, otherwise the following functions may slow down massively on huge input
    text = string.sub(text, 0, 4000)

    -- replace actual linebreaks with ASS linebreaks and get the amount of lines along the way
    local lines
    text, lines = string.gsub(text, "\n", "\\N")

    -- append a Zero-Width-Space to . and _ to enable linebreaking of long filenames
    text = string.gsub(text, "%.", ".\226\128\139")
    text = string.gsub(text, "_", "_\226\128\139")

    -- scale the fontsize for longer multi-line output
    local fontsize, outline = tonumber(mp.property_get("options/osd-font-size")), tonumber(mp.property_get("options/osd-border-size"))
    if lines > 12 then
        fontsize, outline = fontsize / 2, outline / 1.5
    elseif lines > 8 then
        fontsize, outline = fontsize / 1.5, outline / 1.25
    end

    local style = "{\\bord" .. outline .. "\\fs" .. fontsize .. "}"

    state.message_text = style .. text
    state.message_timeout = mp.get_timer() + duration
end

function render_message(ass)
    if not(state.message_timeout == nil) and not(state.message_text == nil) and state.message_timeout > mp.get_timer() then
        ass:new_event()
        ass:append(state.message_text)
    else
        state.message_text = nil
        state.message_timeout = nil
    end
end

--
-- Initialisation and Layout
--

-- OSC INIT
function osc_init()
    --print("\nINIT\n")
    -- kill old Elements
    elements = {}

    -- set canvas resolution acording to display aspect and scaleing setting
    local baseResY = 720
    local display_w, display_h, display_aspect = mp.get_screen_size()
    local scale = 1

    if (mp.property_get("fullscreen") == "yes") then
        scale = osc_param.scaleFS
    else
        scale = osc_param.scaleWindow
    end


    if osc_param.vidscale == true then
        osc_param.playresy = baseResY / scale
    else
        osc_param.playresy = display_h / scale
    end
    osc_param.playresx = osc_param.playresy * display_aspect

    -- position of the controller according to video aspect and valignment
    osc_param.posX = math.floor(get_align(osc_param.halign, osc_param.playresx, osc_param.osc_w, 0))
    osc_param.posY = math.floor(get_align(osc_param.valign, osc_param.playresy, osc_param.osc_h, 0))

    -- Some calculations on stuff we'll need
    -- vertical/horizontal position offset for contents aligned at the borders of the box
    osc_param.pos_offsetX, osc_param.pos_offsetY = (osc_param.osc_w - (2*osc_param.osc_p)) / 2, (osc_param.osc_h - (2*osc_param.osc_p)) / 2

    -- fetch values
    local osc_w, osc_h, osc_r, osc_p = osc_param.osc_w, osc_param.osc_h, osc_param.osc_r, osc_param.osc_p
    local pos_offsetX, pos_offsetY = osc_param.pos_offsetX, osc_param.pos_offsetY
    local posX, posY = osc_param.posX, osc_param.posY

    --
    -- Backround box
    --

    register_box(posX, posY, 5, osc_w, osc_h, osc_r, osc_styles.box, nil)

    --
    -- Title row
    --

    local titlerowY = posY - pos_offsetY - 10

    -- title
    local contentF = function (ass)
        local title = mp.property_get_string("media-title")
        if not (title == nil) then

            if #title > 80 then
                title = string.format("{\\fscx%f}", (80 / #title) * 100) .. title
            end

            ass:append(title)
        else
            ass:append("mpv")
        end
    end

    local eventresponder = {}
    eventresponder.mouse_btn0_up = function ()

        local title = mp.property_get("media-title")
        local pl_count = tonumber(mp.property_get("playlist-count"))

        if pl_count > 1 then
            local playlist_pos = countone(tonumber(mp.property_get("playlist-pos")))
            title = "[" .. playlist_pos .. "/" .. pl_count .. "] " .. title
        end

        show_message(title)
    end
    eventresponder.mouse_btn2_up = function () show_message(mp.property_get("filename")) end

    register_button(posX, titlerowY, 8, 496, 12, osc_styles.vidtitle, contentF, eventresponder, nil)

    -- If we have more than one playlist entry, render playlist navigation buttons
    local metainfo = {}
    metainfo.visible = (tonumber(mp.property_get("playlist-count")) > 1)

    -- playlist prev
    local eventresponder = {}
    eventresponder.mouse_btn0_up = function () mp.send_command("playlist_prev weak") end
    eventresponder["shift+mouse_btn0_up"] = function () show_message(mp.property_get("playlist"), 3) end
    register_button(posX - pos_offsetX, titlerowY, 7, 12, 12, osc_styles.vidtitle, "◀", eventresponder, metainfo)

    -- playlist next
    local eventresponder = {}
    eventresponder.mouse_btn0_up = function () mp.send_command("playlist_next weak") end
    eventresponder["shift+mouse_btn0_up"] = function () show_message(mp.property_get("playlist"), 3) end
    register_button(posX + pos_offsetX, titlerowY, 9, 12, 12, osc_styles.vidtitle, "▶", eventresponder, metainfo)

    --
    -- Big buttons
    --

    local bigbuttonrowY = posY - pos_offsetY + 35
    local bigbuttondistance = 60

    --play/pause
    local contentF = function (ass)
        if mp.property_get("pause") == "yes" then
            ass:append("\238\132\129")
        else
            ass:append("\238\128\130")
        end
    end
    local eventresponder = {}
    eventresponder.mouse_btn0_up = function () mp.send_command("no-osd cycle pause") end
    register_button(posX, bigbuttonrowY, 5, 40, 40, osc_styles.bigButtons, contentF, eventresponder, nil)

    --skipback
    local metainfo = {}
    metainfo.softrepeat = true

    local eventresponder = {}
    eventresponder.mouse_btn0_down = function () mp.send_command("no-osd seek -5 relative keyframes") end
    eventresponder["shift+mouse_btn0_down"] = function () mp.send_command("no-osd frame_back_step") end
    eventresponder.mouse_btn2_down = function () mp.send_command("no-osd seek -30 relative keyframes") end
    register_button(posX - bigbuttondistance, bigbuttonrowY, 5, 40, 40, osc_styles.bigButtons, "\238\128\132", eventresponder, metainfo)

    --skipfrwd
    local eventresponder = {}
    eventresponder.mouse_btn0_down = function () mp.send_command("no-osd seek 10 relative keyframes") end
    eventresponder["shift+mouse_btn0_down"] = function () mp.send_command("no-osd frame_step") end
    eventresponder.mouse_btn2_down = function () mp.send_command("no-osd seek 60 relative keyframes") end
    register_button(posX + bigbuttondistance, bigbuttonrowY, 5, 40, 40, osc_styles.bigButtons, "\238\128\133", eventresponder, metainfo)

    --chapters
    -- do we have any?
    local metainfo = {}
    metainfo.enabled = ((#mp.get_chapter_list()) > 0)

    --prev
    local eventresponder = {}
    eventresponder.mouse_btn0_up = function ()
        local chaplist = mp.get_chapter_list()
        local chapter = tonumber(mp.property_get("chapter")) + 1
        if (tonumber(chaplist[chapter].time) + 3) < tonumber(mp.property_get("time-pos")) then
            mp.send_command("osd-msg set chapter ${=chapter}")
        else
            mp.send_command("osd-msg add chapter -1")
        end

    end
    eventresponder["shift+mouse_btn0_up"] = function () show_message(mp.property_get("chapter-list"), 3) end
    register_button(posX - (bigbuttondistance * 2), bigbuttonrowY, 5, 40, 40, osc_styles.bigButtons, "\238\132\132", eventresponder, metainfo)

    --next
    local eventresponder = {}
    eventresponder.mouse_btn0_up = function () mp.send_command("osd-msg add chapter 1") end
    eventresponder["shift+mouse_btn0_up"] = function () show_message(mp.property_get("chapter-list"), 3) end
    register_button(posX + (bigbuttondistance * 2), bigbuttonrowY, 5, 40, 40, osc_styles.bigButtons, "\238\132\133", eventresponder, metainfo)


    --
    -- Smaller buttons
    --

    if not (osc_param.iAmAProgrammer) then
        update_tracklist()
    end

    --cycle audio tracks

    local metainfo = {}
    local eventresponder = {}
    local contentF

    if not (osc_param.iAmAProgrammer) then
        metainfo.enabled = (#tracks_osc.audio > 0)

        contentF = function (ass)
            local aid = "–"
            if not (get_track("audio") == 0) then
                aid = get_track("audio")
            end
            ass:append("\238\132\134 " .. osc_styles.smallButtonsLlabel .. aid .. "/" .. #tracks_osc.audio)
        end

        eventresponder.mouse_btn0_up = function () set_track("audio", 1) end
        eventresponder.mouse_btn2_up = function () set_track("audio", -1) end
        eventresponder["shift+mouse_btn0_down"] = function ()
            show_message(get_tracklist("audio"), 2)
        end
    else
        metainfo.enabled = true
        contentF = function (ass)
            local aid = mp.property_get("audio")

            ass:append("\238\132\134 " .. osc_styles.smallButtonsLlabel .. aid)
        end

        eventresponder.mouse_btn0_up = function () mp.send_command("osd-msg add audio 1") end
        eventresponder.mouse_btn2_up = function () mp.send_command("osd-msg add audio -1")  end
    end

    register_button(posX - pos_offsetX, bigbuttonrowY, 1, 70, 18, osc_styles.smallButtonsL, contentF, eventresponder, metainfo)


    --cycle sub tracks

    local metainfo = {}
    local eventresponder = {}
    local contentF

    if not (osc_param.iAmAProgrammer) then
        metainfo.enabled = (#tracks_osc.sub > 0)

        contentF = function (ass)
            local sid = "–"
            if not (get_track("sub") == 0) then
                sid = get_track("sub")
            end
            ass:append("\238\132\135 " .. osc_styles.smallButtonsLlabel .. sid .. "/" .. #tracks_osc.sub)
        end

        eventresponder.mouse_btn0_up = function () set_track("sub", 1) end
        eventresponder.mouse_btn2_up = function () set_track("sub", -1) end
        eventresponder["shift+mouse_btn0_down"] = function ()
            show_message(get_tracklist("sub"), 2)
        end
    else
        metainfo.enabled = true
        contentF = function (ass)
            local sid = mp.property_get("sub")

            ass:append("\238\132\135 " .. osc_styles.smallButtonsLlabel .. sid)
        end

        eventresponder.mouse_btn0_up = function () mp.send_command("osd-msg add sub 1") end
        eventresponder.mouse_btn2_up = function () mp.send_command("osd-msg add sub -1")  end
    end
    register_button(posX - pos_offsetX, bigbuttonrowY, 7, 70, 18, osc_styles.smallButtonsL, contentF, eventresponder, metainfo)


    --toggle FS
    local contentF = function (ass)
        if mp.property_get("fullscreen") == "yes" then
            ass:append("\238\132\137")
        else
            ass:append("\238\132\136")
        end
    end
    local eventresponder = {}
    eventresponder.mouse_btn0_up = function () mp.send_command("no-osd cycle fullscreen") end
    register_button(posX+pos_offsetX, bigbuttonrowY, 6, 25, 25, osc_styles.smallButtonsR, contentF, eventresponder, nil)


    --
    -- Seekbar
    --

    local markerF = function ()
        local duration = 0
        if not (mp.property_get("length") == nil) then
            duration = tonumber(mp.property_get("length"))
        end

        local chapters = mp.get_chapter_list()
        local markers = {}
        for n = 1, #chapters do
            markers[n] = (chapters[n].time / duration * 100)
        end
        return markers
    end

    local posF = function ()
        if mp.property_get("length") == nil then
            return nil
        else
            return tonumber(mp.property_get("percent-pos"))
        end
    end

    local metainfo = {}
    metainfo.enabled = (not (mp.property_get("length") == nil)) and (tonumber(mp.property_get("length")) > 0)
    metainfo.styledown = false
    metainfo.slider = {}
    metainfo.slider.border = 1
    metainfo.slider.gap = 1             -- >1 will draw triangle markers
    metainfo.slider.type = "slider"     -- "bar" for old bar-style filling

    local eventresponder = {}
    local sliderF = function (element)
        local seek_to = get_slider_value(element)
        if not(state.last_seek == seek_to) then
            mp.send_command(string.format("no-osd seek %f absolute-percent keyframes", get_slider_value(element)))
            state.last_seek = seek_to
        end
    end
    eventresponder.render = sliderF
    eventresponder.mouse_btn0_down = sliderF
    register_slider(posX, posY+pos_offsetY-22, 2, pos_offsetX*2, 15, osc_styles.timecodes, 0, 100, markerF, posF, eventresponder, metainfo)

    --
    -- Timecodes + Volume
    --

    local bottomrowY = posY + pos_offsetY - 5

    -- left (current pos)
    local metainfo = {}
    local eventresponder = {}

    local contentF = function (ass)
        if state.tc_ms then
            ass:append(mp.property_get_string("time-pos/full"))
        else
            ass:append(mp.property_get_string("time-pos"))
        end
    end

    eventresponder.mouse_btn0_up = function () state.tc_ms = not state.tc_ms end
    register_button(posX - pos_offsetX, bottomrowY, 4, 110, 18, osc_styles.timecodes, contentF, eventresponder, metainfo)

    -- right (total/remaining time)
    -- do we have a usuable duration?
    local metainfo = {}
    metainfo.visible = (not (mp.property_get("length") == nil)) and (tonumber(mp.property_get("length")) > 0)

    local contentF = function (ass)
        if state.rightTC_trem == true then
            if state.tc_ms then
                ass:append("-" .. mp.property_get_string("time-remaining/full"))
            else
                ass:append("-" .. mp.property_get_string("time-remaining"))
            end
        else
            if state.tc_ms then
                ass:append(mp.property_get_string("length/full"))
            else
                ass:append(mp.property_get_string("length"))
            end
        end
    end
    local eventresponder = {}
    eventresponder.mouse_btn0_up = function () state.rightTC_trem = not state.rightTC_trem end

    register_button(posX + pos_offsetX, bottomrowY, 6, 110, 18, osc_styles.timecodes, contentF, eventresponder, metainfo)

    -- Volume Slider
    --[[

    local posF = function ()
        if not(mp.property_get("volume") == nil) then
            return tonumber(mp.property_get("volume"))
        else
            return 0
        end
    end


    local metainfo = {}
    metainfo.styledown = false
    metainfo.slider = {}
    metainfo.slider.border = 1
    metainfo.slider.gap = 1

    local eventresponder = {}
    local sliderF = function (element)
        mp.send_command(string.format("no-osd set volume %f", get_slider_value(element)))
    end
    eventresponder.mouse_move = sliderF
    eventresponder.mouse_btn0_down = sliderF
    eventresponder.mouse_btn2_up = function ()  mp.send_command("no-osd set volume 100") end
    register_slider(posX,bottomrowY, 5, 150, 12, osc_styles.timecodes, 0, 100, nil, posF, eventresponder, metainfo)
    --]]

end

--
-- Other important stuff
--

function show_osc()
    --state.last_osd_time = mp.get_timer()
    state.osc_visible = true
end

function hide_osc()
    state.osc_visible = false
end

function mouse_leave()
    hide_osc()
end

function request_init()
    state.initREQ = true
end

-- called by mpv on every frame
function render()
    local current_screen_sizeX, current_screen_sizeY = mp.get_screen_size()

    if not (state.mp_screen_sizeX == current_screen_sizeX and state.mp_screen_sizeY == current_screen_sizeY) then
    -- display changed, reinit everything
        request_init()
        state.mp_screen_sizeX, state.mp_screen_sizeY = current_screen_sizeX, current_screen_sizeY
    end

    if state.initREQ then
        osc_init()
        state.initREQ = false
    end

    local ass = assdraw.ass_new()

    --ass:new_event()
    --ass:append(0 .." ".. area_y0 .." ".. osc_param.playresx .." ".. area_y1)

    --local x, y = mp.get_mouse_pos()

    --local now = mp.get_timer()


    if state.osc_visible then
        render_elements(ass)
    end

    render_message(ass)


    --[[ Old show handling

    if mouse_over_osc() or state.mouse_down then
        show_osc()
    end

    local osd_time = 1

    if state.osc_visible and now - state.last_osd_time < osd_time then
        draw_osc(ass)
        state.osc_visible = true
    else
        state.osc_visible = false
    end
    --]]

    --ass:new_event()

    --local playresx, playresy = mp.get_osd_resolution()
    --ass:append("{get_osd_resolution: X:" .. playresx .. " Y:" .. playresy .. "}")
    --ass:append(now)
    --local playresx, playresy = mp.get_osd_resolution()
    --ass:append("get_mouse_pos: X:" .. x .. " Y:" .. y .. "")
    --if state.active_button == nil then
    --    ass:append("state.active_button: " .. "nil")
    --else
    --    ass:append("state.active_button: " .. state.active_button)
    --end
    --ass:append("Build time: " .. (mp.get_timer() - now)*1000 .." ms")

    --[[
    ass:new_event()
    ass:pos(x, y)
    ass:append("{\\an5}")
    if state.mouse_down == true then
        ass:append("-")
    else
        ass:append("+")
    end
    -- set canvas size
    --mp.set_osd_ass(osc_geo.playresx, osc_geo.playresy, ass.text)
    --]]

    -- make sure there is something in ass so that mp.set_osd_ass won't fail
    --ass:new_event()
    --ass:append(tonumber(mp.property_get("percent-pos")))

    local w, h, aspect = mp.get_screen_size()
    mp.set_osd_ass(osc_param.playresy * aspect, osc_param.playresy, ass.text)

    -- set mouse area
    local area_y0, area_y1
    if osc_param.valign > 0 then
        -- deadzone above OSC
        area_y0 = get_align(1 - osc_param.deadzonedist, osc_param.posY - (osc_param.osc_h / 2), 0, 0)
        area_y1 = osc_param.playresy
    else
        -- deadzone below OSC
        area_y0 = 0
        area_y1 = (osc_param.posY + (osc_param.osc_h / 2))
         + get_align(-1 + osc_param.deadzonedist, osc_param.playresy - (osc_param.posY + (osc_param.osc_h / 2)), 0, 0)
    end

    mp.set_mouse_area(0, area_y0, osc_param.playresx, area_y1)

end

--
-- Eventhandling
--

function process_event(source, what)

    if what == "down" then

        --state.active_element = 0
        for n = 1, #elements do

            if not (elements[n].eventresponder == nil) then
                if not (elements[n].eventresponder[source .. "_up"] == nil) or not (elements[n].eventresponder[source .. "_down"] == nil) then

                    if mouse_hit(elements[n]) then
                        state.active_element = n
                        state.active_event_source = source
                        -- fire the down event if the element has one
                        if not (elements[n].eventresponder[source .. "_" .. what] == nil) then
                            elements[n].eventresponder[source .. "_" .. what](elements[n])
                        end
                    end
                end

            end
        end

    elseif what == "up" then

        if not (state.active_element == nil) then

            local n = state.active_element

            if n == 0 then
                --click on background (does not work)
            elseif n > 0 and not (elements[n].eventresponder[source .. "_" .. what] == nil) then

                if mouse_hit(elements[n]) then
                    elements[n].eventresponder[source .. "_" .. what](elements[n])
                end
            end
        end
        state.active_element = nil
        state.mouse_down_counter = 0
        state.last_seek = nil

    elseif source == "mouse_move" then
        show_osc()

        if not (state.active_element == nil) then

            local n = state.active_element

            if not (elements[n].eventresponder == nil) then
                if not (elements[n].eventresponder[source] == nil) then
                    elements[n].eventresponder[source](elements[n])
                end
            end
        end
    end
end

function mp_event(name, arg)
    --print("event: " .. name .. " arg: " .. (arg or "-") .. " -")
    if name == "tick" then
        render()
    elseif name == "start" or name == "track-layout" then
        --print("start new file")
        request_init()
    elseif name == "end" then
        --print("end current file")
    end
end

mp.set_key_bindings {
    {"mouse_btn0",              function(e) process_event("mouse_btn0", "up") end,
                                function(e) process_event("mouse_btn0", "down")  end},
    {"shift+mouse_btn0",        function(e) process_event("shift+mouse_btn0", "up") end,
                                function(e) process_event("shift+mouse_btn0", "down")  end},
    {"mouse_btn2",              function(e) process_event("mouse_btn2", "up") end,
                                function(e) process_event("mouse_btn2", "down")  end},
    {"mouse_move",              function(e) process_event("mouse_move", nil) end},
    {"mouse_leave",             mouse_leave},
    {"mouse_btn0_dbl",          "ignore"},
    {"shift+mouse_btn0_dbl",    "ignore"},
    {"mouse_btn2_dbl",          "ignore"},
}
mp.enable_key_bindings()
