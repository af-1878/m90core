#!/usr/bin/env python3
"""
make_roms.py - Irem M90 / M99 ROM assembler for Analogue Pocket
================================================================

Assembles MAME ROM ZIP files into packed .rom files for the Pocket openFPGA core.

Usage:
    python3 make_roms.py <roms_dir> [output_dir]

    roms_dir:   Directory containing MAME ROM ZIP files
    output_dir: Where to write .rom files
                (default: Assets/irem_m90/common/ relative to script)

ROM image format (packed sequential, matches rom.sv parser):
------------------------------------------------------------
    byte 0:         board_cfg byte (board_cfg_t)
    Then for each region:
        byte 0:     region index
        bytes 1-3:  region size (big-endian 24-bit)
        bytes 4+:   region data (exactly 'size' bytes)

Region indices (from board_pkg.sv LOAD_REGIONS):
    0 = CPU ROM    (V35 program, interleaved)
    1 = GFX ROM    (GA25 tiles, 32-bit interleaved)
    2 = Sound CPU  (Z80 program)
    3 = Samples    (PCM audio)
    4 = CPU Key    (256-byte decryption table)
"""

import os
import sys
import zipfile
import hashlib
import binascii
from collections import defaultdict, OrderedDict

# =============================================================================
# ZIP indexing with lenient matching
# =============================================================================

_crc_index = {}
_zip_files = {}


def index_zips(roms_dir):
    global _crc_index, _zip_files
    _crc_index = {}
    _zip_files = {}
    total = 0
    for zname in sorted(os.listdir(roms_dir)):
        if not zname.lower().endswith('.zip'):
            continue
        zpath = os.path.join(roms_dir, zname)
        try:
            zf = zipfile.ZipFile(zpath, 'r')
        except Exception:
            continue
        _zip_files[zname] = zf
        for info in zf.infolist():
            if info.is_dir():
                continue
            crc = f'{info.CRC & 0xFFFFFFFF:08x}'
            if crc not in _crc_index:
                _crc_index[crc] = []
            _crc_index[crc].append((zname, info.filename))
            total += 1
    print(f"  Indexed {total} files across ZIPs in {roms_dir}")


def read_by_crc(crc_hex, friendly_name, expected_zips=None, warnings_list=None):
    key = crc_hex.lower().strip() if isinstance(crc_hex, str) else f'{crc_hex:08x}'
    if key not in _crc_index:
        raise FileNotFoundError(
            f"ROM not found: {friendly_name} (CRC {key})\n"
            f"  Make sure the correct MAME ZIP is in your roms_dir."
        )
    matches = _crc_index[key]

    # Prefer expected ZIPs if specified
    chosen = None
    if expected_zips:
        for zname, fname in matches:
            if zname in expected_zips:
                chosen = (zname, fname)
                break
    if chosen is None:
        chosen = matches[0]
        if expected_zips and warnings_list is not None:
            zname, fname = chosen
            warnings_list.append(
                f"ROM {friendly_name} (CRC {key}) sourced from {zname}, "
                f"not in expected ZIPs {expected_zips}"
            )

    zname, fname = chosen
    data = _zip_files[zname].read(fname)
    actual_crc = f'{binascii.crc32(data) & 0xFFFFFFFF:08x}'
    if actual_crc != key:
        raise ValueError(f"CRC mismatch for {friendly_name}: expected {key}, got {actual_crc}")
    return data


# =============================================================================
# Provenance tracking
# =============================================================================

provenance = defaultdict(lambda: {'CPU': [], 'GFX': [], 'SND': [], 'SAM': [], 'KEY': []})
section_summaries = OrderedDict()


def add_provenance(game_name, kind, friendly_name, crc_hex, zipname):
    provenance[game_name][kind].append((friendly_name, crc_hex, zipname))


def register_section(section_name):
    if section_name not in section_summaries:
        section_summaries[section_name] = {'games': [], 'zips': set(), 'warnings': []}


def register_game(section_name, game_name, expected_zips):
    register_section(section_name)
    section_summaries[section_name]['games'].append(game_name)
    for z in expected_zips:
        if z in _zip_files:
            section_summaries[section_name]['zips'].add(z)


# =============================================================================
# Interleave helpers
# =============================================================================

