#!/usr/bin/env python3
"""VR180 Injector by Siyang Qi

A simple tool to inject VR180 metadata into SBS video files:
- YouTube VR180: Google Spherical Video V2 (st3d + sv3d) for YouTube upload
- Vision Pro APMP: Apple Projected Media Profile (vexu + hfov) for visionOS 26+

No re-encoding — instant metadata injection. Zero dependencies beyond PyQt6.
"""

import sys
import struct
import shutil
import tempfile
from pathlib import Path


# ── Shared MP4 atom manipulation ───────────────────────────────────────

def _find_atom(buf, start, end, tag):
    """Find atom with given 4-byte tag in [start, end). Returns (offset, size) or None.
    Handles 64-bit extended size atoms (sz==1) and extends-to-end atoms (sz==0)."""
    pos = start
    while pos < end - 8:
        sz = struct.unpack('>I', buf[pos:pos+4])[0]
        t = buf[pos+4:pos+8]
        if sz == 1 and pos + 16 <= end:
            # 64-bit extended size
            sz = struct.unpack('>Q', buf[pos+8:pos+16])[0]
        elif sz == 0:
            sz = end - pos  # extends to end of container
        if sz < 8 or pos + sz > end:
            break
        if t == tag:
            return (pos, sz)
        pos += sz
    return None


def _find_video_trak(buf, moov_off, moov_sz):
    """Find the video trak inside moov (contains 'vide' handler)."""
    pos = moov_off + 8
    end = moov_off + moov_sz
    while pos < end - 8:
        sz = struct.unpack('>I', buf[pos:pos+4])[0]
        t = buf[pos+4:pos+8]
        if sz < 8 or pos + sz > end:
            break
        if t == b'trak' and buf[pos:pos+sz].find(b'vide') >= 0:
            return (pos, sz)
        pos += sz
    return None


