-- OpenRC flight screen for EdgeTX 128x64 radios (RadioMaster Zorro and similar).
-- A telemetry ("model screen") script: a HUD in the classic telemetry-screen arrangement (artificial horizon in the
-- middle, battery left, altitude and speeds right, mode and timer on top, messages below), a link page, a statistics
-- page and a settings menu. It reads ELRS/CRSF, FrSky D16 (SmartPort, iNav) and FrSky D8 telemetry by detecting which
-- sensors exist, and the OpenRC simulator's link (simlnk.lua) when the radio is connected to the simulator in USB
-- serial mode. Nothing is invented: a value whose sensor is absent is not drawn. Units are metric.
-- Wheel: change page. ENTER: settings menu (wheel selects, ENTER edits, EXIT saves). Long ENTER on Stats: reset.
-- Lua 5.2 subset (EdgeTX). Original code for OpenRCsimulator; see tools/radio/edgetx/README.md.

local CFG_PATH = "/SCRIPTS/TELEMETRY/flight.cfg"
local SIM_PATH = "/SCRIPTS/TELEMETRY/simlnk.lua"
local SENSORS = { "RQly", "1RSS", "2RSS", "RSNR", "RFMD", "TPWR", "RSSI", "RxBt", "VFAS", "A1", "A2", "A4", "Curr",
  "Capa", "Bat%", "Fuel", "FM", "GPS", "GSpd", "ASpd", "Alt", "VSpd", "Hdg", "Sats", "Ptch", "Roll", "Dist",
  "470", "0470", "Tmp1", "480", "0480", "Tmp2", "0420", "0430", "0440" }
local SWITCHES = { "sa", "sb", "sc", "sd", "se", "sf", "sg", "sh" }
local BAT_SOURCES = { "auto", "VFAS", "RxBt", "A2", "A1" }
local MODE_SOUND = { ACRO = "acro", MANU = "manual", RTH = "rth", WRTH = "rth", CRUZ = "cruise", WP = "navwp",
  LAND = "landin", HOLD = "poshld", LOTR = "loiter", HOR = "fm-hor", TURT = "turton", ["!FS!"] = "fsact" }
local DISARMED_FM = { OK = true, WAIT = true, ["!ERR"] = true }
local PAGES = 3

-- Units (EdgeTX TelemetryUnit)
local U_KTS, U_MPS, U_KMH, U_MPH, U_M, U_FT, U_PCT, U_MAH, U_RAD = 4, 5, 7, 8, 9, 10, 13, 14, 21

local ids, units = {}, {}
local cfg = { cells = 0, low = 350, crit = 330, bat = 1, arm = 0, alerts = 1, lq = 70, rssi = 45 }
local T = {}           -- current values (nil = absent)
local S = {}           -- statistics
local st = { page = 1, menu = false, sel = 1, edit = false, scan = -1000, armed = false, armedAt = 0, armedTime = 0,
  lastTick = 0, mode = nil, msg = "", msgAt = -100000, lowAt = -100000, critAt = -100000, sigAt = -100000,
  modeAt = -100000, home = nil, model = "", proto = "", cells = 0 }
local sim = nil

local function now() return getTime() end -- 10 ms ticks

local function say(text, file)
  st.msg = text
  st.msgAt = now()
  if file and cfg.alerts == 1 then playFile(file .. ".wav") end
end

-- Settings ------------------------------------------------------------------------------------------------------------

local KEYS = { "cells", "low", "crit", "bat", "arm", "alerts", "lq", "rssi" }

local function loadCfg()
  local f = io.open(CFG_PATH, "r")
  if not f then return end
  local text = io.read(f, 2048) or ""
  io.close(f)
  for line in string.gmatch(text, "[^\n]+") do
    local name, rest = string.match(line, "^(.-)|(.*)$")
    if name == st.model then
      local i = 1
      for n in string.gmatch(rest, "[^,]+") do
        local key = KEYS[i]
        if key then cfg[key] = tonumber(n) or cfg[key] end
        i = i + 1
      end
    end
  end
end

