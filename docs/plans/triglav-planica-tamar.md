# Step 21: Triglav National Park landscape, Planica and Tamar (plan)

Owner decisions of 2026-11-17: a landscape of Triglavski narodni park, solid real terrain (ground contact follows the
elevation model; this is a terrain change, not a flight-model change), centred on the Planica/Tamar valley. Status:
**in progress**: TG-01 to TG-06 done ([research/triglav](../../research/triglav/README.md),
`app/landscapes/triglav_tamar/`, `app/physics/terrain_dem.gd`); the landscape is in the catalog with solid terrain for
airplanes, helicopters, multirotors, the blimp and the RC trucks. Open: TG-07 (trees and buildings are not solid yet)
and the 1080p frame-time captures of TG-08. Steps are 21a (data and visuals) and 21b (solid terrain contact).

## Owner decisions (2026-11-18)

- Triglav before the mod folder (step 20 follows).
- Playable core **8 × 8 km at 2 m**: the Tamar meadow, the Planica valley to Rateče and the ridges either side.
- Ground look from the **real aerial orthophoto** (2023–25 survey). Its licence is checked before a public release,
  with procedural shading as the fallback.
- **RC trucks drive the Triglav terrain too** (in 21b).
- The photo, trees, buildings and newer bare earth come from the GURS 2023–25 **classified point cloud (GKOT)**,
  all 64 sheets of the core, fetched through the public viewer with a headless browser (owner request, 2026-11-18).

## The place

The Tamar meadow and the Dom v Tamarju hut (1108 m) lie at the head of the Planica valley, inside the park, under
Jalovec (2645 m), Mojstrovka and the Ponce ridge on the Italian border about 2 km west. The Planica Nordic Centre with
the ski-flying hills is 3.5 km north down the valley, and Rateče is at its mouth, 5.7 km north.

| Point | WGS84 | D96/TM (EPSG:3794) E, N | LiDAR 1 m tile |
| --- | --- | --- | --- |
| Dom v Tamarju | 46.44605 N, 13.71341 E | 401150, 145956 | `TM1_401_145` |
| Planica Nordic Centre (approximate) | 46.479 N, 13.721 E | 401793, 149610 | `TM1_401_149` |
| Rateče | 46.4975 N, 13.7125 E | 401174, 151676 | `TM1_401_151` |
| Jalovec summit | 46.4211 N, 13.6797 E | 398514, 143226 | `TM1_398_143` |

The coordinates come from a GRS80 transverse-Mercator conversion (central meridian 15° E, k0 0.9999, false easting
500 km, false northing −5000 km). The data checks the hut: the LiDAR tile gives **1108.1 m** at its coordinates.

## Data sources (checked 2026-11-18)