def _inject_atoms_into_hvc1(input_path, output_path, inject_data, strip_tags):
    """Inject atoms into the hvc1/hev1 sample entry of an MP4/MOV file.

    Strips any existing atoms with tags in strip_tags, then appends inject_data.
    Correctly updates all parent atom sizes and chunk offsets.
    Memory-efficient: only loads the moov atom, not the entire file.
    If output_path == input_path, modifies the file in-place (no copy).
    """
    in_place = (str(Path(input_path).resolve()) == str(Path(output_path).resolve()))
    if not in_place:
        shutil.copy2(str(input_path), str(output_path))

    # Step 1: Scan for moov position without loading entire file
    moov_file_off = None
    moov_file_sz = None
    with open(str(output_path), 'rb') as f:
        f.seek(0, 2); fsize = f.tell(); f.seek(0)
        while f.tell() < fsize:
            pos = f.tell()
            hdr = f.read(8)
            if len(hdr) < 8: break
            sz, tag = struct.unpack('>I4s', hdr)
            header_sz = 8
            if sz == 1:
                ext = f.read(8)
                sz = struct.unpack('>Q', ext)[0]
                header_sz = 16
            elif sz == 0:
                sz = fsize - pos
            if sz < 8: break
            if tag == b'moov':
                moov_file_off = pos
                moov_file_sz = sz
                break
            f.seek(pos + sz)
    if moov_file_off is None:
        raise Exception("moov atom not found")

    # Step 2: Read only the moov atom
    with open(str(output_path), 'rb') as f:
        f.seek(moov_file_off)
        data = bytearray(f.read(moov_file_sz))

    # Work within the moov buffer (offsets relative to moov start)
    moov = _find_atom(data, 0, len(data), b'moov')
    if not moov:
        raise Exception("moov atom not found in buffer")
    trak = _find_video_trak(data, moov[0], moov[1])
    if not trak:
        raise Exception("Video trak not found")
    mdia = _find_atom(data, trak[0] + 8, trak[0] + trak[1], b'mdia')
    if not mdia:
        raise Exception("mdia not found")
    minf = _find_atom(data, mdia[0] + 8, mdia[0] + mdia[1], b'minf')
    if not minf:
        raise Exception("minf not found")
    stbl = _find_atom(data, minf[0] + 8, minf[0] + minf[1], b'stbl')
    if not stbl:
        raise Exception("stbl not found")
    stsd = _find_atom(data, stbl[0] + 8, stbl[0] + stbl[1], b'stsd')
    if not stsd:
        raise Exception("stsd not found")
    hvc1 = _find_atom(data, stsd[0] + 16, stsd[0] + stsd[1], b'hvc1')
    if not hvc1:
        hvc1 = _find_atom(data, stsd[0] + 16, stsd[0] + stsd[1], b'hev1')
    if not hvc1:
        raise Exception("hvc1/hev1 not found — file must be H.265/HEVC encoded")
    hvc1_off, hvc1_sz = hvc1

    # Rebuild hvc1: keep header + non-stripped sub-atoms + new inject_data
    hvc1_header = data[hvc1_off:hvc1_off + 86]  # 4(size) + 4(tag) + 78(video sample entry)
    kept = bytearray()
    pos = hvc1_off + 86
    end = hvc1_off + hvc1_sz
    while pos < end - 8:
        asz = struct.unpack('>I', data[pos:pos+4])[0]
        atag = data[pos+4:pos+8]
        if asz < 8 or pos + asz > end:
            break
        if bytes(atag) not in strip_tags:
            kept.extend(data[pos:pos+asz])
        pos += asz

    new_body = bytes(kept) + inject_data
    new_hvc1_sz = 86 + len(new_body)
    new_hvc1 = struct.pack('>I', new_hvc1_sz) + hvc1_header[4:86] + new_body
    size_delta = new_hvc1_sz - hvc1_sz

    # Replace hvc1 in data
    data[hvc1_off:hvc1_off + hvc1_sz] = new_hvc1

    # Update parent chain sizes
    for off, _ in [stsd, stbl, minf, mdia, trak, moov]:
        old_sz = struct.unpack('>I', data[off:off+4])[0]
        struct.pack_into('>I', data, off, old_sz + size_delta)

    # Fix chunk offsets if moov is before mdat (insertion shifts mdat position)
    # moov_file_off is the position in the ORIGINAL file; data buffer is moov-only
    moov_is_before_mdat = (moov_file_off + moov_file_sz <= fsize and
                           moov_file_off < fsize - moov_file_sz)  # moov not at end
    if size_delta != 0 and moov_is_before_mdat:
        moov_data_end = len(data)
        for tag in [b'stco', b'co64']:
            search_pos = 0
            while True:
                idx = data.find(tag, search_pos, moov_data_end)
                if idx < 4:
                    break
                atom_sz = struct.unpack('>I', data[idx-4:idx])[0]
                n = struct.unpack('>I', data[idx+8:idx+12])[0]
                if tag == b'stco':
                    for e in range(n):
                        eoff = idx + 12 + e * 4
                        v = struct.unpack('>I', data[eoff:eoff+4])[0]
                        struct.pack_into('>I', data, eoff, v + size_delta)
                else:  # co64
                    for e in range(n):
                        eoff = idx + 12 + e * 8
                        v = struct.unpack('>Q', data[eoff:eoff+8])[0]
                        struct.pack_into('>Q', data, eoff, v + size_delta)
                search_pos = idx + atom_sz

    # Write back: only rewrite the moov portion of the file
    moov_at_end = (moov_file_off + moov_file_sz >= fsize)
    if moov_at_end:
        # moov is at end of file — just truncate and rewrite moov
        with open(str(output_path), 'r+b') as f:
            f.seek(moov_file_off)
            f.write(data)
            f.truncate()
    else:
        # moov is before mdat — need to rewrite everything after moov
        with open(str(output_path), 'rb') as f:
            f.seek(moov_file_off + moov_file_sz)
            after_moov = f.read()
        with open(str(output_path), 'r+b') as f:
            f.seek(moov_file_off)
            f.write(data)
            f.write(after_moov)
            f.truncate()


# ── YouTube VR180 (Google Spherical Video V2) ──────────────────────────

def inject_youtube_vr180(input_path, output_path):
    """Inject YouTube VR180 metadata (st3d + sv3d). Pure Python, no dependencies."""

    # st3d: stereo_mode = 2 (leftRight / side-by-side)
    st3d = struct.pack('>I', 13) + b'st3d' + b'\x00\x00\x00\x00' + b'\x02'

    # sv3d: svhd + proj(prhd + equi)
    svhd = struct.pack('>I', 13) + b'svhd' + b'\x00\x00\x00\x00' + b'\x00'
    prhd = struct.pack('>I', 24) + b'prhd' + b'\x00' * 16  # yaw=0, pitch=0, roll=0
    # equi: version/flags(4) + top(4) + bottom(4) + left(4) + right(4) = 28 bytes
    # For VR180: top=0, bottom=0, left=0x3FFFFFFF, right=0x3FFFFFFF (crop 180° from each side)
    equi = struct.pack('>I', 28) + b'equi' + struct.pack('>IIIII', 0, 0, 0, 0x3FFFFFFF, 0x3FFFFFFF)
    proj = struct.pack('>I', 8 + len(prhd) + len(equi)) + b'proj' + prhd + equi
    sv3d = struct.pack('>I', 8 + len(svhd) + len(proj)) + b'sv3d' + svhd + proj

    _inject_atoms_into_hvc1(input_path, output_path, st3d + sv3d,
                            strip_tags={b'st3d', b'sv3d', b'vexu', b'hfov'})


