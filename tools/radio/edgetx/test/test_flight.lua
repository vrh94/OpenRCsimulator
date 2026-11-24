-- Tests for SCRIPTS/TELEMETRY/flight.lua against the mock EdgeTX API (harness.lua).
-- Run from the repo root: lua tools/radio/edgetx/test/test_flight.lua [SOUNDS/en folder to check voice files against]
local here = string.match(arg[0], "^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local H = require("harness")
H.scripts = here .. "/.."
local soundsDir = arg[1]
os.execute("mkdir -p '" .. H.root .. "/SCRIPTS/TELEMETRY'")
os.remove(H.root .. "/SCRIPTS/TELEMETRY/flight.cfg")

local played_all = {}

local function run(name, scenario, steps)
  H.reset(scenario)
  local script = H.load("/SCRIPTS/TELEMETRY/flight.lua")
  script.init()
  local ok, err = pcall(steps, script)
  H.check(name .. ": runs without errors", ok, err)
  H.check(name .. ": every draw stays on the 128x64 screen, with integer coordinates", #H.oob == 0, table.concat(H.oob, "; "))
  H.check(name .. ": no graphic relies on XOR (1-bit screen)", #H.xor == 0, table.concat(H.xor, "; "))
  for _, f in ipairs(H.played) do played_all[f] = true end
  return script
end

local function count(list, value)
  local n = 0
  for _, v in ipairs(list) do if v == value then n = n + 1 end end
  return n
end

-- The horizon frame (33,9 62x46) is intact and the aircraft symbol has its white outline.
local function hudShape(name)
  local broken = {}
  for x = 33, 94 do
    if not H.pixel(x, 9) or not H.pixel(x, 54) then broken[#broken + 1] = x end
  end
  for y = 9, 54 do
    if not H.pixel(33, y) or not H.pixel(94, y) then broken[#broken + 1] = "y" .. y end
  end
  H.check(name .. ": horizon frame intact", #broken == 0, table.concat(broken, ",") .. "\n" .. H.art())
  local cx, cy = 64, 32
  local wing, halo = true, true
  for x = cx - 10, cx - 4 do wing = wing and H.pixel(x, cy) and H.pixel(x + 14, cy) end
  for x = cx - 11, cx - 3 do halo = halo and not H.pixel(x, cy - 1) and not H.pixel(x + 14, cy - 1) end
  H.check(name .. ": aircraft symbol drawn with a white outline", wing and halo, "\n" .. H.art())
end

local function pages(script)
  local texts = {}
  for p = 1, 3 do
    H.tick(script, 1, nil, true)
    texts[p] = H.texts()
    if p == 1 then hudShape("  HUD") end
    local hits = H.overlaps()
    H.check("  page " .. p .. " text does not overlap", #hits == 0, table.concat(hits, ", "))
    H.tick(script, 1, EVT_VIRTUAL_NEXT, true)
  end
  return texts
end

-- 1. ELRS with iNav: arm in ANGL, RTH, disarm. GPS moves 300 m north.
local function phase(t, a, b, c, d) if t < 300 then return a elseif t < 600 then return b elseif t < 900 then return c end return d end
local elrs = {
  rssi = 1,
  sensors = {
    RQly = { id = 1, unit = 13, value = 100 }, ["1RSS"] = { id = 2, unit = 29, value = -61 },
    ["2RSS"] = { id = 3, unit = 29, value = -64 }, RSNR = { id = 4, unit = 17, value = 9 },
    RFMD = { id = 5, unit = 0, value = 7 }, TPWR = { id = 6, unit = 16, value = 100 },
    RxBt = { id = 7, unit = 1, value = 16.4 }, Curr = { id = 8, unit = 2, value = 12.5 },
    Capa = { id = 9, unit = 14, value = function(t) return t / 10 end }, ["Bat%"] = { id = 10, unit = 13, value = 88 },
    FM = { id = 11, unit = 42, value = function(t) return phase(t, "OK", "ANGL", "RTH", "OK") end },
    GPS = { id = 12, unit = 40, value = function(t) return { lat = 46.1970 + t * 3e-6, lon = 14.5810 } end },
    GSpd = { id = 13, unit = 7, value = 54 }, Alt = { id = 14, unit = 9, value = 120 },
    Hdg = { id = 15, unit = 20, value = 10 }, Sats = { id = 16, unit = 0, value = 14 },
    Ptch = { id = 17, unit = 21, value = 0.1 }, Roll = { id = 18, unit = 21, value = -0.3 },
  },
}
run("ELRS + iNav", elrs, function(s)
  H.tick(s, 50, nil, false)
  H.check("ELRS: disarmed while FM says OK", count(H.played, "armed.wav") == 0)
  H.tick(s, 70, nil, false) -- t = 360
  H.check("ELRS: ANGL arms (armed.wav once)", count(H.played, "armed.wav") == 1, table.concat(H.played, ","))
  H.tick(s, 120, nil, false) -- t = 720
  H.check("ELRS: RTH is announced", count(H.played, "rth.wav") == 1, table.concat(H.played, ","))
  H.tick(s, 1, nil, true)
  local texts = H.texts()
  H.check("ELRS HUD: mode, LQ, volts, home distance", texts:find("RTH", 1, true) and texts:find("LQ100", 1, true)
    and texts:find("16.4", 1, true) and texts:find("H%d"), texts)
  H.tick(s, 100, nil, false) -- t = 1020
  H.check("ELRS: disarm on OK", count(H.played, "disarm.wav") == 1, table.concat(H.played, ","))
  H.tick(s, 1, nil, true)
  local cols = 0
  for x = 34, 93 do
    for y = 10, 53 do
      -- a horizon pixel: set, with a set neighbour along the line, outside the symbol and the heading box
      if H.pixel(x, y) and (H.pixel(x - 1, y) or H.pixel(x - 1, y - 1) or H.pixel(x - 1, y + 1))
        and not (y >= 10 and y <= 18) and not (x >= 52 and x <= 76 and y >= 29 and y <= 36) then cols = cols + 1; break end
    end
  end
  H.check("ELRS: horizon line is continuous on the 1-bit screen (>= 40 of 60 columns)", cols >= 40, cols .. "\n" .. H.art())
  local t = pages(s)
  H.check("ELRS link page shows both antennas", t[2]:find("-61/-64dBm", 1, true), t[2])
end)

-- 2. ELRS with Betaflight: "*" suffix means disarmed.
local bf = { rssi = 1, sensors = {
  RQly = { id = 1, unit = 13, value = 99 }, RxBt = { id = 7, unit = 1, value = 25.1 },
  FM = { id = 11, unit = 42, value = function(t) return phase(t, "ACRO*", "ACRO", "ANGL", "ANGL*") end } } }
run("ELRS + Betaflight", bf, function(s)
  H.tick(s, 400, nil, false)
  H.check("BF: ACRO without * is armed", count(H.played, "armed.wav") == 1, table.concat(H.played, ","))
  H.tick(s, 300, nil, true)
  H.check("BF: 6S detected from 25.1 V (4.18 V/cell)", H.texts():find("4.18v", 1, true), H.texts())
  H.check("BF HUD: mode shown without the star", H.texts():find("ANGL", 1, true) and not H.texts():find("*", 1, true), H.texts())
end)

-- 3. FrSky D16 with iNav (INAV 8+ ids, and legacy Tmp1/Tmp2).
for _, ids in ipairs({ { "470", "480" }, { "Tmp1", "Tmp2" } }) do
  local d16 = { rssi = 1, sensors = {
    RSSI = { id = 1, unit = 17, value = 82 }, RxBt = { id = 2, unit = 1, value = 5.1 },
    VFAS = { id = 3, unit = 1, value = 12.3 }, Curr = { id = 4, unit = 2, value = 8 },
    Fuel = { id = 5, unit = 14, value = 450 }, Alt = { id = 6, unit = 9, value = 55 },
    VSpd = { id = 7, unit = 5, value = 1.5 }, GSpd = { id = 8, unit = 4, value = 20 },
    [ids[1]] = { id = 9, unit = 0, value = function(t) return phase(t, 1, 14, 1014, 1) end },
    [ids[2]] = { id = 10, unit = 0, value = 3912 }, ["0420"] = { id = 11, unit = 9, value = 230 } } }
  run("D16 + iNav " .. ids[1], d16, function(s)
    H.tick(s, 120, nil, false)
    H.check(ids[1] .. ": 14 (armed, angle) arms", count(H.played, "armed.wav") == 1, table.concat(H.played, ","))
    H.tick(s, 150, nil, true)
    local texts = H.texts()
    H.check(ids[1] .. ": RTH decoded from 1014", texts:find("RTH", 1, true), texts)
    H.check(ids[1] .. ": GS in km/h from knots (37)", texts:find("GS37", 1, true), texts)
    H.check(ids[1] .. ": 3S cell 4.10 V, 450 mAh, home 230 m", texts:find("4.10v", 1, true) and texts:find("450mAh", 1, true)
      and texts:find("H230", 1, true), texts)
    local p = pages(s)
    H.check(ids[1] .. ": sats 12 with home fix from 3912", p[2]:find("12 fix", 1, true), p[2])
  end)
end

-- 4. FrSky D8: RSSI, A1, A2 only; arming falls back to throttle.
local d8 = { rssi = 1, sources = { thr = function(t) return t > 400 and 0 or -1024 end }, sensors = {
  RSSI = { id = 1, unit = 17, value = 70 }, A1 = { id = 2, unit = 1, value = 5.0 }, A2 = { id = 3, unit = 1, value = 11.8 } } }
run("D8", d8, function(s)
  H.tick(s, 100, nil, false)
  H.check("D8: throttle low keeps it disarmed", count(H.played, "armed.wav") == 0)
  H.tick(s, 100, nil, true)
  H.check("D8: throttle above 5 % arms", count(H.played, "armed.wav") == 1, table.concat(H.played, ","))
  H.check("D8: A2 is the flight battery, R70 shown", H.texts():find("11.8", 1, true) and H.texts():find("R70", 1, true), H.texts())
  local t = pages(s)
  H.check("D8: link page labels the protocol", t[2]:find("LINK D8", 1, true), t[2])
end)

-- 5. No telemetry (the SIM model without the simulator link): timer runs from the throttle.
local none = { rssi = 0, sources = { thr = function(t) return t > 30 and 200 or -1024 end } }
run("No telemetry", none, function(s)
  H.tick(s, 400, nil, true) -- ~11.1 s armed
  local texts = H.texts()
  H.check("No telemetry: says so and draws no values", texts:find("No telemetry", 1, true) and texts:find("%-%-"), texts)
  H.check("No telemetry: flight timer counts armed time (00:11)", texts:find("00:11", 1, true), texts)
  pages(s)
end)

-- 6. Low and critical battery (4S).
local low = { rssi = 1, sensors = { RQly = { id = 1, unit = 13, value = 100 },
  RxBt = { id = 2, unit = 1, value = function(t) return t < 300 and 14.2 or 12.8 end } } }
run("Low battery", low, function(s)
  H.tick(s, 80, nil, false)
  H.check("Battery: 3.55 V/cell is not low yet", count(H.played, "lowbat.wav") == 0, table.concat(H.played, ","))
  H.tick(s, 150, nil, false)
  H.check("Battery: 3.20 V/cell is critical: voice and haptic", count(H.played, "lowbat.wav") >= 1 and H.haptics >= 1)
  local n = count(H.played, "lowbat.wav")
  H.tick(s, 200, nil, false)
  H.check("Battery: repeats are rate limited (<= 1 per 10 s)", count(H.played, "lowbat.wav") - n <= 1)
end)

-- 7. Telemetry lost, and low LQ.
local lost = { rssi = function(t) return t < 300 and 1 or 0 end, sensors = { RQly = { id = 1, unit = 13, value = 60 },
  RxBt = { id = 2, unit = 1, value = 16.6 } } }
run("Link", lost, function(s)
  H.tick(s, 50, nil, false)
  H.check("Link: LQ 60 < 70 warns (siglow)", count(H.played, "siglow.wav") == 1, table.concat(H.played, ","))
  H.tick(s, 100, nil, true)
  H.check("Link: lost telemetry is shown", H.texts():find("Telemetry lost", 1, true), H.texts())
end)

-- 8. Settings menu and per-model persistence.
run("Menu", { model = "Plane1", rssi = 0 }, function(s)
  H.tick(s, 1, EVT_VIRTUAL_ENTER, true)
  H.check("Menu: ENTER opens settings", H.texts():find("Screen settings", 1, true), H.texts())
  H.tick(s, 1, EVT_VIRTUAL_ENTER, true)       -- edit Cells
  H.tick(s, 1, EVT_VIRTUAL_NEXT, true)        -- 1S
  H.tick(s, 1, EVT_VIRTUAL_NEXT, true)        -- 2S
  H.tick(s, 1, EVT_VIRTUAL_NEXT, true)        -- 3S
  H.tick(s, 1, EVT_VIRTUAL_EXIT, true)        -- stop editing
  for _ = 1, 4 do H.tick(s, 1, EVT_VIRTUAL_NEXT, true) end -- to "Arming"
  H.tick(s, 1, EVT_VIRTUAL_ENTER, true)
  H.tick(s, 1, EVT_VIRTUAL_NEXT, true)        -- SA down
  H.tick(s, 1, EVT_VIRTUAL_EXIT, true)
  H.check("Menu: arming shows SA down", H.texts():find("SA down", 1, true), H.texts())
  H.tick(s, 1, EVT_VIRTUAL_EXIT, true)        -- leave and save
  H.check("Menu: EXIT returns to the HUD", not H.texts():find("Screen settings", 1, true), H.texts())
end)
local f = H.realIo.open(H.root .. "/SCRIPTS/TELEMETRY/flight.cfg", "rb")
local saved = f and f:read("a") or ""
if f then f:close() end
H.check("Menu: settings saved per model", saved:find("Plane1|3,350,330,1,1,1,70,45", 1, true), saved)
run("Menu reload", { model = "Plane1", rssi = 0, sources = { sa = 1024 } }, function(s)
  H.tick(s, 20, nil, true)
  H.check("Menu reload: SA down arms after reloading the saved setting", count(H.played, "armed.wav") == 1,
    table.concat(H.played, ","))
end)

-- 9. Stats reset with long ENTER on the stats page.
run("Stats", elrs, function(s)
  H.tick(s, 400, nil, false)
  H.tick(s, 1, EVT_VIRTUAL_NEXT, true)
  H.tick(s, 1, EVT_VIRTUAL_NEXT, true)
  H.check("Stats: max altitude recorded", H.texts():find("120m", 1, true), H.texts())
  H.tick(s, 1, EVT_VIRTUAL_ENTER_LONG, true)
  H.tick(s, 1, nil, true)
  H.check("Stats: reset message", H.texts():find("Stats reset", 1, true), H.texts())
end)

if soundsDir then
  for file in pairs(played_all) do
    local fh = H.realIo.open(soundsDir .. "/" .. file, "rb")
    H.check("voice file exists: " .. file, fh ~= nil)
    if fh then fh:close() end
  end
end

print(H.failures == 0 and "all flight.lua checks passed" or (H.failures .. " flight.lua check(s) failed"))
os.exit(H.failures == 0 and 0 or 1)