local function saveCfg()
  local lines, text = {}, ""
  local f = io.open(CFG_PATH, "r")
  if f then
    text = io.read(f, 2048) or ""
    io.close(f)
  end
  for line in string.gmatch(text, "[^\n]+") do
    if string.match(line, "^(.-)|") ~= st.model and #lines < 30 then lines[#lines + 1] = line end
  end
  local values = {}
  for i = 1, #KEYS do values[i] = tostring(cfg[KEYS[i]]) end
  lines[#lines + 1] = st.model .. "|" .. table.concat(values, ",")
  f = io.open(CFG_PATH, "w")
  if f then
    io.write(f, table.concat(lines, "\n") .. "\n")
    io.close(f)
  end
end

-- Sensors ---------------------------------------------------------------------------------------------------------------

local function scan()
  for i = 1, #SENSORS do
    local info = getFieldInfo(SENSORS[i])
    ids[SENSORS[i]] = info and info.id or nil
    units[SENSORS[i]] = info and info.unit or nil
  end
  st.scan = now()
end

local function val(name)
  local id = ids[name]
  if not id then return nil end
  local v = getValue(id)
  if type(v) ~= "number" then return nil end
  return v
end

local function first(a, b, c)
  local id = ids[a] and a or (ids[b] and b or (c and ids[c] and c or nil))
  return id and val(id) or nil, id
end

local function digit(v, k) return math.floor(v / 10 ^ k) % 10 end
local function bit(d, b) return math.floor(d / b) % 2 == 1 end

-- iNav SmartPort mode sensor (470, formerly Tmp1): 7 digits ABCDEFG, see INAV docs/Telemetry.md.
local function inavMode(v)
  local g, f, e, d, c = digit(v, 0), digit(v, 1), digit(v, 2), digit(v, 3), digit(v, 4)
  local armed = bit(g, 4)
  local mode
  if not armed then mode = bit(g, 2) and "!ERR" or "OK"
  elseif bit(c, 4) then mode = "!FS!"
  elseif bit(d, 1) then mode = "RTH"
  elseif bit(d, 2) then mode = "WP"
  elseif bit(d, 8) then mode = bit(e, 2) and "CRUZ" or "CRSH"
  elseif bit(e, 4) then mode = "HOLD"
  elseif bit(f, 4) then mode = "MANU"
  elseif bit(e, 2) then mode = "AH"
  elseif bit(f, 1) then mode = "ANGL"
  elseif bit(f, 2) then mode = "HOR"
  else mode = "ACRO" end
  return mode, armed
end

local function toKmh(v, unit)
  if unit == U_KTS then return v * 1.852 elseif unit == U_MPS then return v * 3.6
  elseif unit == U_MPH then return v * 1.609344 end
  return v
end

local function toDeg(v, unit)
  if unit == U_RAD then return math.deg(v) end
  return v
end

local function distBearing(lat1, lon1, lat2, lon2)
  local r = math.rad
  local dlat, dlon = r(lat2 - lat1), r(lon2 - lon1)
  local a = math.sin(dlat / 2) ^ 2 + math.cos(r(lat1)) * math.cos(r(lat2)) * math.sin(dlon / 2) ^ 2
  local d = 6371000 * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
  local y = math.sin(dlon) * math.cos(r(lat2))
  local x = math.cos(r(lat1)) * math.sin(r(lat2)) - math.sin(r(lat1)) * math.cos(r(lat2)) * math.cos(dlon)
  return d, (math.deg(math.atan2(y, x)) + 360) % 360
end

-- Reads every source into T. Called from background and run.
local function update()
  local t = now()
  if t - st.scan > 100 then scan() end
  local s = sim and sim.poll() or nil
  local simUp = s and s.alive
  local v
  T = {}
  T.tx = getValue("tx-voltage")
  T.thr = (getValue("thr") + 1024) / 20.48
  -- Link
  T.lq = val("RQly")
  T.rssi = T.lq == nil and val("RSSI") or nil
  local streaming = (getRSSI() or 0) > 0
  if T.lq then st.proto = "ELRS"
  elseif simUp then st.proto = "SIM"
  elseif ids.RSSI and ids.RxBt then st.proto = "D16"
  elseif ids.RSSI and ids.A1 then st.proto = "D8"
  elseif ids.RSSI then st.proto = "FrSky"
  else st.proto = "" end
  T.live = streaming or simUp
  -- Battery
  local src = BAT_SOURCES[cfg.bat]
  if src == "auto" then v = first("VFAS", "RxBt", "A2") or val("A1") else v = val(src) end
  T.volt = (v and v > 0) and v or nil
  T.cell = val("A4")
  if T.volt and not T.cell then
    -- auto: the largest count the pack has shown (a sagging pack must not look like one cell fewer)
    st.cells = math.max(st.cells, math.ceil(T.volt / 4.35))
    local cells = cfg.cells > 0 and cfg.cells or st.cells
    T.cell = T.volt / cells
  end
  T.curr = val("Curr")
  T.mah = val("Capa")
  T.pct = val("Bat%")
  v = val("Fuel")
  if v then
    if units.Fuel == U_MAH then T.mah = T.mah or v elseif units.Fuel == U_PCT then T.pct = T.pct or v end
  end
  -- Flight data
  v = val("Alt")
  if v then T.alt = units.Alt == U_FT and v * 0.3048 or v end
  T.vs = val("VSpd")
  v = val("GSpd")
  if v then T.gs = toKmh(v, units.GSpd) end
  v = val("ASpd")
  if v then T.as = toKmh(v, units.ASpd) end
  T.hdg = val("Hdg")
  v = val("Ptch")
  if v then T.pitch = toDeg(v, units.Ptch) else v = val("0430"); if v then T.pitch = v / 10 end end
  v = val("Roll")
  if v then T.roll = toDeg(v, units.Roll) else v = val("0440"); if v then T.roll = v / 10 end end
  T.sats = val("Sats")
  -- Mode and arming
  local armedKnown
  if ids.FM then
    local fm = getValue(ids.FM)
    if type(fm) == "string" and fm ~= "" then
      local disarmed = DISARMED_FM[fm] or string.sub(fm, -1) == "*"
      T.mode = string.gsub(fm, "%*$", "")
      armedKnown = not disarmed
    end
  end
  v = first("470", "0470", "Tmp1")
  if v and v > 0 and armedKnown == nil then T.mode, armedKnown = inavMode(v) end
  v = first("480", "0480", "Tmp2")
  if v and v > 0 then
    T.sats = T.sats or v % 100
    T.fix = bit(digit(v, 3), 1)
  end
  -- Simulator link (values it does not send stay nil)
  if simUp then
    for k, x in pairs(s.values) do T[k] = x end
    if s.armed ~= nil then armedKnown = s.armed end
  end
  -- Arming: telemetry, simulator, switch, throttle
  local armed
  if cfg.arm == 0 and armedKnown ~= nil and T.live then armed = armedKnown
  elseif cfg.arm >= 1 and cfg.arm <= 8 then armed = getValue(SWITCHES[cfg.arm]) > 0
  else armed = T.thr > 5 end
  -- GPS and home
  local gps = ids.GPS and getValue(ids.GPS) or nil
  if type(gps) == "table" and gps.lat and gps.lat ~= 0 then T.lat, T.lon = gps.lat, gps.lon end
  if armed and not st.armed then st.home = nil end
  if T.lat and armed and not st.home then st.home = { T.lat, T.lon } end
  if T.dist == nil then
    v = val("0420") or val("Dist")
    if v then T.dist = v
    elseif st.home and T.lat then T.dist, T.homeDir = distBearing(T.lat, T.lon, st.home[1], st.home[2]) end
  end
  -- Arming edges, timer, mode callouts
  if armed ~= st.armed then
    st.armed = armed
    if armed then st.armedAt = t; say("Armed", "armed") else say("Disarmed", "disarm") end
  end
  if armed then st.armedTime = st.armedTime + (t - st.lastTick) end
  st.lastTick = t
  if T.mode and T.mode ~= st.mode then
    if st.mode and t - st.modeAt > 100 then say(T.mode, MODE_SOUND[T.mode]) end
    st.mode, st.modeAt = T.mode, t
  end
  -- Alerts
  if T.cell and T.live then
    if T.cell * 100 < cfg.crit then
      if t - st.critAt > 1000 then st.critAt = t; say("BATTERY CRITICAL", "lowbat"); playHaptic(30, 10, 0) end
    elseif T.cell * 100 < cfg.low then
      if t - st.lowAt > 2000 then st.lowAt = t; say("Battery low", "lowbat") end
    end
  end
  if streaming and ((T.lq and T.lq < cfg.lq) or (T.rssi and T.rssi < cfg.rssi)) and t - st.sigAt > 1500 then
    st.sigAt = t
    say("Signal low", "siglow")
  end
  -- Statistics
  if T.live then
    local function hi(k, x) if x and (S[k] == nil or x > S[k]) then S[k] = x end end
    local function lo(k, x) if x and (S[k] == nil or x < S[k]) then S[k] = x end end
    hi("alt", T.alt); hi("dist", T.dist); hi("gs", T.gs); hi("curr", T.curr); hi("mah", T.mah)
    if armed then lo("cell", T.cell); lo("lq", T.lq); lo("rssi", T.rssi) end
  end
end

-- Drawing ---------------------------------------------------------------------------------------------------------------

local BX, BY, BW, BH = 33, 9, 62, 46 -- horizon box
local CX, CY = BX + 31, BY + 23
local K = 0.66 -- pixels per degree of pitch

local function rnd(v) return math.floor(v + 0.5) end

local function fmt(v, f)
  if v == nil then return "--" end
  if string.find(f, "d") and not string.find(f, "%.") then v = rnd(v) end
  return string.format(f, v)
end

local function inBox(x, y) return x > BX and x < BX + BW - 1 and y > BY and y < BY + BH - 1 end

local function horizon()
  lcd.drawRectangle(BX, BY, BW, BH)
  local r = math.rad(T.roll or 0)
  local p = T.pitch or 0
  local c, s = math.cos(r), math.sin(r)
  if math.abs(c) < 0.05 then c = c < 0 and -0.05 or 0.05 end
  local hx, hy = CX + s * p * K, CY + c * p * K
  if T.pitch ~= nil and T.roll ~= nil then
    for x = BX + 1, BX + BW - 2 do
      local y = math.floor(hy - s * (x - hx) / c + 0.5)
      if c > 0 then
        local top = math.max(y, BY + 1)
        if top <= BY + BH - 2 then lcd.drawLine(x, top, x, BY + BH - 2, DOTTED, 0) end
      else
        local bottom = math.min(y, BY + BH - 2)
        if bottom >= BY + 1 then lcd.drawLine(x, BY + 1, x, bottom, DOTTED, 0) end
      end
      if y > BY and y < BY + BH - 1 then lcd.drawPoint(x, y) end
    end
    for step = -20, 20, 10 do
      if step ~= 0 then
        local lx, ly = hx - s * step * K, hy - c * step * K
        local x1, y1, x2, y2 = lx - c * 5, ly + s * 5, lx + c * 5, ly - s * 5
        if inBox(x1, y1) and inBox(x2, y2) then
          lcd.drawLine(math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), step > 0 and SOLID or DOTTED, 0)
        end
      end
    end
  else
    lcd.drawText(CX - 10, CY + 8, "no att", SMLSIZE)
  end
  -- aircraft symbol
  lcd.drawLine(CX - 9, CY, CX - 4, CY, SOLID, FORCE)
  lcd.drawLine(CX + 4, CY, CX + 9, CY, SOLID, FORCE)
  lcd.drawLine(CX - 4, CY, CX - 2, CY + 2, SOLID, FORCE)
  lcd.drawLine(CX + 4, CY, CX + 2, CY + 2, SOLID, FORCE)
  -- heading tape
  if T.hdg then
    local h = T.hdg
    for i, card in ipairs({ "N", "E", "S", "W" }) do
      local d = ((i - 1) * 90 - h + 540) % 360 - 180
      if math.abs(d) <= 40 and math.abs(d) >= 16 then lcd.drawText(CX + math.floor(d * 0.7) - 1, BY + 2, card, SMLSIZE) end
    end
    lcd.drawText(CX - 5, BY + 1, string.format("%03d", rnd(h) % 360), SMLSIZE + INVERS)
  end
  -- home arrow
  if T.dist and T.dist > 5 and T.homeDir and T.hdg then
    local a = math.rad(T.homeDir - T.hdg)
    local ax, ay = CX, BY + BH - 8
    local tx, ty = ax + math.sin(a) * 5, ay - math.cos(a) * 5
    local lx, ly = ax + math.sin(a + 2.5) * 4, ay - math.cos(a + 2.5) * 4
    local rx, ry = ax + math.sin(a - 2.5) * 4, ay - math.cos(a - 2.5) * 4
    lcd.drawLine(math.floor(tx), math.floor(ty), math.floor(lx), math.floor(ly), SOLID, FORCE)
    lcd.drawLine(math.floor(tx), math.floor(ty), math.floor(rx), math.floor(ry), SOLID, FORCE)
    lcd.drawLine(math.floor(lx), math.floor(ly), math.floor(rx), math.floor(ry), SOLID, FORCE)
  end