# ── Vision Pro APMP (Apple Projected Media Profile) ────────────────────

def inject_apmp_vr180(input_path, output_path, baseline_mm=65.0):
    """Inject VR180 APMP metadata for Vision Pro (visionOS 26+). Pure Python."""

    # eyes/stri: stereo indication = 0x03 (side-by-side)
    stri = struct.pack('>I', 13) + b'stri' + b'\x00\x00\x00\x00' + b'\x03'
    eyes = struct.pack('>I', 8 + len(stri)) + b'eyes' + stri

    # proj/prji: projection = halfEquirectangular
    prji = struct.pack('>I', 16) + b'prji' + b'\x00\x00\x00\x00' + b'hequ'
    proj = struct.pack('>I', 8 + len(prji)) + b'proj' + prji

    # pack/pkin: view packing = sideBySide
    pkin = struct.pack('>I', 16) + b'pkin' + b'\x00\x00\x00\x00' + b'side'
    pack = struct.pack('>I', 8 + len(pkin)) + b'pack' + pkin

    # cams/blin: camera baseline in mm (fixed-point × 65536)
    blin_val = int(baseline_mm * 65536) & 0xFFFFFFFF
    blin = struct.pack('>I', 12) + b'blin' + struct.pack('>I', blin_val)
    cams = struct.pack('>I', 8 + len(blin)) + b'cams' + blin

    vexu = struct.pack('>I', 8 + len(eyes) + len(proj) + len(pack) + len(cams)) + b'vexu' + eyes + proj + pack + cams

    # hfov: horizontal field of view = 180° (stored as 180000 = 180.000°)
    hfov = struct.pack('>I', 12) + b'hfov' + struct.pack('>I', 180000)

    _inject_atoms_into_hvc1(input_path, output_path, vexu + hfov,
                            strip_tags={b'st3d', b'sv3d', b'vexu', b'hfov'})


# ── GUI ────────────────────────────────────────────────────────────────