def interleave_16(hi_data, lo_data, word_swap=True):
    """Interleave two byte streams into 16-bit words for V35 CPU ROMs."""
    length = min(len(hi_data), len(lo_data))
    out = bytearray(length * 2)
    for i in range(length):
        if word_swap:
            out[i*2]   = lo_data[i]
            out[i*2+1] = hi_data[i]
        else:
            out[i*2]   = hi_data[i]
            out[i*2+1] = lo_data[i]
    return bytes(out)


def interleave_32(b0, b1, b2, b3):
    """Interleave four byte streams into 32-bit words for GFX ROMs."""
    length = min(len(b0), len(b1), len(b2), len(b3))
    out = bytearray(length * 4)
    for i in range(length):
        out[i*4 + 0] = b0[i]
        out[i*4 + 1] = b1[i]
        out[i*4 + 2] = b2[i]
        out[i*4 + 3] = b3[i]
    return bytes(out)


def mirror_to_size(data, target_size):
    """Mirror data repeatedly to fill target_size bytes."""
    out = bytearray(target_size)
    for i in range(target_size):
        out[i] = data[i % len(data)]
    return bytes(out)


# =============================================================================
# ROM image builder
# =============================================================================

def region_header(region_idx, data):
    size = len(data)
    return bytes([region_idx, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF])


def pack_rom(board_cfg, regions):
    """
    Build a packed ROM image.
    board_cfg: single byte (int)
    regions: list of (region_idx, data_bytes) tuples
    """
    out = bytearray()
    out.append(board_cfg)
    for idx, data in regions:
        print(f"    region {idx}: {len(data)//1024}KB")
        out += region_header(idx, data)
        out += data
    return bytes(out)


# =============================================================================
# Encryption keys (256 bytes each, from MRA files)
# =============================================================================

KEY_DYNABLST = bytes([
    0x90,0x90,0x79,0x90,0x9d,0x48,0x90,0x90,0x90,0x90,0x2e,0x90,0x90,0xa5,0x72,0x90,
    0x46,0x5b,0xb1,0x3a,0xc3,0x90,0x35,0x90,0x90,0x23,0x90,0x99,0x90,0x05,0x90,0x3c,
    0x3b,0x76,0x11,0x90,0x90,0x4b,0x90,0x92,0x90,0x32,0x5d,0x90,0xf7,0x5a,0x9c,0x90,
    0x26,0x40,0x89,0x90,0x90,0x90,0x90,0x57,0x90,0x90,0x90,0x90,0x90,0xba,0x53,0xbb,
    0x42,0x59,0x2f,0x90,0x77,0x90,0x90,0x4f,0xbf,0x4a,0xcb,0x86,0x62,0x7d,0x90,0xb8,
    0x90,0x34,0x90,0x5f,0x90,0x7f,0xf8,0x80,0xa0,0x84,0x12,0x52,0x90,0x90,0x90,0x47,
    0x90,0x2b,0x88,0xf9,0x90,0xa3,0x83,0x90,0x75,0x87,0x90,0xab,0xeb,0x90,0xfe,0x90,
    0x90,0xaf,0xd0,0x2c,0xd1,0xe6,0x90,0x43,0xa2,0xe7,0x85,0xe2,0x49,0x22,0x29,0x90,
    0x7c,0x90,0x90,0x9a,0x90,0x90,0xb9,0x90,0x14,0xcf,0x33,0x02,0x90,0x90,0x90,0x73,
    0x90,0xc5,0x90,0x90,0x90,0xf3,0xf6,0x24,0x90,0x56,0xd3,0x90,0x09,0x01,0x90,0x90,
    0x03,0x2d,0x1b,0x90,0xf5,0xbe,0x90,0x90,0xfb,0x8e,0x21,0x8d,0x0b,0x90,0x90,0xb2,
    0xfc,0xfa,0xc6,0x90,0xe8,0xd2,0x90,0x08,0x0a,0xa8,0x78,0xff,0x90,0xb5,0x90,0x90,
    0xc7,0x06,0x18,0x90,0x90,0x1e,0x7e,0xb0,0x0e,0x0f,0x90,0x90,0x0c,0xaa,0x55,0x90,
    0x90,0x74,0x3d,0x90,0x90,0x38,0x27,0x50,0x90,0xb6,0x5e,0x8b,0x07,0xe5,0x39,0xea,
    0xbd,0x90,0x81,0xb7,0x90,0x8a,0x0d,0x90,0x58,0xa1,0xa9,0x36,0x90,0xc4,0x90,0x8f,
    0x8c,0x1f,0x51,0x04,0xf2,0x90,0xb3,0xb4,0xe9,0x2a,0x90,0x90,0x90,0x25,0x90,0xbc,
])

