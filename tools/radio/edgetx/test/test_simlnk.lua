-- Tests for SCRIPTS/TELEMETRY/simlnk.lua (the OpenRC simulator link) and its use by flight.lua.
-- Run from the repo root: lua tools/radio/edgetx/test/test_simlnk.lua
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local H = require("harness")
H.scripts = here .. "/.."
os.execute("mkdir -p '" .. H.root .. "/SCRIPTS/TELEMETRY'")

local function cs(payload)
  local sum = 0
  for i = 1, #payload do sum = sum + string.byte(payload, i) end
  return string.format("%s*%02X\n", payload, sum % 256)
end

local function outputs()
  local o = {}
  for i = 1, 16 do o[i] = 0 end
  o[1], o[2], o[3], o[5], o[9] = -1024, 1024, 512, 1500, 1024
  return o
end

-- 1. Frames out.
H.reset({ outputs = outputs() })
local link = H.load("/SCRIPTS/TELEMETRY/simlnk.lua")
H.t = 1000
local state = link.poll()
local c = H.serialOut[1] or ""
H.check("C frame: CH1 -1024 -> 000, CH2 +1024 -> 7FF (clamped), CH3 512 -> 600, CH5 over range -> 7FF, CH9 on",
  c:sub(1, 16) == "C0007FF600400" .. "7FF" and c:sub(26, 28) == "7FF", c)
H.check("C frame: 16 channels and a valid checksum", #c == 1 + 48 + 4 and c == cs(c:sub(1, 49)), c)
H.check("hello once a second", H.serialOut[2] == cs("H,zorro,2.12.5"), H.serialOut[2])
H.t = 1050; link.poll()
H.check("no second hello within the second", #H.serialOut == 3)
H.check("not alive before the simulator speaks", state.alive == false)

-- 2. Lines in: split across reads, bad checksum, empty fields.
H.serialIn = cs("B,16.40,12.5,734,62") .. cs("A,124.5,1.4,54.0,61.2,52,7.0,-20.0") .. "A,1,2,3*00\n" .. cs("N,612,190.5,46.1966067,-14.5833153")
  .. cs("M,ANGL,1,93,48") .. cs("I,OpenRC,Jensen Ugly Stik") .. string.sub(cs("B,15.10,,,"), 1, 6)
H.t = 1100
state = link.poll()
local v = state.values
H.check("B: volts, amps, mAh, %", v.volt == 16.4 and v.curr == 12.5 and v.mah == 734 and v.pct == 62)
H.check("A: altitude, speeds, heading, attitude", v.alt == 124.5 and v.vs == 1.4 and v.gs == 54 and v.as == 61.2
  and v.hdg == 52 and v.pitch == 7 and v.roll == -20)
H.check("N: home and position", v.dist == 612 and v.homeDir == 190.5 and v.lat == 46.1966067 and v.lon == -14.5833153)
H.check("M: mode and armed", v.mode == "ANGL" and state.armed == true)
H.check("I: simulator and aircraft", state.name == "OpenRC" and state.aircraft == "Jensen Ugly Stik")
H.check("a line with a bad checksum is counted and ignored", state.bad == 1 and v.alt == 124.5, state.bad)
H.check("alive after valid lines", state.alive == true)
H.serialIn = string.sub(cs("B,15.10,,,"), 7)
H.t = 1110
state = link.poll()
H.check("a line split across reads is joined; empty fields clear the value", v.volt == 15.1 and v.curr == nil and v.mah == nil,
  tostring(v.volt) .. " " .. tostring(v.curr))

-- 3. Sensors published for EdgeTX.
local tm = H.telemetry
H.check("sensors: RxBt 16.40 V (prec 2), Alt 124.5 m, Hdg 52 (published at most 5 times a second)", tm.RxBt and tm.RxBt.raw == 1640 and tm.RxBt.prec == 2
  and tm.Alt and tm.Alt.raw == 1245 and tm.Hdg and tm.Hdg.raw == 520)
H.check("sensors: no Curr or Capa when the simulator has none", tm.Curr == nil or tm.Curr.raw == 125)
H.check("sensors: no link quality or RSSI is ever created", tm.RQly == nil and tm.RSSI == nil and tm["1RSS"] == nil)
H.check("GPS sensor ends with the GPS unit (lat/lon parts first)", tm.GPS and tm.GPS.unit == UNIT_GPS)
-- The radio's floats keep ~7 digits, so the position is parsed from the text as whole 1e-6 degrees, rounded.
H.check("GPS: exact 1e-6 degrees from the text, rounded, sign kept", tm.GPS and tm.GPS.lat == 46196607 and tm.GPS.lon == -14583315
  and math.type(tm.GPS.lat) == "integer", tostring(tm.GPS and tm.GPS.lat) .. " " .. tostring(tm.GPS and tm.GPS.lon))

-- 4. Timeout.
H.t = 1300
state = link.poll()
H.check("link drops after 1 s without lines", state.alive == false)

-- 5. flight.lua on the simulator link: protocol SIM, values, arming and mode callouts from the simulator.
local phase = 0
H.reset({ model = "SIM", rssi = 0 })
local flight = H.load("/SCRIPTS/TELEMETRY/flight.lua")
flight.init()
local function feed(mode, armed)
  H.serialIn = H.serialIn .. cs("B,16.20,10.0,500,70") .. cs("A,80,0.5,60,65,270,3,10") .. cs("N,300,90,,")
    .. cs("M," .. mode .. "," .. armed .. ",10,40")
end
local cycles = 350
for i = 1, cycles do
  feed(i < 50 and "OK" or (i < 100 and "ACRO" or "RTH"), i < 50 and 0 or 1)
  H.tick(flight, 1, nil, i % 2 == 0)
end
local texts = H.texts()
H.check("flight + SIM: protocol, mode, volts, altitude, home", texts:find("SIM", 1, true) and texts:find("RTH", 1, true)
  and texts:find("16.2", 1, true) and texts:find("80", 1, true) and texts:find("H300", 1, true), texts)
local played = table.concat(H.played, ",")
H.check("flight + SIM: armed from the simulator; ACRO and RTH announced", played == "armed.wav,acro.wav,rth.wav", played)
H.check("flight + SIM: no 'lost' or 'no telemetry' while the link is up", not texts:find("lost", 1, true) and not texts:find("No telemetry", 1, true), texts)
H.check("flight + SIM: every draw on screen", #H.oob == 0, table.concat(H.oob, "; "))
H.tick(flight, 1, EVT_VIRTUAL_NEXT, true)
H.check("flight + SIM: link page names the simulator and its rates", H.texts():find("Simulator", 1, true)
  and H.texts():find("No RF link", 1, true), H.texts())
local sent = 0
for _, s in ipairs(H.serialOut) do if s:sub(1, 1) == "C" then sent = sent + 1 end end
H.check("flight + SIM: one channel frame per Lua cycle", sent == cycles + 1, sent)

print(H.failures == 0 and "all simlnk.lua checks passed" or (H.failures .. " simlnk.lua check(s) failed"))
os.exit(H.failures == 0 and 0 or 1)
