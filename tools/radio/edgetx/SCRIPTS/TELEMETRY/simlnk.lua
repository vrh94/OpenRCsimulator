-- OpenRC simulator link for EdgeTX (loaded by flight.lua). With the radio connected to the computer as
-- "USB Serial (VCP)" and SYS > Hardware > USB-VCP set to "LUA", this sends the radio's channel outputs to the
-- OpenRC simulator and receives the simulator's flight data, which it gives to flight.lua and publishes as
-- telemetry sensors (so EdgeTX voice, logs and other scripts can use them). EdgeTX runs Lua every 50 ms, so the
-- sticks reach the simulator 20 times a second; USB joystick mode remains the low-latency choice.
--
-- Line protocol (ASCII, one message per line, "*" + two hex digits = sum of the payload bytes mod 256):
--   radio -> simulator  C<16 x 3 hex digits: CH1..CH16 output + 1024, 0..2047>*cs
--                       H,<radio>,<EdgeTX version>*cs                 (once a second)
--   simulator -> radio  B,<volts>,<amps>,<mAh used>,<% left>*cs
--                       A,<alt m>,<vspeed m/s>,<ground km/h>,<air km/h>,<heading deg>,<pitch deg>,<roll deg>*cs
--                       N,<home distance m>,<bearing to home deg>,<lat deg>,<lon deg>*cs
--                       M,<mode text>,<armed 0/1>,<flight time s>,<throttle %>*cs
--                       I,<simulator>,<aircraft>*cs
-- An empty field means the simulator has no such value (nothing is invented: there is no RSSI or link quality).
-- Lua 5.2 subset (EdgeTX). Original code for OpenRCsimulator; see tools/radio/edgetx/README.md.

local SENSOR_BASE = 0x5A00
local GROUPS = {
  B = { "volt", "curr", "mah", "pct" },
  A = { "alt", "vs", "gs", "as", "hdg", "pitch", "roll" },
  N = { "dist", "homeDir", "lat", "lon" },
  M = { "mode", "armed", "time", "thr" },
  I = { "name", "aircraft" },
}
-- value key, sensor id offset, name, EdgeTX unit, precision
local SENSORS = {
  { "volt", 1, "RxBt", 1, 2 }, { "curr", 2, "Curr", 2, 1 }, { "mah", 3, "Capa", 14, 0 }, { "pct", 4, "Bat%", 13, 0 },
  { "alt", 5, "Alt", 9, 1 }, { "vs", 6, "VSpd", 5, 1 }, { "gs", 7, "GSpd", 7, 1 }, { "as", 8, "ASpd", 7, 1 },
  { "hdg", 9, "Hdg", 20, 1 }, { "pitch", 10, "Ptch", 20, 1 }, { "roll", 11, "Roll", 20, 1 }, { "dist", 12, "Dist", 9, 0 },
}
local TEXT_KEYS = { mode = true, name = true, aircraft = true }

local st = { buf = "", lastRx = -100000, lastHello = -100000, lastSensors = -100000, lastGps = -100000,
  rateAt = 0, rx = 0, tx = 0 }
local state = { alive = false, values = {}, armed = nil, name = nil, aircraft = nil, txRate = 0, rxRate = 0, bad = 0 }

local function checksum(s)
  local sum = 0
  for i = 1, #s do sum = sum + string.byte(s, i) end
  return sum % 256
end

local function send(payload)
  serialWrite(payload .. string.format("*%02X\n", checksum(payload)))
end

local function fields(payload)
  local list, start = {}, 1
  while true do
    local comma = string.find(payload, ",", start, true)
    if not comma then list[#list + 1] = string.sub(payload, start); return list end
    list[#list + 1] = string.sub(payload, start, comma - 1)
    start = comma + 1
  end
end

local function handle(line, t)
  local payload, cs = string.match(line, "^(.-)%*(%x%x)$")
  if not payload or tonumber(cs, 16) ~= checksum(payload) then
    state.bad = state.bad + 1
    return
  end
  local f = fields(payload)
  local keys = GROUPS[f[1]]
  if not keys then return end
  for i = 1, #keys do
    local raw = f[i + 1]
    local key = keys[i]
    if raw == nil or raw == "" then
      if key == "armed" then state.armed = nil
      elseif key == "name" or key == "aircraft" then state[key] = nil
      else state.values[key] = nil end
    elseif key == "armed" then
      state.armed = raw == "1"
    elseif key == "name" or key == "aircraft" then
      state[key] = raw
    elseif TEXT_KEYS[key] then
      state.values[key] = raw
    else
      state.values[key] = tonumber(raw)
    end
  end
  st.lastRx = t
  st.rx = st.rx + 1
end

local function publish(t)
  if not setTelemetryValue then return end
  if t - st.lastSensors >= 20 then
    st.lastSensors = t
    for i = 1, #SENSORS do
      local s = SENSORS[i]
      local v = state.values[s[1]]
      if v then setTelemetryValue(SENSOR_BASE + s[2], 0, 0, math.floor(v * 10 ^ s[5] + 0.5), s[4], s[5], s[3]) end
    end
  end
  local lat, lon = state.values.lat, state.values.lon
  if lat and lon and t - st.lastGps >= 50 and UNIT_GPS then
    st.lastGps = t
    -- EdgeTX stores a Lua GPS sensor from its latitude and longitude parts (1e-6 degrees), then the GPS unit.
    setTelemetryValue(SENSOR_BASE + 20, 0, 0, math.floor(lat * 1000000 + 0.5), UNIT_GPS + 4, 0, "GPS")
    setTelemetryValue(SENSOR_BASE + 20, 0, 0, math.floor(lon * 1000000 + 0.5), UNIT_GPS + 3, 0, "GPS")
    setTelemetryValue(SENSOR_BASE + 20, 0, 0, 0, UNIT_GPS, 0, "GPS")
  end
end

local function poll()
  if not serialWrite or not serialRead then return state end
  local t = getTime()
  -- Channels out, every Lua cycle.
  local parts = { "C" }
  for ch = 0, 15 do
    local v = math.floor((getOutputValue(ch) or 0) + 1024.5)
    parts[#parts + 1] = string.format("%03X", math.max(0, math.min(2047, v)))
  end
  send(table.concat(parts))
  st.tx = st.tx + 1
  if t - st.lastHello >= 100 then
    st.lastHello = t
    local version, radio = getVersion()
    send("H," .. (radio or "radio") .. "," .. (version or ""))
  end
  -- Lines in.
  for _ = 1, 12 do
    local chunk = serialRead()
    if not chunk or chunk == "" then break end
    st.buf = st.buf .. chunk
  end
  while true do
    local nl = string.find(st.buf, "[\r\n]")
    if not nl then break end
    local line = string.sub(st.buf, 1, nl - 1)
    st.buf = string.sub(st.buf, nl + 1)
    if line ~= "" then handle(line, t) end
  end
  if #st.buf > 512 then st.buf = ""; state.bad = state.bad + 1 end
  if t - st.rateAt >= 100 then
    state.txRate, state.rxRate = st.tx * 100 / (t - st.rateAt), st.rx * 100 / (t - st.rateAt)
    st.tx, st.rx, st.rateAt = 0, 0, t
  end
  state.alive = t - st.lastRx < 100
  if state.alive then publish(t) end
  return state
end

return { poll = poll }
