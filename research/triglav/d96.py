"""D96/TM (EPSG:3794) projection math shared by the TG/KM bake scripts."""
import math

import numpy as np

# GRS80 transverse Mercator for D96/TM (EPSG:3794).
A = 6378137.0
F = 1.0 / 298.257222101
E2 = F * (2.0 - F)
EP2 = E2 / (1.0 - E2)
K0 = 0.9999
LON0 = math.radians(15.0)
FE, FN = 500000.0, -5000000.0


def d96_to_wgs84(east: np.ndarray, north: np.ndarray):
    """Inverse transverse Mercator (Snyder 1987, eqs. 8-12 to 8-25), arrays in metres to degrees."""
    x = (east - FE) / K0
    m = (north - FN) / K0
    mu = m / (A * (1 - E2 / 4 - 3 * E2 ** 2 / 64 - 5 * E2 ** 3 / 256))
    e1 = (1 - math.sqrt(1 - E2)) / (1 + math.sqrt(1 - E2))
    phi1 = (mu + (3 * e1 / 2 - 27 * e1 ** 3 / 32) * np.sin(2 * mu) + (21 * e1 ** 2 / 16 - 55 * e1 ** 4 / 32) * np.sin(4 * mu)
            + (151 * e1 ** 3 / 96) * np.sin(6 * mu) + (1097 * e1 ** 4 / 512) * np.sin(8 * mu))
    c1 = EP2 * np.cos(phi1) ** 2
    t1 = np.tan(phi1) ** 2
    n1 = A / np.sqrt(1 - E2 * np.sin(phi1) ** 2)
    r1 = A * (1 - E2) / (1 - E2 * np.sin(phi1) ** 2) ** 1.5
    d = x / n1
    lat = phi1 - (n1 * np.tan(phi1) / r1) * (d ** 2 / 2 - (5 + 3 * t1 + 10 * c1 - 4 * c1 ** 2 - 9 * EP2) * d ** 4 / 24
                                              + (61 + 90 * t1 + 298 * c1 + 45 * t1 ** 2 - 252 * EP2 - 3 * c1 ** 2) * d ** 6 / 720)
    lon = LON0 + (d - (1 + 2 * t1 + c1) * d ** 3 / 6 + (5 - 2 * c1 + 28 * t1 - 3 * c1 ** 2 + 8 * EP2 + 24 * t1 ** 2) * d ** 5 / 120) / np.cos(phi1)
    return np.degrees(lat), np.degrees(lon)


def wgs84_to_d96(lat: float, lon: float):
    """Forward transform by Newton iteration on the inverse (scalar, degrees to metres; sub-millimetre)."""
    east = 500000.0 + (lon - 15.0) * 77000.0
    north = lat * 111000.0 - 5000000.0
    for _ in range(30):
        la, lo = d96_to_wgs84(np.array([east]), np.array([north]))
        north += (lat - float(la[0])) * 111132.0
        east += (lon - float(lo[0])) * 111320.0 * math.cos(math.radians(lat))
    return east, north