end

local function topBar()
  local mode = T.mode or (st.armed and "ARMED" or "SAFE")
  lcd.drawText(0, 0, mode, st.armed and INVERS or 0)
  lcd.drawTimer(48, 0, math.floor(st.armedTime / 100), 0)
  lcd.drawText(127, 1, fmt(T.tx, "%.1fV"), SMLSIZE + RIGHT)
end

local function bottomBar()
  local t = now()
  if not T.live and st.proto ~= "" then
    lcd.drawText(0, 57, "Telemetry lost", SMLSIZE + BLINK)
    return
  elseif st.msg ~= "" and t - st.msgAt < 600 then
    lcd.drawText(0, 57, st.msg, SMLSIZE + ((t - st.msgAt < 200) and INVERS or 0))
  elseif not T.live then
    lcd.drawText(0, 57, "No telemetry", SMLSIZE)
  else
    lcd.drawText(0, 57, string.format("%s %s", st.proto, T.sats and ("sat " .. rnd(T.sats)) or ""), SMLSIZE)
  end
  local link = not T.live and "" or (T.lq and string.format("LQ%d", rnd(T.lq)) or (T.rssi and string.format("R%d", rnd(T.rssi)) or ""))
  lcd.drawText(127, 57, link, SMLSIZE + RIGHT)