KEY_BBMANW = bytes([
    0x1f,0x51,0x84,0x90,0x3d,0x09,0x0d,0x90,0x90,0x57,0x90,0x90,0x90,0x32,0x11,0x90,
    0x90,0x9c,0x90,0x90,0x4b,0x90,0x90,0x03,0x90,0x90,0x90,0x89,0xb0,0x90,0x90,0x90,
    0x90,0xbb,0x18,0xbe,0x53,0x21,0x55,0x7c,0x90,0x90,0x47,0x58,0xf6,0x90,0x90,0xb2,
    0x06,0x90,0x2b,0x90,0x2f,0x0b,0xfc,0x98,0x90,0x90,0xfa,0x81,0x83,0x40,0x38,0x90,
    0x90,0x90,0x49,0x85,0xd1,0xf5,0x07,0xe2,0x5e,0x1e,0x90,0x04,0x90,0x90,0x90,0xb1,
    0xc7,0x90,0x96,0xf2,0xb6,0xd2,0xc3,0x90,0x87,0xba,0xcb,0x88,0x90,0xb9,0xd0,0xb5,
    0x9a,0x80,0xa2,0x72,0x90,0xb4,0x90,0xaa,0x26,0x7d,0x52,0x33,0x2e,0xbc,0x08,0x79,
    0x48,0x90,0x76,0x36,0x02,0x90,0x5b,0x12,0x8b,0xe7,0x90,0x90,0x90,0xab,0x90,0x4f,
    0x90,0x90,0xa8,0xe5,0x39,0x0e,0xa9,0x90,0x90,0x14,0x90,0xff,0x7f,0x90,0x90,0x27,
    0x90,0x01,0x90,0x90,0xe6,0x8a,0xd3,0x90,0x90,0x8e,0x56,0xa5,0x92,0x90,0x90,0xf9,
    0x22,0x90,0x5f,0x90,0x90,0xa1,0x90,0x74,0xb8,0x90,0x46,0x05,0xeb,0xcf,0xbf,0x5d,
    0x24,0x90,0x9d,0x90,0x90,0x90,0x90,0x90,0x59,0x8d,0x3c,0xf8,0xc5,0x90,0xf3,0x4e,
    0x90,0x90,0x50,0xc6,0xe9,0xfe,0x0a,0x90,0x99,0x86,0x90,0x90,0xaf,0x8c,0x42,0xf7,
    0x90,0x41,0x90,0xa3,0x90,0x3a,0x2a,0x43,0x90,0xb3,0xe8,0x90,0xc4,0x35,0x78,0x25,
    0x75,0x90,0xb7,0x90,0x23,0x90,0x90,0x8f,0x90,0x90,0x2c,0x90,0x77,0x7e,0x90,0x0f,
    0x0c,0xa0,0xbd,0x90,0x90,0x2d,0x29,0xea,0x90,0x3b,0x73,0x90,0xfb,0x20,0x90,0x5a,
])

