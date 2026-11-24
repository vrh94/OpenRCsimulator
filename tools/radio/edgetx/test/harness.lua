-- Headless test harness for the OpenRC EdgeTX scripts (tools/radio/edgetx/SCRIPTS). It runs a script under a desktop
-- Lua (5.2 or newer) against a mock of the EdgeTX 2.12 Lua API for a 128x64 radio: lcd calls are recorded and checked
-- against the screen, sensors come from a scenario table, files live under a temporary SD root, and serialRead/Write
-- use in-memory FIFOs. Run: lua tools/radio/edgetx/test/test_flight.lua [path/to/SOUNDS/en]
local H = {}

H.W, H.H = 128, 64
H.failures = 0

function H.check(label, ok, detail)
  if ok then print("ok   " .. label) else
    H.failures = H.failures + 1
    print("FAIL " .. label .. (detail and (" " .. tostring(detail)) or ""))
  end
end

-- Lua 5.2 had math.atan2; EdgeTX keeps it.
if not math.atan2 then math.atan2 = function(y, x) return math.atan(y, x) end end

-- Flags and constants (values only need to be distinct bits)
SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE = 0x0100, 0x0200, 0x0400, 0x0800
INVERS, BLINK, RIGHT, BOLD, FORCE, ERASE, PREC1, PREC2, TIMEHOUR = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1000
SOLID, DOTTED = 0, 1
EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV, EVT_VIRTUAL_ENTER, EVT_VIRTUAL_ENTER_LONG, EVT_VIRTUAL_EXIT = 101, 102, 103, 104, 105
UNIT_GPS = 40

local function has(flags, f) return math.floor(flags / f) % 2 == 1 end

local function charWidth(flags)
  if has(flags, SMLSIZE) then return 4 elseif has(flags, MIDSIZE) then return 8 elseif has(flags, DBLSIZE) then return 10 end
  return 6
end

local function charHeight(flags)
  if has(flags, SMLSIZE) then return 6 elseif has(flags, MIDSIZE) then return 12 elseif has(flags, DBLSIZE) then return 16 end
  return 8
end

-- State reset per scenario
function H.reset(scenario)
  H.t = 0
  H.scenario = scenario or {}
  H.sensors = H.scenario.sensors or {}
  H.sources = H.scenario.sources or {}
  H.draws = {}
  H.played = {}
  H.haptics = 0
  H.oob = {}
  H.serialIn = ""
  H.serialOut = {}
  H.telemetry = {}
  H.modelName = H.scenario.model or "SIM"
end

