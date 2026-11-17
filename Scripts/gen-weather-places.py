#!/usr/bin/env python3
"""Build the compact weather place index from three GeoNames dump files."""
import sqlite3
import sys
import unicodedata
from pathlib import Path
from zipfile import ZipFile


def key(name):
    folded = unicodedata.normalize("NFKD", name.casefold())
    return "".join(char for char in folded if char.isalnum())


source, output = map(Path, sys.argv[1:])
countries = {
    row[0]: (row[1], row[4], row[5]) for line in (source / "countryInfo.txt").read_text().splitlines()
    if line and not line.startswith("#") for row in [line.split("\t")]
}
capital_names = {code: key(capital) for code, (_, _, capital) in countries.items() if capital}
capitals = {}
regions = {
    row[0]: row[1:3] for line in (source / "admin1CodesASCII.txt").read_text().splitlines()
    if line for row in [line.split("\t")]
}

output.unlink(missing_ok=True)
with sqlite3.connect(output) as db, ZipFile(source / "cities1000.zip") as archive:
    db.executescript("""
        CREATE TABLE city(id INTEGER PRIMARY KEY, label TEXT, latitude REAL, longitude REAL,
                          population INTEGER, country TEXT, region TEXT, region_ascii TEXT,
                          country_code TEXT, region_code TEXT, qualifier TEXT);
        CREATE TABLE name(key TEXT, city INTEGER, rank INTEGER,
                          PRIMARY KEY(key, city)) WITHOUT ROWID;
        CREATE TABLE country_capital(key TEXT PRIMARY KEY, city INTEGER NOT NULL) WITHOUT ROWID;
    """)
    for line in archive.read("cities1000.txt").decode().splitlines():
        row = line.split("\t")
        identifier, name, ascii_name, alternatives, latitude, longitude = row[:6]
        country_code, region_code = row[8], row[10]
        country = countries.get(country_code, ("", country_code, ""))[1]
        region, region_ascii = regions.get(f"{country_code}.{region_code}", ("", ""))
        label = ", ".join(dict.fromkeys(part for part in [name, region, country] if part))
        qualifier = ", ".join(dict.fromkeys(part for part in [region, country] if part and part != name))
        db.execute("INSERT INTO city VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", (
            identifier, label, latitude, longitude, row[14] or 0, key(country),
            key(region), key(region_ascii), key(country_code), key(region_code), key(qualifier)))
        names = [(name, 0), (ascii_name, 0)]
        seen = {key(name), key(ascii_name)}
        if capital := capital_names.get(country_code):
            if capital in seen:
                priority = 0
            elif any(key(alias) == capital for alias in alternatives.split(",")):
                priority = 1
            elif row[7] == "PPLC":
                priority = 2
            else:
                priority = None
            if priority is not None:
                candidate = (priority, row[7] != "PPLC", -int(row[14] or 0), int(identifier))
                if country_code not in capitals or candidate < capitals[country_code]:
                    capitals[country_code] = candidate
        aliases = (alias for alias in alternatives.split(",") if 2 <= len(alias) <= 80 and alias.isascii()
                   and all(char.isalpha() or char in " -'." for char in alias))
        for alias in aliases:
            folded = key(alias)
            if folded and folded not in seen:
                names.append((alias, 1))
                seen.add(folded)
                if len(names) >= 8:
                    break
        db.executemany("INSERT OR IGNORE INTO name VALUES (?, ?, ?)", (
            (folded, identifier, rank) for alias, rank in names if (folded := key(alias))))
    for code, (_, _, _, identifier) in capitals.items():
        iso3, country, _ = countries[code]
        aliases = [code, iso3, country]
        if code == "GB":
            aliases.append("UK")
        db.executemany("INSERT INTO country_capital VALUES (?, ?)", (
            (alias, identifier) for alias in dict.fromkeys(map(key, aliases)) if alias))
    db.execute("CREATE INDEX city_latitude ON city(latitude)")
    db.commit()
    db.execute("VACUUM")