end

local function hud()
  topBar()
  horizon()
  -- battery (left)
  lcd.drawText(0, 10, fmt(T.volt, "%.1f"), MIDSIZE)
  lcd.drawText(0, 23, fmt(T.cell, "%.2fv"), SMLSIZE)
  lcd.drawText(0, 30, fmt(T.curr, "%.1fA"), SMLSIZE)
  lcd.drawText(0, 37, fmt(T.mah, "%dmAh"), SMLSIZE)
  if T.pct then
    lcd.drawGauge(0, 45, 31, 7, math.max(0, math.min(100, T.pct)), 100)
  elseif T.cell then
    lcd.drawGauge(0, 45, 31, 7, math.max(0, math.min(100, (T.cell - 3.3) / 0.9 * 100)), 100)
  end
  -- flight data (right)
  lcd.drawText(127, 10, fmt(T.alt, "%d"), MIDSIZE + RIGHT)
  lcd.drawText(127, 23, T.vs and string.format("VS%+.1f", T.vs) or "VS --", SMLSIZE + RIGHT)
  lcd.drawText(127, 30, T.gs and string.format("GS%d", rnd(T.gs)) or "GS --", SMLSIZE + RIGHT)
  lcd.drawText(127, 37, T.as and string.format("AS%d", rnd(T.as)) or "", SMLSIZE + RIGHT)
  local d = T.dist
  lcd.drawText(127, 45, d == nil and "H --" or (d >= 1000 and string.format("H%.1fk", d / 1000) or string.format("H%d", rnd(d))),
    SMLSIZE + RIGHT)
  bottomBar()
