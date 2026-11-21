# Triglav: Planica and Tamar — data credits

The landscape is built from Slovenian national survey data. Generation scripts, pinned sources and transformations
are in [research/triglav/README.md](../../../research/triglav/README.md) in the source distribution.

| Used for | Source | Licence and credit |
| --- | --- | --- |
| Bare-earth terrain (8 × 8 km core, 2 m), trees, buildings, aerial photo (from the point colours) | Cyclic laser scanning of Slovenia 2023–2025: classified point cloud (GKOT), via [clss.si](https://clss.si/) | CC BY 4.0 ([terms](https://www.e-prostor.gov.si/en/access-to-geodetic-data/)). *Contains data of the Surveying and Mapping Authority of the Republic of Slovenia (GURS), cyclic laser scanning 2023–2025.* |
| Core terrain under dense canopy | ARSO LiDAR digital terrain model DMR1, 2014–15 survey | Free to use, modify and reuse with credit. *Ministry of the Environment and Spatial Planning, Slovenian Environment Agency (ARSO).* |
| Outer ring (far view only) and the core's Italian corner | SRTM 1 arc-second, Mapzen Terrain Tiles | Public domain. *SRTM data courtesy of the U.S. Geological Survey; Mapzen Terrain Tiles.* |

Changes: the point clouds were gridded, filtered and merged with ARSO under canopy; trees and buildings were extracted
from the classified points and simplified; the photo is the colour of the highest point per cell, with gaps filled. The products are not survey
data and must not be used for navigation. Both licence statements are to be confirmed with GURS and ARSO before a
public release (the GURS terms page does not name the LiDAR products).