def main():
    from PyQt6.QtWidgets import (
        QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
        QLabel, QPushButton, QFileDialog, QLineEdit, QRadioButton,
        QButtonGroup, QSpinBox, QMessageBox, QGroupBox
    )
    from PyQt6.QtCore import Qt
    from PyQt6.QtGui import QFont

    app = QApplication(sys.argv)

    win = QMainWindow()
    win.setWindowTitle("VR180 Injector by Siyang Qi")
    win.setFixedSize(560, 380)

    central = QWidget()
    win.setCentralWidget(central)
    layout = QVBoxLayout(central)
    layout.setSpacing(10)

    # Title
    title = QLabel("VR180 Metadata Injector")
    title.setFont(QFont("", 16, QFont.Weight.Bold))
    title.setAlignment(Qt.AlignmentFlag.AlignCenter)
    layout.addWidget(title)

    subtitle = QLabel("Inject VR180 metadata into SBS H.265 files — no re-encoding")
    subtitle.setAlignment(Qt.AlignmentFlag.AlignCenter)
    subtitle.setStyleSheet("color: #666;")
    layout.addWidget(subtitle)

    # Input file
    input_group = QGroupBox("Input")
    input_layout = QHBoxLayout(input_group)
    input_edit = QLineEdit()
    input_edit.setPlaceholderText("Select a SBS video file (.mp4, .mov)")
    input_edit.setReadOnly(True)
    input_layout.addWidget(input_edit, 1)
    browse_btn = QPushButton("Browse")
    input_layout.addWidget(browse_btn)
    layout.addWidget(input_group)

    # Mode selection
    mode_group = QGroupBox("Injection Mode")
    mode_layout = QVBoxLayout(mode_group)

    radio_youtube = QRadioButton("YouTube VR180  (st3d + sv3d — for YouTube upload)")
    radio_apmp = QRadioButton("Vision Pro APMP  (vexu + hfov — for visionOS 26+)")
    radio_apmp.setChecked(True)

    btn_group = QButtonGroup()
    btn_group.addButton(radio_youtube, 0)
    btn_group.addButton(radio_apmp, 1)

    mode_layout.addWidget(radio_youtube)
    mode_layout.addWidget(radio_apmp)

    # Baseline option (APMP only)
    baseline_layout = QHBoxLayout()
    baseline_label = QLabel("    Camera baseline:")
    baseline_spin = QSpinBox()
    baseline_spin.setRange(10, 200)
    baseline_spin.setValue(65)
    baseline_spin.setSuffix(" mm")
    baseline_spin.setToolTip("Distance between camera lens centers (65mm = human IPD)")
    baseline_layout.addWidget(baseline_label)
    baseline_layout.addWidget(baseline_spin)
    baseline_layout.addStretch()
    mode_layout.addLayout(baseline_layout)

    layout.addWidget(mode_group)

    def on_mode_changed(btn_id):
        is_apmp = btn_id == 1
        baseline_label.setEnabled(is_apmp)
        baseline_spin.setEnabled(is_apmp)
    btn_group.idToggled.connect(on_mode_changed)

    # Overwrite option
    from PyQt6.QtWidgets import QCheckBox
    overwrite_cb = QCheckBox("Overwrite original file (no copy)")
    overwrite_cb.setToolTip("Modify the input file in-place instead of creating a new file.\nOnly adds ~100 bytes — safe and instant.")
    layout.addWidget(overwrite_cb)

    # Inject button + status
    btn_layout = QHBoxLayout()
    inject_btn = QPushButton("Inject Metadata")
    inject_btn.setFixedHeight(40)
    inject_btn.setFixedWidth(200)
    inject_btn.setStyleSheet(
        "QPushButton { background-color: #0066cc; color: white; font-size: 14px; border-radius: 6px; }"
        "QPushButton:hover { background-color: #0055aa; }"
    )
    btn_layout.addStretch()
    btn_layout.addWidget(inject_btn)
    btn_layout.addStretch()
    layout.addLayout(btn_layout)

    status = QLabel("")
    status.setAlignment(Qt.AlignmentFlag.AlignCenter)
    status.setStyleSheet("color: #333; font-style: italic;")
    layout.addWidget(status)

    layout.addStretch()

    credit = QLabel("by Siyang Qi — no re-encoding, instant injection")
    credit.setAlignment(Qt.AlignmentFlag.AlignCenter)
    credit.setStyleSheet("color: #999; font-size: 11px;")
    layout.addWidget(credit)

    # Handlers
    input_path = [None]

    def browse():
        path, _ = QFileDialog.getOpenFileName(
            win, "Select Video File", "",
            "Video Files (*.mp4 *.mov *.m4v);;All Files (*)"
        )
        if path:
            input_path[0] = Path(path)
            input_edit.setText(path)
            status.setText("")

    def inject():
        if not input_path[0] or not input_path[0].exists():
            QMessageBox.warning(win, "No File", "Please select an input video file.")
            return

        inp = input_path[0]
        mode = btn_group.checkedId()

        if overwrite_cb.isChecked():
            out_path = str(inp)
            confirm = QMessageBox.question(win, "Overwrite?",
                f"Overwrite the original file?\n\n{inp.name}\n\nThis modifies the file in-place (only adds ~100 bytes).",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
            if confirm != QMessageBox.StandardButton.Yes:
                return
        else:
            suffix = "_youtube_vr180" if mode == 0 else "_visionpro_vr180"
            out = inp.parent / f"{inp.stem}{suffix}{inp.suffix}"
            out_path, _ = QFileDialog.getSaveFileName(
                win, "Save Output File", str(out),
                "Video Files (*.mp4 *.mov);;All Files (*)"
            )
            if not out_path:
                return

        try:
            status.setText("Injecting metadata...")
            status.setStyleSheet("color: #0066cc; font-style: italic;")
            app.processEvents()

            if mode == 0:
                inject_youtube_vr180(inp, out_path)
                status.setText(f"YouTube VR180 metadata injected: {Path(out_path).name}")
            else:
                baseline = baseline_spin.value()
                inject_apmp_vr180(inp, out_path, baseline_mm=float(baseline))
                status.setText(f"Vision Pro APMP injected ({baseline}mm): {Path(out_path).name}")

            status.setStyleSheet("color: #008800; font-style: normal; font-weight: bold;")
            QMessageBox.information(win, "Done",
                f"Metadata injected successfully!\n\n{Path(out_path).name}")

        except Exception as e:
            status.setText(f"Error: {e}")
            status.setStyleSheet("color: #cc0000; font-style: normal;")
            QMessageBox.critical(win, "Error", f"Injection failed:\n\n{str(e)}")

    browse_btn.clicked.connect(browse)
    inject_btn.clicked.connect(inject)

    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