end

local function row(y, label, value)
  lcd.drawText(0, y, label, SMLSIZE)
  lcd.drawText(127, y, value, SMLSIZE + RIGHT)
end

local function linkPage()
  topBar()
  lcd.drawText(0, 10, "LINK " .. (st.proto ~= "" and st.proto or "none"), SMLSIZE + INVERS)
  if st.proto == "ELRS" then
    row(18, "Link quality", fmt(T.lq, "%d%%"))
    row(25, "RSSI ant 1 / 2", fmt(val("1RSS"), "%d") .. " / " .. fmt(val("2RSS"), "%d") .. " dBm")
    row(32, "SNR", fmt(val("RSNR"), "%d dB"))
    row(39, "Rate index / power", fmt(val("RFMD"), "%d") .. " / " .. fmt(val("TPWR"), "%dmW"))
    row(46, "RX battery", fmt(val("RxBt"), "%.2fV"))
  elseif st.proto == "SIM" then
    local s = sim.poll()
    row(18, "Simulator", s.name or "OpenRC")
    row(25, "Sticks sent", string.format("%d/s", rnd(s.txRate or 0)))
    row(32, "Telemetry recv", string.format("%d/s", rnd(s.rxRate or 0)))
    row(39, "Bad lines", tostring(s.bad or 0))
    row(46, "Note", "no RF link: no RSSI")
  elseif st.proto ~= "" then
    row(18, "RSSI", fmt(T.rssi, "%d dB"))
    row(25, "RX battery", fmt(val("RxBt"), "%.2fV"))
    row(32, "A1 / A2", fmt(val("A1"), "%.2f") .. " / " .. fmt(val("A2"), "%.2fV"))
    row(39, "Sats", fmt(T.sats, "%d") .. (T.fix and " fix" or ""))
  else
    lcd.drawText(0, 24, "No telemetry sensors.", SMLSIZE)
    lcd.drawText(0, 32, "MDL > Telemetry > Discover", SMLSIZE)
  end
  bottomBar()