KEY_RISKCHAL = bytes([
    0x63,0x90,0x90,0x36,0x90,0x52,0xb1,0x5b,0x68,0xcd,0x90,0x90,0x90,0xa8,0x90,0x90,
    0x90,0x90,0x75,0x24,0x08,0x83,0x32,0xe9,0x90,0x79,0x90,0x8f,0x22,0x90,0xac,0x90,
    0x5d,0xa5,0x11,0x51,0x0a,0x29,0x90,0x90,0xf8,0x98,0x91,0x40,0x28,0x00,0x03,0x5f,
    0x26,0x90,0x90,0x8b,0x2f,0x02,0x90,0x90,0x8e,0xab,0x90,0x90,0xbc,0x90,0xb3,0x90,
    0x09,0x90,0xc6,0x90,0x90,0x3a,0x90,0x90,0x90,0x74,0x61,0x90,0x33,0x90,0x90,0x90,
    0x90,0x53,0xa0,0xc0,0xc3,0x41,0xfc,0xe7,0x90,0x2c,0x7c,0x2b,0x90,0x4f,0xba,0x2a,
    0xb0,0x90,0x21,0x7d,0x90,0x90,0xb5,0x07,0xb9,0x90,0x27,0x46,0xf9,0x90,0x90,0x90,
    0x90,0xea,0x72,0x73,0xad,0xd1,0x3b,0x5e,0xe5,0x57,0x90,0x0d,0xfd,0x90,0x92,0x3c,
    0x90,0x86,0x78,0x7f,0x30,0x25,0x2d,0x90,0x9a,0xeb,0x04,0x0b,0xa2,0xb8,0xf6,0x90,
    0x90,0x90,0x9d,0x90,0xbb,0x90,0x90,0xcb,0xa9,0xcf,0x90,0x60,0x43,0x56,0x90,0x90,
    0x90,0xa3,0x90,0x90,0x12,0x90,0xfa,0xb4,0x90,0x81,0xe6,0x48,0x80,0x8c,0xd4,0x90,
    0x42,0x90,0x84,0xb6,0x77,0x3d,0x3e,0x90,0x90,0x0c,0x4b,0x90,0xa4,0x90,0x90,0x90,
    0x90,0xff,0x47,0x90,0x55,0x1e,0x90,0x59,0x93,0x90,0x90,0x90,0x88,0xc1,0x01,0xb2,
    0x85,0x2e,0x06,0xc7,0x05,0x90,0x8a,0x5a,0x58,0xbe,0x90,0x4e,0x90,0x1f,0x23,0x90,
    0xe8,0x90,0x89,0xa1,0xd0,0x90,0x90,0xe2,0x38,0xfe,0x50,0x9c,0x90,0x90,0x90,0x49,
    0xfb,0x20,0xf3,0x90,0x90,0x0f,0x90,0x90,0x90,0x76,0xf7,0xbd,0x39,0x7e,0xbf,0x90,
])

KEY_ATOMPUNK = KEY_DYNABLST
KEY_BOMBRMAN = KEY_DYNABLST
KEY_BBMANWJ  = KEY_BBMANW


# =============================================================================
# Game builders — each returns a fully packed .rom bytes object
# =============================================================================

def _get(crc, name, expected_zips, game_name, kind, warnings_list):
    data = read_by_crc(crc, name, expected_zips, warnings_list)
    crc_hex = f'{crc:08x}' if isinstance(crc, int) else crc
    zname = _crc_index.get(crc_hex.lower(), [('unknown','')])[0][0]
    add_provenance(game_name, kind, name, crc_hex, zname)
    return data


def build_dynablst(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0x27667681, 'bbm-cp1e.ic62', expected_zips, game_name, 'CPU', warnings_list),
        _get(0x95db7a67, 'bbm-cp0e.ic65', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0x695d2019, 'bbm-c0.ic66', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x4c7c8bbc, 'bbm-c1.ic67', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x0700d406, 'bbm-c2.ic68', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x3c3613af, 'bbm-c3.ic69', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0x251090cd, 'bbm-sp.ic23', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0x0fa803fe, 'bbm-v0.ic20', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_DYNABLST', '00000000', 'internal')
    return pack_rom(0x90, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_DYNABLST)])


def build_bombrman(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0x982bd166, 'bbm-p1.ic62', expected_zips, game_name, 'CPU', warnings_list),
        _get(0x0a20afcc, 'bbm-p0.ic65', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0x695d2019, 'bbm-c0.ic66', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x4c7c8bbc, 'bbm-c1.ic67', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x0700d406, 'bbm-c2.ic68', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x3c3613af, 'bbm-c3.ic69', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0x251090cd, 'bbm-sp.ic23', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0x0fa803fe, 'bbm-v0.ic20', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_DYNABLST', '00000000', 'internal')
    return pack_rom(0x90, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_BOMBRMAN)])


def build_atompunk(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0x860c0479, 'bbm-cp0d.ic65', expected_zips, game_name, 'CPU', warnings_list),
        _get(0xbe57bf74, 'bbm-cp1d.ic62', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0x695d2019, 'bbm-c0.ic66', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x4c7c8bbc, 'bbm-c1.ic67', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x0700d406, 'bbm-c2.ic68', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x3c3613af, 'bbm-c3.ic69', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0x251090cd, 'bbm-sp.ic23', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0x0fa803fe, 'bbm-v0.ic20', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_ATOMPUNK', '00000000', 'internal')
    return pack_rom(0x90, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_ATOMPUNK)])


