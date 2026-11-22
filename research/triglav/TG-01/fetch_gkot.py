#!/usr/bin/env python3
"""TG-01b: download the GURS CLSS 2023-25 classified point clouds (GKOT) of the Triglav core through the public viewer.

The Surveying and Mapping Authority's viewer (https://clss.si/, "Pregledovalnik 3D podatkov") offers each 1 km sheet's
products from a popup: draw an area on the 2D map in download mode, and the popup links GKOT, DMR, DMP, nDMP, PAS,
POF and POFI for that sheet. This script does what a person would, one sheet at a time, with a headless browser:
it opens the viewer, searches for Rateče, zooms out to the sheet grid, enters download mode, and for each sheet of
E 399-406 x N 144-151 km draws a tiny triangle at the sheet's centre, checks that the popup names that sheet and
clicks its GKOT link. The viewer pans whenever a popup opens; screenshots before and after each read measure the pan
(phase correlation), so sheet positions stay known in map coordinates. Downloads are sequential.

Files go to tmp/triglav/gkot/ (not committed); fetch_log.json there records each file's URL, size and SHA-256, and
`--record` copies those pins into research/triglav/sources.json (`clss_gkot`). Resumable: present files are skipped.

    tmp/triglav/venv/bin/python research/triglav/TG-01/fetch_gkot.py            # download what is missing
    tmp/triglav/venv/bin/python research/triglav/TG-01/fetch_gkot.py --record   # pin the downloaded files

Needs Playwright with Chromium, numpy and Pillow in the venv:
    python3 -m venv tmp/triglav/venv && tmp/triglav/venv/bin/pip install playwright numpy pillow "laspy[lazrs]"
    tmp/triglav/venv/bin/python -m playwright install chromium

Terms: GURS geodetic data are CC BY 4.0 (https://www.e-prostor.gov.si/en/access-to-geodetic-data/); credit the
Surveying and Mapping Authority of the Republic of Slovenia, the data type and its date.
"""
import asyncio
import hashlib
import json
import re
import sys
import time
from pathlib import Path

from playwright.async_api import async_playwright

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import region as regions  # noqa: E402

R = regions.select()
OUT = R["cache"] / "gkot"
SOURCES = R["sources"]

SCALE_IS_2KM = """() => Array.from(document.querySelectorAll('*')).some(e => e.childElementCount === 0
  && (e.innerText || '').trim() === '2 km')"""


async def open_viewer(p):
    b = await p.chromium.launch()
    pg = await b.new_page(viewport={"width": 1600, "height": 1000}, accept_downloads=True)
    await pg.goto("https://clss.si/", wait_until="networkidle", timeout=90000)
    await pg.wait_for_timeout(3000)
    fr = [f for f in pg.frames if "lift.clss.si/#" in f.url][0]
    box = fr.get_by_placeholder("Napišite naslov")
    await box.click(); await box.type(R["clss_search"], delay=120); await pg.wait_for_timeout(3000)
    if R.get("clss_pick"):
        await fr.get_by_text(R["clss_pick"]).first.click()
    else:
        await box.press("Enter")
    await pg.wait_for_timeout(4000)
    await pg.mouse.move(400, 520)
    if R.get("clss_pick"):
        # A picked address opens at street scale: zoom out about the pin until the sheet-grid scale (2 km bar).
        for i in range(40):
            if await fr.evaluate(SCALE_IS_2KM):
                break
            await pg.mouse.wheel(0, 120); await pg.wait_for_timeout(700)
    else:
        for i in range(10):
            await pg.mouse.wheel(0, 400); await pg.wait_for_timeout(500)
    await pg.wait_for_timeout(2500)
    await pg.mouse.click(29, 121)      # download mode
    await pg.wait_for_timeout(2500)
    return b, pg, fr


async def draw(pg, pts):
    for x, y in pts[:-1]:
        await pg.mouse.click(x, y); await pg.wait_for_timeout(350)
    await pg.mouse.dblclick(*pts[-1]); await pg.wait_for_timeout(2500)

async def panel_text(fr):
    return await fr.evaluate("() => document.body.innerText")