end

local function statsPage()
  topBar()
  lcd.drawText(0, 8, "STATS  long ENTER = reset", SMLSIZE + INVERS)
  row(15, "Max alt / dist", fmt(S.alt, "%dm") .. " / " .. fmt(S.dist, "%dm"))
  row(22, "Max speed / curr", fmt(S.gs, "%dkm/h") .. " / " .. fmt(S.curr, "%.1fA"))
  row(29, "Min cell", fmt(S.cell, "%.2fV"))
  row(36, "Min LQ / RSSI", fmt(S.lq, "%d%%") .. " / " .. fmt(S.rssi, "%d"))
  row(43, "Used", fmt(S.mah, "%dmAh"))
  local timer = model.getTimer(0)
  if timer and timer.mode ~= 0 then
    lcd.drawText(0, 50, "Timer1", SMLSIZE)
    lcd.drawTimer(127, 50, timer.value, SMLSIZE + RIGHT)
  end
  bottomBar()
end

-- Menu ------------------------------------------------------------------------------------------------------------------

local MENU = {
  { "Cells", "cells", 0, 8, function(v) return v == 0 and "auto" or (v .. "S") end },
  { "Low cell", "low", 300, 400, function(v) return string.format("%.2fV", v / 100) end },
  { "Critical cell", "crit", 280, 380, function(v) return string.format("%.2fV", v / 100) end },
  { "Battery", "bat", 1, #BAT_SOURCES, function(v) return BAT_SOURCES[v] end },
  { "Arming", "arm", 0, 9, function(v) return v == 0 and "auto" or (v == 9 and "throttle" or string.upper(SWITCHES[v]) .. " down") end },
  { "Voice alerts", "alerts", 0, 1, function(v) return v == 1 and "on" or "off" end },
  { "LQ warning", "lq", 30, 95, function(v) return v .. "%" end },
  { "RSSI warning", "rssi", 30, 80, function(v) return v .. "dB" end },
}

local function menuPage()
  lcd.drawText(0, 0, "Screen settings", INVERS)
  local top = math.max(1, math.min(st.sel - 3, #MENU - 6))
  for i = top, math.min(#MENU, top + 6) do
    local item = MENU[i]
    local y = 9 + (i - top) * 8
    lcd.drawText(0, y, item[1], SMLSIZE)
    local flags = SMLSIZE + RIGHT
    if i == st.sel then flags = flags + INVERS + (st.edit and BLINK or 0) end
    lcd.drawText(127, y, item[5](cfg[item[2]]), flags)
  end
end

local function menuEvent(event)
  local item = MENU[st.sel]
  if event == EVT_VIRTUAL_EXIT then
    if st.edit then st.edit = false else st.menu = false; saveCfg() end
  elseif event == EVT_VIRTUAL_ENTER then
    st.edit = not st.edit
  elseif event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
    local d = event == EVT_VIRTUAL_NEXT and 1 or -1
    if st.edit then
      local step = (item[2] == "low" or item[2] == "crit") and 5 or 1
      cfg[item[2]] = math.max(item[3], math.min(item[4], cfg[item[2]] + d * step))
    else
      st.sel = math.max(1, math.min(#MENU, st.sel + d))
    end
  end
end

-- Script entry points ---------------------------------------------------------------------------------------------------

local function init()
  local info = model.getInfo()
  st.model = info and info.name or ""
  loadCfg()
  st.lastTick = now()
  if loadScript then
    local chunk = loadScript(SIM_PATH)
    if chunk then sim = chunk() end
  end
end

local function background()
  update()
end

local function run(event)
  update()
  lcd.clear()
  if st.menu then
    menuEvent(event)
    if st.menu then menuPage() return 0 end
    event = 0
  end
  if event == EVT_VIRTUAL_NEXT then st.page = st.page % PAGES + 1
  elseif event == EVT_VIRTUAL_PREV then st.page = (st.page + PAGES - 2) % PAGES + 1
  elseif event == EVT_VIRTUAL_ENTER_LONG and st.page == 3 then
    S = {}; st.armedTime = 0; killEvents(event); say("Stats reset")
  elseif event == EVT_VIRTUAL_ENTER then
    st.menu, st.sel, st.edit = true, 1, false
    lcd.clear(); menuPage(); return 0
  end
  if st.page == 1 then hud() elseif st.page == 2 then linkPage() else statsPage() end
  return 0
end

return { init = init, background = background, run = run }