local function oob(what, x1, y1, x2, y2)
  if x1 < 0 or y1 < 0 or x2 > H.W or y2 > H.H then
    H.oob[#H.oob + 1] = string.format("%s %d,%d-%d,%d", what, x1, y1, x2, y2)
  end
end

lcd = {}
function lcd.clear() H.draws = {} end
function lcd.drawText(x, y, text, flags)
  flags = flags or 0
  text = tostring(text)
  local w, h = #text * charWidth(flags), charHeight(flags)
  local x1 = has(flags, RIGHT) and (x - w) or x
  oob("text '" .. text .. "'", x1, y, x1 + w - 1, y + h - 1)
  H.draws[#H.draws + 1] = { "text", text, x1, y, w, h, flags }
end
function lcd.drawNumber(x, y, v, flags) lcd.drawText(x, y, tostring(v), flags) end
function lcd.drawTimer(x, y, v, flags)
  lcd.drawText(x, y, string.format("%02d:%02d", math.floor(v / 60), math.floor(v) % 60), flags)
end
function lcd.drawLine(x1, y1, x2, y2, pattern, flags)
  oob("line", math.min(x1, x2), math.min(y1, y2), math.max(x1, x2) + 1, math.max(y1, y2) + 1)
  H.draws[#H.draws + 1] = { "line", x1, y1, x2, y2, pattern or 0 }
end
function lcd.drawPoint(x, y) oob("point", x, y, x + 1, y + 1); H.draws[#H.draws + 1] = { "point", x, y } end
function lcd.drawRectangle(x, y, w, h) oob("rect", x, y, x + w, y + h); H.draws[#H.draws + 1] = { "rect", x, y, w, h } end
function lcd.drawFilledRectangle(x, y, w, h) oob("fill", x, y, x + w, y + h) end
function lcd.drawGauge(x, y, w, h, fill, max)
  oob("gauge", x, y, x + w, y + h)
  H.draws[#H.draws + 1] = { "gauge", x, y, w, h, fill / max }
  assert(fill >= 0 and fill <= max, "gauge fill out of range " .. tostring(fill))
end

function getTime() return H.t end
function getRSSI()
  local v = H.scenario.rssi
  if type(v) == "function" then v = v(H.t) end
  return v or 0, 45, 42
end
function getFieldInfo(name)
  local s = H.sensors[name]
  if s then return { id = s.id, name = name, desc = name, unit = s.unit } end
  if H.telemetry[name] then return { id = H.telemetry[name].id, name = name, unit = H.telemetry[name].unit } end
  return nil
end
function getValue(key)
  if type(key) == "number" then
    for _, s in pairs(H.sensors) do
      if s.id == key then
        local v = s.value
        if type(v) == "function" then v = v(H.t) end
        return v
      end
    end
    for _, s in pairs(H.telemetry) do if s.id == key then return s.value end end
    return 0
  end
  local v = H.sources[key]
  if type(v) == "function" then v = v(H.t) end
  if v == nil then
    if key == "tx-voltage" then return 7.9 end
    if key == "thr" then return -1024 end -- throttle stick low
    return 0
  end
  return v
end
function getOutputValue(ch)
  local v = H.scenario.outputs and H.scenario.outputs[ch + 1]
  if type(v) == "function" then v = v(H.t) end
  return v or 0
end
function getVersion() return "2.12.5", "zorro", 2, 12, 5, "EdgeTX" end
function getGeneralSettings() return { language = "en" } end
function playFile(name) H.played[#H.played + 1] = name end
function playHaptic() H.haptics = H.haptics + 1 end
function killEvents() end
function setTelemetryValue(id, sub, inst, value, unit, prec, name)
  local key = name or string.format("%04X", id)
  local s = H.telemetry[key] or { id = 1000 + id }
  s.value = prec and prec > 0 and value / 10 ^ prec or value
  s.raw, s.unit, s.prec = value, unit, prec
  H.telemetry[key] = s
  return true
end
function serialRead(n)
  local count = math.min(#H.serialIn, n and n > 0 and n or 256)
  if not n or n == 0 then
    local nl = string.find(H.serialIn, "[\r\n]")
    if nl and nl <= 256 then count = nl end
  end
  local out = string.sub(H.serialIn, 1, count)
  H.serialIn = string.sub(H.serialIn, count + 1)
  return out
end
function serialWrite(s) H.serialOut[#H.serialOut + 1] = s end

model = {}
function model.getInfo() return { name = H.modelName } end
function model.getTimer(i) return { mode = 0, value = 0 } end

-- SD card under a temporary root
H.root = os.getenv("TMPDIR") and (os.getenv("TMPDIR") .. "/openrc_edgetx_sd") or "/tmp/openrc_edgetx_sd"
H.scripts = nil -- set by the test to the repo's SCRIPTS parent folder
local realIo = io
local sd = {}
function sd.open(path, mode)
  local f = realIo.open(H.root .. path, mode == "w" and "wb" or (mode == "a" and "ab" or "rb"))
  return f
end
function sd.read(f, n) return f:read(n) end
function sd.write(f, ...) for _, s in ipairs({ ... }) do f:write(s) end end
function sd.close(f) f:close() end
io = sd
H.realIo = realIo

function loadScript(path)
  local local_path = H.scripts .. path
  local f = realIo.open(local_path, "rb")
  if not f then return nil end
  f:close()
  return assert(loadfile(local_path))
end

function H.load(rel)
  local chunk = assert(loadfile(H.scripts .. rel))
  return chunk()
end

function H.tick(script, n, event, visible)
  for _ = 1, n do
    H.t = H.t + 3
    if visible then script.run(event or 0); event = 0 else script.background() end
  end
end

-- Writes the current frame's primitives, one per line, for a preview renderer.
function H.dump(path)
  local f = H.realIo.open(path, "wb")
  for _, d in ipairs(H.draws) do
    local parts = {}
    for i, v in ipairs(d) do parts[i] = tostring(v) end
    f:write(table.concat(parts, "\t"), "\n")
  end
  f:close()
end

function H.texts()
  local out = {}
  for _, d in ipairs(H.draws) do if d[1] == "text" then out[#out + 1] = d[2] end end
  return table.concat(out, " | ")
end

function H.overlaps()
  local texts = {}
  for _, d in ipairs(H.draws) do if d[1] == "text" and d[2] ~= "" then texts[#texts + 1] = d end end
  local hits = {}
  for i = 1, #texts do
    for j = i + 1, #texts do
      local a, b = texts[i], texts[j]
      if a[3] < b[3] + b[5] and b[3] < a[3] + a[5] and a[4] < b[4] + b[6] and b[4] < a[4] + a[6] then
        hits[#hits + 1] = "'" .. a[2] .. "' x '" .. b[2] .. "'"
      end
    end
  end
  return hits
end

return H