LOG = OUT / "fetch_log.json"
SHEETS = regions.sheets(R)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def say(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


VISIBLE_POPUP = """() => Array.from(document.querySelectorAll('.popup-renderer')).filter(e => {
  const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden'; })"""


async def close_popup(fr, pg):
    closed = await fr.evaluate(f"""() => {{ let n = 0; for (const p of ({VISIBLE_POPUP})()) {{
        const b = p.querySelector('.fc-close'); if (b) {{ (b.closest('button') || b).click(); n++; }} }} return n; }}""")
    if closed:
        await pg.wait_for_timeout(600)
    still = await fr.evaluate(f"() => ({VISIBLE_POPUP})().length")
    if still:
        raise RuntimeError("the sheet popup did not close")


async def read_sheet(pg, fr, x, y):
    await close_popup(fr, pg)
    await draw(pg, [(x, y), (x + 3, y), (x + 3, y + 3)])
    text = await fr.evaluate(f"() => ({VISIBLE_POPUP})().map(p => p.innerText).join('\\n')")
    names = re.findall(r"Ime kvadranta\s+(\d{3})_(\d{3})", text)
    return (int(names[-1][0]), int(names[-1][1])) if names else None


CLIP = {"x": 320, "y": 140, "width": 460, "height": 840}   # inside the 2D map pane, below the search box
SAFE = (360, 180, 740, 900)                                # where a click's popup cannot hide the next target


async def grab(pg):
    import io
    import numpy as np
    from PIL import Image
    await pg.wait_for_timeout(900)
    png = await pg.screenshot(clip=CLIP)
    return np.asarray(Image.open(io.BytesIO(png)).convert("L"), dtype=np.float64)


def shift_between(a, b):
    """Translation d (pixels, x and y) with b(p) ~ a(p - d), by phase correlation."""
    import numpy as np
    wy = np.hanning(a.shape[0])[:, None]; wx = np.hanning(a.shape[1])[None, :]
    fa = np.fft.fft2((a - a.mean()) * wy * wx); fb = np.fft.fft2((b - b.mean()) * wy * wx)
    r = fb * np.conj(fa); r /= np.abs(r) + 1e-9
    c = np.real(np.fft.ifft2(r))
    iy, ix = np.unravel_index(np.argmax(c), c.shape)
    dy = iy - a.shape[0] if iy > a.shape[0] // 2 else iy
    dx = ix - a.shape[1] if ix > a.shape[1] // 2 else ix
    return float(dx), float(dy)


class Tracker:
    """Map coordinates m = screen pixel - offset; offset follows every pan the viewer makes."""
    def __init__(self, pg, fr):
        self.pg, self.fr, self.off = pg, fr, [0.0, 0.0]
        self.ref = None

    async def settle(self):
        await close_popup(self.fr, self.pg)
        img = await grab(self.pg)
        if self.ref is not None:
            dx, dy = shift_between(self.ref, img)
            self.off[0] += dx; self.off[1] += dy
        self.ref = img

    async def bring_into_view(self, mx, my):
        for _ in range(6):
            x, y = mx + self.off[0], my + self.off[1]
            if SAFE[0] <= x <= SAFE[2] and SAFE[1] <= y <= SAFE[3]:
                return x, y
            cx, cy = (SAFE[0] + SAFE[2]) / 2, (SAFE[1] + SAFE[3]) / 2
            dx = max(-150, min(150, cx - x)); dy = max(-150, min(150, cy - y))
            await self.pg.mouse.move(cx, cy); await self.pg.mouse.down()
            await self.pg.mouse.move(cx + dx / 2, cy + dy / 2, steps=8)
            await self.pg.mouse.move(cx + dx, cy + dy, steps=8); await self.pg.mouse.up()
            await self.settle()
        raise RuntimeError(f"could not bring map point ({mx:.0f}, {my:.0f}) into view; offset {self.off}")

    async def read(self, mx, my):
        x, y = await self.bring_into_view(mx, my)
        got = await read_sheet(self.pg, self.fr, round(x), round(y))
        await self.settle()
        return got


async def scale_px_per_km(fr):
    w = await fr.evaluate("""() => { const e = Array.from(document.querySelectorAll('*')).find(e => e.childElementCount === 0 && (e.innerText||'').trim() === '2 km');
      if (!e) return null; let p = e; for (let i = 0; i < 3 && p; i++) { const r = p.getBoundingClientRect(); if (r.width > 60) return r.width; p = p.parentElement; } return null; }""")
    return (w / 2.0) if w and 60 < w < 140 else 47.5



def record() -> int:
    log = json.loads(LOG.read_text())
    pins = json.loads(SOURCES.read_text())
    entries = []
    for e, n in SHEETS:
        item = log.get(f"{e}_{n}")
        if item is None:
            print(f"FAIL: sheet {e}_{n} has not been fetched", file=sys.stderr)
            return 1
        entries.append({"sheet": f"{e}_{n}", **item})
    pins["clss_gkot"] = entries
    credit = ("Cyclic laser scanning of Slovenia 2023-2025 (CLSS), classified point cloud GKOT: Surveying and Mapping "
              "Authority of the Republic of Slovenia (GURS), CC BY 4.0")
    if credit not in pins["attribution"]:
        pins["attribution"].append(credit)
    SOURCES.write_text(json.dumps(pins, indent=1) + "\n")
    print(f"pinned {sum(1 for x in entries if 'sha256' in x)} GKOT sheets "
          f"({sum(1 for x in entries if 'absent' in x)} absent) in {SOURCES.relative_to(REPO)}")
    return 0


async def main():
    OUT.mkdir(parents=True, exist_ok=True)
    log = json.loads(LOG.read_text()) if LOG.exists() else {}
    for e, n in SHEETS:  # files already present (downloaded by hand) are recorded, not fetched again
        key, path = f"{e}_{n}", OUT / f"GKOT_{e}_{n}.laz"
        if path.exists() and key not in log:
            log[key] = {"name": path.name, "url": f"(manual download) GKOT_{key}.laz", "bytes": path.stat().st_size,
                        "sha256": sha256(path), "fetched": time.strftime("%Y-%m-%d")}
    LOG.write_text(json.dumps(log, indent=1))
    todo = [s for s in SHEETS if f"{s[0]}_{s[1]}" not in log or "sha256" not in log[f"{s[0]}_{s[1]}"]]
    todo = [s for s in todo if log.get(f"{s[0]}_{s[1]}", {}).get("absent") is None]
    if R.get("fetch_first"):
        fe, fn = R["fetch_first"]
        todo.sort(key=lambda s: max(abs(s[0] - fe), abs(s[1] - fn)))
    say(f"{len(todo)} sheets to fetch")
    if not todo:
        return 0
    async with async_playwright() as p:
        b, pg, fr = await open_viewer(p)
        s = await scale_px_per_km(fr)
        import numpy as np
        test = np.random.default_rng(1).random((200, 300))
        assert shift_between(test, np.roll(np.roll(test, 7, axis=1), -5, axis=0)) == (7.0, -5.0), "phase correlation sign"
        tr = Tracker(pg, fr)
        await tr.settle()
        mx0, my0 = 550.0, 500.0
        first = await tr.read(mx0, my0)
        say(f"first read {first}; offset {tr.off}")
        e0, n0 = first
        bx = by = None
        for k in range(1, 14):
            r = await tr.read(mx0 + 4 * k, my0)
            say(f"  probe x+{4 * k}: {r}; offset {[round(v) for v in tr.off]}")
            if r and r[0] != e0:
                bx = mx0 + 4 * k - 2; break
        for k in range(1, 14):
            r = await tr.read(mx0, my0 + 4 * k)
            say(f"  probe y+{4 * k}: {r}; offset {[round(v) for v in tr.off]}")
            if r and r[1] != n0:
                by = my0 + 4 * k - 2; break
        say(f"scale {s:.2f} px/km; sheet {e0}_{n0}; east edge map x={bx}, south edge map y={by}")
        if bx is None or by is None:
            await pg.screenshot(path=str(OUT / "calibration_failed.png"))
            return 1

        def centre(e, n):
            return bx + (e - e0 - 1) * s + s / 2, by + (n0 - 1 - n) * s + s / 2

        for e, n in todo:
            key = f"{e}_{n}"
            target = OUT / f"GKOT_{key}.laz"
            x, y = centre(e, n)
            got = None
            for attempt in range(4):
                got = await tr.read(x, y)
                if got == (e, n):
                    break
                if got is None:
                    break
                x += (e - got[0]) * s
                y -= (n - got[1]) * s
            if got != (e, n):
                if got is not None:
                    say(f"{key}: still reading {got} after corrections; stopping")
                    await pg.screenshot(path=str(OUT / "navigation_failed.png"))
                    return 1
                say(f"{key}: no sheet here (popup said {got}); recorded absent")
                log[key] = {"absent": f"the viewer shows no CLSS sheet at this position (got {got})"}
                LOG.write_text(json.dumps(log, indent=1))
                continue
            px, py = await tr.bring_into_view(x, y)
            if await read_sheet(pg, fr, round(px), round(py)) != (e, n):
                say(f"{key}: popup changed before the download; stopping"); return 1
            link = fr.locator(f'.popup-renderer a[href$="/GKOT_{key}.laz"]')
            if not await link.count():
                say(f"{key}: popup has no GKOT link; recorded absent")
                log[key] = {"absent": "the popup lists no GKOT product"}
                LOG.write_text(json.dumps(log, indent=1))
                continue
            href = await link.first.get_attribute("href")
            label = (await link.first.inner_text()).strip()
            say(f"{key}: downloading {label}")
            t0 = time.time()
            async with pg.expect_download(timeout=0) as info:
                await link.first.click()
            dl = await info.value
            part = target.with_suffix(".laz.part")
            await dl.save_as(str(part))
            await dl.delete()
            part.rename(target)
            size = target.stat().st_size
            log[key] = {"name": target.name, "url": href, "bytes": size, "sha256": sha256(target),
                        "fetched": time.strftime("%Y-%m-%d")}
            LOG.write_text(json.dumps(log, indent=1))
            say(f"{key}: {size / 1e6:.1f} MB in {time.time() - t0:.0f} s")
            await tr.settle()
        await b.close()
    return 0


sys.exit(record() if "--record" in sys.argv[1:] else asyncio.run(main()))