def build_bbmanw(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0x567d3709, 'bbm2-h0-b.ic77', expected_zips, game_name, 'CPU', warnings_list),
        _get(0xe762c22b, 'bbm2-l0-b.ic79', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0xe7ce058a, 'bbm2-c0.ic81', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x636a78a9, 'bbm2-c1.ic82', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x9ac2142f, 'bbm2-c2.ic83', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x47af1750, 'bbm2-c3.ic84', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0x6bc1689e, 'bbm2-sp.ic33', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0x4ad889ed, 'bbm2-v0.ic30', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_BBMANW', '00000000', 'internal')
    return pack_rom(0xa0, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_BBMANW)])


def build_bbmanwj(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0xe1407b91, 'bbm2-h0.ic77', expected_zips, game_name, 'CPU', warnings_list),
        _get(0x20873b49, 'bbm2-l0.ic79', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0xe7ce058a, 'bbm2-c0.ic81', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x636a78a9, 'bbm2-c1.ic82', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x9ac2142f, 'bbm2-c2.ic83', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x47af1750, 'bbm2-c3.ic84', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0xa4b0a66e, 'bbm2-sp-a.ic33', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0x0ae655ff, 'bbm2-v0-b.ic30', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_BBMANWJ', '00000000', 'internal')
    return pack_rom(0xa0, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_BBMANWJ)])


def build_bbmanwja(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0xe1407b91, 'bbm2-h0.ic77', expected_zips, game_name, 'CPU', warnings_list),
        _get(0x20873b49, 'bbm2-l0.ic79', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0xe7ce058a, 'bbm2-c0.ic81', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x636a78a9, 'bbm2-c1.ic82', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x9ac2142f, 'bbm2-c2.ic83', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x47af1750, 'bbm2-c3.ic84', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0xb8d8108c, 'bbm2-sp-b.ic33', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0x0ae655ff, 'bbm2-v0-b.ic30', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_BBMANWJ', '00000000', 'internal')
    return pack_rom(0x80, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_BBMANWJ)])


def build_newapunk(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0x7d858682, 'bbm2-h0-a.ic77', expected_zips, game_name, 'CPU', warnings_list),
        _get(0xc7568031, 'bbm2-l0-a.ic79', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0xe7ce058a, 'bbm2-c0.ic81', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x636a78a9, 'bbm2-c1.ic82', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x9ac2142f, 'bbm2-c2.ic83', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x47af1750, 'bbm2-c3.ic84', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0x6bc1689e, 'bbm2-sp.ic33', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0x4ad889ed, 'bbm2-v0.ic30', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_BBMANW', '00000000', 'internal')
    return pack_rom(0xa0, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_BBMANW)])


def build_riskchal(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0x4c9b5344, 'l4-a-h0-b.ic77', expected_zips, game_name, 'CPU', warnings_list),
        _get(0x0455895a, 'l4-a-l0-b.ic79', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0x84d0b907, 'rc_c0.ic81', expected_zips, game_name, 'GFX', warnings_list),
        _get(0xcb3784ef, 'rc_c1.ic82', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x687164d7, 'rc_c2.ic83', expected_zips, game_name, 'GFX', warnings_list),
        _get(0xc86be6af, 'rc_c3.ic84', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0xbb80094e, 'l4_a-sp.ic33', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0xcddac360, 'rc_v0.ic30', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_RISKCHAL', '00000000', 'internal')
    return pack_rom(0x80, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_RISKCHAL)])


def build_gussun(game_name, expected_zips, warnings_list):
    cpu = interleave_16(
        _get(0x9d585e61, 'l4-a-h0.ic77', expected_zips, game_name, 'CPU', warnings_list),
        _get(0xc7b4c519, 'l4-a-l0.ic79', expected_zips, game_name, 'CPU', warnings_list),
    )
    gfx = interleave_32(
        _get(0x84d0b907, 'rc_c0.ic81', expected_zips, game_name, 'GFX', warnings_list),
        _get(0xcb3784ef, 'rc_c1.ic82', expected_zips, game_name, 'GFX', warnings_list),
        _get(0x687164d7, 'rc_c2.ic83', expected_zips, game_name, 'GFX', warnings_list),
        _get(0xc86be6af, 'rc_c3.ic84', expected_zips, game_name, 'GFX', warnings_list),
    )
    snd = _get(0xbb80094e, 'l4_a-sp.ic33', expected_zips, game_name, 'SND', warnings_list)
    sam = _get(0xcddac360, 'rc_v0.ic30', expected_zips, game_name, 'SAM', warnings_list)
    cpu = mirror_to_size(cpu, 0x100000)
    add_provenance(game_name, 'KEY', 'KEY_RISKCHAL', '00000000', 'internal')
    return pack_rom(0x80, [(0,cpu),(1,gfx),(2,snd),(3,sam),(4,KEY_RISKCHAL)])


