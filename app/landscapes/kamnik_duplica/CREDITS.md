# Kamnik: Duplica airstrip — data credits

The landscape is built from Slovenian national survey data and Copernicus satellite imagery. Generation scripts,
pinned sources and transformations are in [research/kamnik/README.md](../../../research/kamnik/README.md) in the
source distribution.

| Used for | Source | Licence and credit |
| --- | --- | --- |
| Bare-earth terrain (8 × 8 km core, 2 m), trees, buildings, aerial photo of the core (from the point colours) | Cyclic laser scanning of Slovenia 2023–2025: classified point cloud (GKOT), via [clss.si](https://clss.si/) | CC BY 4.0 ([terms](https://www.e-prostor.gov.si/en/access-to-geodetic-data/)). *Contains data of the Surveying and Mapping Authority of the Republic of Slovenia (GURS), cyclic laser scanning 2023–2025.* |
| Core terrain under dense canopy | ARSO LiDAR digital terrain model DMR1, 2014–15 survey | Free to use, modify and reuse with credit. *Ministry of the Environment and Spatial Planning, Slovenian Environment Agency (ARSO).* |
| Outer ring heights (48 × 48 km: the Kamnik Alps, Krvavec, Rašica, Šmarna gora, Ljubljana) | SRTM 1 arc-second, Mapzen Terrain Tiles | Public domain. *SRTM data courtesy of the U.S. Geological Survey; Mapzen Terrain Tiles.* |
| Outer ring colour | Sentinel-2 cloudless 2016, [s2maps.eu](https://s2maps.eu) | CC BY 4.0. *Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016).* |
| Airstrip layout (runway 11/29, 425 × 25 m grass, elevation 349 m, model flying at threshold 29) | Letalska zveza Slovenije, [Vzletišče Kamnik, operating manual 2021](https://lzs-zveza.si/documents/ULN/Vzleti%C5%A1%C4%8De_Kamnik_2021.pdf) | Facts only; no content copied. |

Changes: the point clouds were gridded, filtered and merged with ARSO under canopy; trees and buildings were extracted
from the classified points and simplified; the core photo is the colour of the highest point per cell, with gaps
filled and the sheets' colour balanced against each other; the satellite mosaic was reprojected to D96/TM. The products are not survey data and must not be used for
navigation. The GURS and ARSO licence statements are to be confirmed before a public release.