| Use | Source | Access | Licence and attribution |
| --- | --- | --- | --- |
| Playable terrain, bare earth | ARSO LiDAR digital terrain model **DMR1**, 1 m grid, 2014–15 survey ([eVode](https://gis.arso.gov.si/evode/profile.aspx?id=atlas_voda_Lidar@Arso)) | Anonymous HTTPS, 1 km² tiles `https://gis.arso.gov.si/lidar/dmr1/b_<block>/D96TM/TM1_<E km>_<N km>.asc` (Tamar is block `b_37`): ASCII `E;N;H` rows, 1,000,000 points, 28 MB per tile | Free to use, modify and reuse with the credit "Ministry of the Environment and Spatial Planning, Slovenian Environment Agency" (per [OpenDEM's record](https://opendem.info/opendemeu_meta_slovenia.html) of ARSO's statement). Confirm with ARSO before release |
| Newer terrain, canopy height, orthophoto | GURS cyclic laser scanning 2023–2025 ([news](https://www.gov.si/novice/2026-06-03-lidarski-podatki-za-celotno-slovenijo-dostopni-v-pregledovalniku-3d-podatkov/), viewer [clss.si](https://clss.si/)) | Free, no registration, 1 km sheets, up to ten at a time: DMR and DMP (LAZ), nDMP canopy height, hillshade, orthophoto (GeoTIFF) | GURS data are CC BY 4.0 ([terms](https://www.e-prostor.gov.si/en/access-to-geodetic-data/)): credit the Surveying and Mapping Authority, the data type and date. The page does not name the LiDAR products explicitly: confirm |
| Far backdrop over Italy and Austria (outside Slovenian data) | SRTM via Mapzen Terrain Tiles, tile `N46E013` (the source the Club mountains already use) | Anonymous | Public domain: "SRTM data courtesy of the U.S. Geological Survey" |
| Not used | Copernicus GLO-30 | — | A surface model (tree tops and roofs), wrong for solid ground |

Raw downloads stay outside `app/` in a cache under `tmp/`, pinned by SHA-256 in a sources file. Only the reduced,
quantized products the game needs are committed, each well under the repository's 50 MiB rule
(`tools/repo/large_files.json`).

## Design

**Extent.**
- Playable core: 4 × 4 km at 2 m spacing, from 16 DMR1 tiles averaged 2 × 2 (about 4 M samples).
- Visual-only ring: about 24 × 24 km at 16–32 m, from DMR1 decimated inside Slovenia and SRTM beyond.
- The field origin is the pilot spot. Heights are stored relative to it, and the field's elevation (849.7 m at the
  Rateče meadow) feeds the atmosphere, so air density is right for the altitude (done 2026-11-21).

**Pilot spots.**
- Tamar meadow south of the hut was the first choice, but it falls 6–7 % everywhere: only 2 of 10 airplanes can park
  there at idle. The pilot stands instead on a level hay meadow on the Rateče plain at the mouth of the Planica valley
  (849.7 m), with a 100 × 12 m strip 24 m south and a levelled helicopter pad between them.
- Later: the outrun of the Planica ski-flying hills.

**21a, data and visuals.**
- TG-01 fetch and pin: downloads the listed tiles into the cache, checks hashes and writes `sources.json` with
  attribution.
- TG-02 bake: builds the 2 m core and the far ring as 16-bit height grids, about 2 cm steps over the valley's
  900–2650 m.
- TG-02 validation: the hut at 1108 m, the Nordic Centre, the Jalovec summit, and a smooth seam between core and ring.
  It writes a `--check` mode like the other generators.
- TG-03 landscape adapter `landscapes/triglav_tamar/` (done):
  - terrain: a quadtree of one shared 64 × 64 tile with skirts, placed by transform; the vertex shader reads the
    2 m core (tiles up to 6 m spacing) or the 16 m ring from RG8 textures, so the CPU never builds terrain meshes;
  - colour from the GKOT true orthophoto inside the core, procedural alpine shading (forest, alpine grass, limestone)
    outside it and where the photo is filled; haze as in the ground shader, without its flat-ground rim;
  - trees: every detected crown, as low-poly spruce and broadleaf instances in 250 m chunks, tinted from the photo,
    drawn to 1.5 km;
  - buildings: every GKOT roof region rebuilt from its 1 m roof grid (footprint, roof shape, walls), roofs coloured
    from the photo;
  - `tests/test_triglav_landscape.gd`.
- TG-04 field and catalog (done):
  - `field.json`, with surfaces for the meadow;
  - an entry in `landscapes/catalog.gd`, so Home and Settings list it beside Club field and Green paradise;
  - attribution in the credits (done: `app/landscapes/triglav_tamar/CREDITS.md`, linked from the field credits).

**21b, solid terrain contact.**
- TG-05 a DEM provider in `physics/ground_terrain.gd` (done: `physics/terrain_dem.gd`):
  - It returns height and slope from the baked grid, with bicubic interpolation so the slope is continuous.
  - It is composed under the field's surfaces the way the lake basin is.
  - `max_height` covers the DEM's highest point, so the airborne skip test stays conservative.
  - The flight model is untouched; only the ground under it changes.
- TG-06 wire every session that samples terrain to the provider (done: the provider follows the field's surface
  tables, airframe contact runs in the terrain's tangent plane, helicopter pads are levelled platforms):
  - airplanes (gear, hull, ground effect, ground start);
  - helicopters, multirotors and the RC trucks.
  - The AI companions are qualified on Club field only and refuse other fields as before.
- TG-07 collision for trees and buildings through the existing scenery collision world (done:
  `landscapes/triglav_tamar/obstacles.gd`; trees and buildings within 600 m of the pilot are solid, since a flight log
  carries the whole inventory). Settings > Graphics > Scene detail sets how far they are drawn (trees 600, 1000, 1500
  or 2500 m; buildings 2, 3, 4 or 6 km).
- TG-08 tests (`tests/test_triglav_terrain.gd` covers the provider, a hull inside a mountainside, an airplane parked and
  rolling on the strip, a truck driving the meadow and the helicopter pad; frame-time captures remain):
  - the provider against the baked grid;
  - landing and take-off on the sloped meadow;
  - a truck driving the valley road;
  - a crash into a slope;
  - frame-time captures at 1080p.

## Risks and notes

- **Licences.** The ARSO wording is from correspondence quoted by OpenDEM, and GURS's CC BY 4.0 page does not name the
  LiDAR products. Ask ARSO and GURS to confirm before a public release.
- **Real-world rules.** Flying drones and models in Triglav National Park needs the park's prior consent
  ([Triglav National Park on drones](https://oko.bohinj.si/en/program/drones-in-protected-areas/)). The landscape's
  description will say so: the simulator is the place to fly there freely.
- **Size and speed.**
  - Download: 1.6 GB of ARSO tiles and about 40 GB of GKOT sheets (cached under `tmp/`, never committed).
  - Committed products: about 10–20 MB.
  - Physics: the provider's lookup is O(1) per wheel or contact point.
  - Rendering: needs LOD; the existing scenery budgets apply.
- **Data age.** The core's bare earth, photo, trees and buildings are from the 2024–25 survey; ARSO's 2014–15 model
  fills only the ground under dense canopy.
- **Atmosphere at altitude** (owner decision 2026-11-21, done). The field flies in the air at its 849.7 m pilot spot:
  1.128 kg/m³, 7.9 % thinner than sea level (`app/physics/field_air.gd`, [decision](../DECISIONS.md)). The default
  air becomes the standard atmosphere there; custom air keeps its temperature, QNH and humidity at the field's
  elevation. Home's conditions line shows the air flown. Natural Random stays on Club field (its v1 catalog pins sea
  level). Wind and height-above-ground readouts use the datum at the pilot spot.