# =============================================================================
# Games table
# =============================================================================

SECTIONS = OrderedDict([
    ("Bomber Man / Dyna Blaster (1991 M90)", [
        ("bombman.rom",  "Bomber Man (World)            [variants id=0]",
         build_dynablst, ['dynablst.zip', 'bombrman.zip']),
        ("bombmanj.rom", "Bomber Man (Japan)            [variants id=1]",
         build_bombrman, ['dynablst.zip', 'bombrman.zip']),
        ("dynablst.rom", "Dyna Blaster (Europe)         [variants id=2]",
         build_dynablst, ['dynablst.zip']),
        ("atompunk.rom", "Atomic Punk (US)              [variants id=3]",
         build_atompunk, ['dynablst.zip', 'atompunk.zip']),
    ]),
    ("Bomber Man World / New Dyna Blaster (1992 M99)", [
        ("bomberw.rom",  "Bomber Man World (World)      [variants id=4]",
         build_bbmanw,   ['bbmanw.zip']),
        ("dynabst2.rom", "Bomber Man World (Japan)      [variants id=5]",
         build_bbmanwj,  ['bbmanw.zip', 'bbmanwja.zip', 'bbmanwj.zip']),
        ("bbmanwja.rom", "Bomber Man World Japan rev    [variants id=7]",
         build_bbmanwja, ['bbmanw.zip', 'bbmanwja.zip']),
    ]),
    ("New Atomic Punk (US rebrand of Bomber Man World)", [
        ("atmpunk2.rom", "New Atomic Punk Global Quest  [variants id=6]",
         build_newapunk, ['bbmanw.zip', 'newapunk.zip']),
    ]),
    ("Risky Challenge / Gussun Oyoyo (M90 variant)", [
        ("riskchal.rom", "Risky Challenge               [variants id=8]",
         build_riskchal, ['riskchal.zip']),
        ("gussun.rom",   "Gussun Oyoyo (Japan)          [variants id=9]",
         build_gussun,   ['riskchal.zip', 'gussun.zip']),
    ]),
])


# =============================================================================
# Main build loop
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    roms_dir = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        'Assets', 'irem_m90', 'common'
    )

    print('=' * 62)
    print('  Irem M90/M99 ROM Assembler for Analogue Pocket')
    print('=' * 62)
    print(f'  ROMs source : {os.path.abspath(roms_dir)}')
    print(f'  Output      : {os.path.abspath(output_dir)}')
    print()

    if not os.path.isdir(roms_dir):
        print(f'ERROR: ROM directory not found: {roms_dir}')
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    print('Scanning ZIPs...')
    index_zips(roms_dir)
    print()

    ok = fail = skip = 0

    for section_name, games in SECTIONS.items():
        print(f'\n--- {section_name} ---')
        for outfile, desc, builder, expected_zips in games:
            print(f'\n[ {outfile} ]  {desc}')
            print(f'  Needs: {", ".join(expected_zips)}')

            register_game(section_name, outfile, expected_zips)
            warnings_list = []

            outpath = os.path.join(output_dir, outfile)
            try:
                rom = builder(outfile, expected_zips, warnings_list)
                with open(outpath, 'wb') as f:
                    f.write(rom)
                md5 = hashlib.md5(rom).hexdigest()
                print(f'  -> {outpath}')
                print(f'     {len(rom):,} bytes  MD5={md5}')
                for w in warnings_list:
                    print(f'  WARNING: {w}')
                ok += 1
            except FileNotFoundError as e:
                print(f'  SKIP: {e}')
                skip += 1
            except Exception as e:
                import traceback
                print(f'  FAIL: {e}')
                traceback.print_exc()
                fail += 1

    print()
    print('=' * 62)
    print(f'  Built: {ok}   Skipped (missing ZIPs): {skip}   Failed: {fail}')
    print('=' * 62)

    # Provenance summary
    print('\nProvenance summary:')
    for section_name, info in section_summaries.items():
        print(f'\n  {section_name}')
        for g in info['games']:
            if g in provenance:
                print(f'    {g}:')
                for kind in ['CPU', 'GFX', 'SND', 'SAM', 'KEY']:
                    for name, crc, zipname in provenance[g][kind]:
                        print(f'      [{kind}] {name} ({crc}) <- {zipname}')


if __name__ == '__main__':
    main()
