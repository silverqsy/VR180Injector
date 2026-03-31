// VR180 Injector by Siyang Qi
// Native macOS app to inject VR180 metadata into SBS H.265 files.
// No re-encoding — instant metadata injection (~100 bytes added).
//
// Build: swiftc -O -o "VR180 Injector" VR180Injector.swift -framework SwiftUI -framework AppKit
// Or:    swift build (with Package.swift)

import SwiftUI
import AppKit
import Foundation

// MARK: - MP4 Atom Engine

/// Read a big-endian UInt32 from Data at offset
func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { ptr in
        ptr.load(fromByteOffset: offset, as: UInt32.self).bigEndian
    }
}

/// Read a big-endian UInt64 from Data at offset
func readU64(_ data: Data, _ offset: Int) -> UInt64 {
    data.withUnsafeBytes { ptr in
        ptr.load(fromByteOffset: offset, as: UInt64.self).bigEndian
    }
}

/// Write a big-endian UInt32 into Data at offset
func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.replaceSubrange(offset..<offset+4, with: $0) }
}

/// Write a big-endian UInt64 into Data at offset
func writeU64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.replaceSubrange(offset..<offset+8, with: $0) }
}

/// Build a Data from UInt32 big-endian
func packU32(_ value: UInt32) -> Data {
    var be = value.bigEndian
    return Data(bytes: &be, count: 4)
}

/// Find an atom by 4CC tag within a Data buffer range. Returns (offset, size) or nil.
/// Handles 64-bit extended sizes (sz==1) and extends-to-end (sz==0).
func findAtom(in buf: Data, start: Int, end: Int, tag: Data) -> (offset: Int, size: Int)? {
    var pos = start
    while pos < end - 8 {
        var sz = Int(readU32(buf, pos))
        let t = buf[pos+4..<pos+8]
        if sz == 1 && pos + 16 <= end {
            sz = Int(readU64(buf, pos + 8))
        } else if sz == 0 {
            sz = end - pos
        }
        if sz < 8 || pos + sz > end { break }
        if t == tag { return (pos, sz) }
        pos += sz
    }
    return nil
}

/// Find the video trak (contains "vide" handler) inside moov buffer
func findVideoTrak(in buf: Data, moovOff: Int, moovSz: Int) -> (offset: Int, size: Int)? {
    var pos = moovOff + 8
    let end = moovOff + moovSz
    let trakTag = "trak".data(using: .ascii)!
    let videTag = "vide".data(using: .ascii)!
    while pos < end - 8 {
        let sz = Int(readU32(buf, pos))
        let t = buf[pos+4..<pos+8]
        if sz < 8 || pos + sz > end { break }
        if t == trakTag {
            let trakData = buf[pos..<pos+sz]
            if trakData.range(of: videTag) != nil {
                return (pos, sz)
            }
        }
        pos += sz
    }
    return nil
}

/// Scan a file for the moov atom position without loading the entire file.
/// Returns (fileOffset, size, fileSize) or throws.
func scanForMoov(at url: URL) throws -> (offset: UInt64, size: Int, fileSize: UInt64) {
    let fh = try FileHandle(forReadingFrom: url)
    defer { fh.closeFile() }
    let fsize = fh.seekToEndOfFile()
    fh.seek(toFileOffset: 0)

    while fh.offsetInFile < fsize {
        let pos = fh.offsetInFile
        guard let hdr = readExact(fh, count: 8) else { break }
        var sz = UInt64(readU32(hdr, 0))
        let tag = hdr[4..<8]
        if sz == 1 {
            guard let ext = readExact(fh, count: 8) else { break }
            sz = readU64(ext, 0)
        } else if sz == 0 {
            sz = fsize - pos
        }
        if sz < 8 { break }
        if tag == "moov".data(using: .ascii)! {
            return (pos, Int(sz), fsize)
        }
        fh.seek(toFileOffset: pos + sz)
    }
    throw InjectorError.moovNotFound
}

/// Read exactly `count` bytes from a FileHandle, or nil if not enough data
func readExact(_ fh: FileHandle, count: Int) -> Data? {
    let d = fh.readData(ofLength: count)
    return d.count == count ? d : nil
}

// MARK: - Atom Builders

/// Build YouTube VR180 atoms: st3d + sv3d (Google Spherical Video V2)
func buildYouTubeAtoms() -> Data {
    // st3d: version(4) + stereo_mode(1)=0x02 (leftRight)
    let st3d = packU32(13) + "st3d".data(using: .ascii)! + Data([0,0,0,0, 0x02])

    // svhd: version(4) + empty string + null
    let svhd = packU32(13) + "svhd".data(using: .ascii)! + Data([0,0,0,0, 0])

    // prhd: version(4) + yaw(4) + pitch(4) + roll(4) = all zeros
    let prhd = packU32(24) + "prhd".data(using: .ascii)! + Data(count: 16)

    // equi: version(4) + top(4)=0 + bottom(4)=0 + left(4)=0x3FFFFFFF + right(4)=0x3FFFFFFF
    let equi = packU32(28) + "equi".data(using: .ascii)!
        + packU32(0) + packU32(0) + packU32(0) + packU32(0x3FFFFFFF) + packU32(0x3FFFFFFF)

    let proj = packU32(UInt32(8 + prhd.count + equi.count)) + "proj".data(using: .ascii)! + prhd + equi
    let sv3d = packU32(UInt32(8 + svhd.count + proj.count)) + "sv3d".data(using: .ascii)! + svhd + proj

    return st3d + sv3d
}

/// Build Vision Pro APMP atoms: vexu + hfov
func buildAPMPAtoms(baselineMM: Double) -> Data {
    // eyes/stri: stereo = 0x03 (side-by-side)
    let stri = packU32(13) + "stri".data(using: .ascii)! + Data([0,0,0,0, 0x03])
    let eyes = packU32(UInt32(8 + stri.count)) + "eyes".data(using: .ascii)! + stri

    // proj/prji: halfEquirectangular
    let prji = packU32(16) + "prji".data(using: .ascii)! + Data([0,0,0,0]) + "hequ".data(using: .ascii)!
    let proj = packU32(UInt32(8 + prji.count)) + "proj".data(using: .ascii)! + prji

    // pack/pkin: sideBySide
    let pkin = packU32(16) + "pkin".data(using: .ascii)! + Data([0,0,0,0]) + "side".data(using: .ascii)!
    let pack = packU32(UInt32(8 + pkin.count)) + "pack".data(using: .ascii)! + pkin

    // cams/blin: baseline in mm (fixed-point * 65536)
    let blinVal = UInt32(baselineMM * 65536) & 0xFFFFFFFF
    let blin = packU32(12) + "blin".data(using: .ascii)! + packU32(blinVal)
    let cams = packU32(UInt32(8 + blin.count)) + "cams".data(using: .ascii)! + blin

    let vexu = packU32(UInt32(8 + eyes.count + proj.count + pack.count + cams.count))
        + "vexu".data(using: .ascii)! + eyes + proj + pack + cams

    // hfov: 180.0 degrees = 180000
    let hfov = packU32(12) + "hfov".data(using: .ascii)! + packU32(180000)

    return vexu + hfov
}

// MARK: - Core Injection

enum InjectorError: LocalizedError {
    case moovNotFound
    case videoTrakNotFound
    case mdiaNotFound, minfNotFound, stblNotFound, stsdNotFound
    case hvc1NotFound

    var errorDescription: String? {
        switch self {
        case .moovNotFound: return "moov atom not found"
        case .videoTrakNotFound: return "Video track not found"
        case .mdiaNotFound: return "mdia atom not found"
        case .minfNotFound: return "minf atom not found"
        case .stblNotFound: return "stbl atom not found"
        case .stsdNotFound: return "stsd atom not found"
        case .hvc1NotFound: return "hvc1/hev1 not found — file must be H.265/HEVC"
        }
    }
}

let stripTags: Set<Data> = [
    "st3d".data(using: .ascii)!,
    "sv3d".data(using: .ascii)!,
    "vexu".data(using: .ascii)!,
    "hfov".data(using: .ascii)!,
]

func injectAtoms(inputURL: URL, outputURL: URL, injectData: Data) throws {
    let inPlace = inputURL.standardizedFileURL == outputURL.standardizedFileURL
    if !inPlace {
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.copyItem(at: inputURL, to: outputURL)
    }

    // Step 1: Scan for moov
    let (moovFileOff, moovFileSz, fsize) = try scanForMoov(at: outputURL)

    // Step 2: Read only moov
    let fh = try FileHandle(forReadingFrom: outputURL)
    fh.seek(toFileOffset: moovFileOff)
    var data = fh.readData(ofLength: moovFileSz)
    fh.closeFile()

    // Walk: moov → trak(video) → mdia → minf → stbl → stsd → hvc1
    let moovTag = "moov".data(using: .ascii)!
    guard let moov = findAtom(in: data, start: 0, end: data.count, tag: moovTag) else {
        throw InjectorError.moovNotFound
    }
    guard let trak = findVideoTrak(in: data, moovOff: moov.offset, moovSz: moov.size) else {
        throw InjectorError.videoTrakNotFound
    }
    guard let mdia = findAtom(in: data, start: trak.offset+8, end: trak.offset+trak.size,
                              tag: "mdia".data(using: .ascii)!) else { throw InjectorError.mdiaNotFound }
    guard let minf = findAtom(in: data, start: mdia.offset+8, end: mdia.offset+mdia.size,
                              tag: "minf".data(using: .ascii)!) else { throw InjectorError.minfNotFound }
    guard let stbl = findAtom(in: data, start: minf.offset+8, end: minf.offset+minf.size,
                              tag: "stbl".data(using: .ascii)!) else { throw InjectorError.stblNotFound }
    guard let stsd = findAtom(in: data, start: stbl.offset+8, end: stbl.offset+stbl.size,
                              tag: "stsd".data(using: .ascii)!) else { throw InjectorError.stsdNotFound }

    var hvc1 = findAtom(in: data, start: stsd.offset+16, end: stsd.offset+stsd.size,
                         tag: "hvc1".data(using: .ascii)!)
    if hvc1 == nil {
        hvc1 = findAtom(in: data, start: stsd.offset+16, end: stsd.offset+stsd.size,
                          tag: "hev1".data(using: .ascii)!)
    }
    guard let hvc1 = hvc1 else { throw InjectorError.hvc1NotFound }

    // Rebuild hvc1: keep header(86 bytes) + non-stripped sub-atoms + new inject data
    let hvc1Header = data[hvc1.offset..<hvc1.offset+86]
    var kept = Data()
    var pos = hvc1.offset + 86
    let hvc1End = hvc1.offset + hvc1.size
    while pos < hvc1End - 8 {
        let asz = Int(readU32(data, pos))
        if asz < 8 || pos + asz > hvc1End { break }
        let atag = data[pos+4..<pos+8]
        if !stripTags.contains(atag) {
            kept.append(data[pos..<pos+asz])
        }
        pos += asz
    }

    let newBody = kept + injectData
    let newHvc1Sz = 86 + newBody.count
    var newHvc1 = packU32(UInt32(newHvc1Sz))
    newHvc1.append(hvc1Header[hvc1.offset+4..<hvc1.offset+86])
    newHvc1.append(newBody)
    let sizeDelta = newHvc1Sz - hvc1.size

    // Replace hvc1
    data.replaceSubrange(hvc1.offset..<hvc1.offset+hvc1.size, with: newHvc1)

    // Update parent chain sizes
    for parent in [stsd, stbl, minf, mdia, trak, moov] {
        let oldSz = readU32(data, parent.offset)
        writeU32(&data, parent.offset, oldSz + UInt32(Int32(sizeDelta)))
    }

    // Fix chunk offsets if moov is before mdat
    let moovAtEnd = (moovFileOff + UInt64(moovFileSz) >= fsize)
    if sizeDelta != 0 && !moovAtEnd {
        for tagStr in ["stco", "co64"] {
            let tag = tagStr.data(using: .ascii)!
            var searchPos = 0
            while true {
                guard let range = data[searchPos...].range(of: tag) else { break }
                let idx = range.lowerBound
                if idx < 4 { break }
                let atomSz = Int(readU32(data, idx - 4))
                let n = Int(readU32(data, idx + 8))
                if tagStr == "stco" {
                    for e in 0..<n {
                        let eoff = idx + 12 + e * 4
                        let v = readU32(data, eoff)
                        writeU32(&data, eoff, UInt32(Int(v) + sizeDelta))
                    }
                } else {
                    for e in 0..<n {
                        let eoff = idx + 12 + e * 8
                        let v = readU64(data, eoff)
                        writeU64(&data, eoff, UInt64(Int64(v) + Int64(sizeDelta)))
                    }
                }
                searchPos = idx + atomSz
            }
        }
    }

    // Write back moov only
    if moovAtEnd {
        let wh = try FileHandle(forWritingTo: outputURL)
        wh.seek(toFileOffset: moovFileOff)
        wh.write(data)
        wh.truncateFile(atOffset: moovFileOff + UInt64(data.count))
        wh.closeFile()
    } else {
        // moov before mdat: read after-moov, rewrite
        let rh = try FileHandle(forReadingFrom: outputURL)
        rh.seek(toFileOffset: moovFileOff + UInt64(moovFileSz))
        let afterMoov = rh.readData(ofLength: Int(fsize - moovFileOff - UInt64(moovFileSz)))
        rh.closeFile()

        let wh = try FileHandle(forWritingTo: outputURL)
        wh.seek(toFileOffset: moovFileOff)
        wh.write(data)
        wh.write(afterMoov)
        wh.truncateFile(atOffset: moovFileOff + UInt64(data.count + afterMoov.count))
        wh.closeFile()
    }
}

// MARK: - SwiftUI App

enum InjectionMode: String, CaseIterable {
    case youtube = "YouTube VR180"
    case apmp = "Vision Pro APMP"
}

class InjectorModel: ObservableObject {
    @Published var inputURL: URL? = nil
    @Published var mode: InjectionMode = .apmp
    @Published var baseline: Int = 63
    @Published var overwrite: Bool = false
    @Published var status: String = ""
    @Published var statusColor: NSColor = .secondaryLabelColor
    @Published var isProcessing = false

    var inputName: String { inputURL?.lastPathComponent ?? "" }

    func inject() {
        guard let input = inputURL else {
            showStatus("No input file selected", color: .systemRed)
            return
        }

        isProcessing = true
        showStatus("Injecting metadata...", color: .systemBlue)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let output: URL
                if overwrite {
                    output = input
                } else {
                    let suffix = mode == .youtube ? "_youtube_vr180" : "_visionpro_vr180"
                    let stem = input.deletingPathExtension().lastPathComponent
                    let ext = input.pathExtension
                    output = input.deletingLastPathComponent()
                        .appendingPathComponent("\(stem)\(suffix).\(ext)")
                    // For non-overwrite, let user pick via save panel on main thread
                    // (simplified: just use default path)
                }

                let atoms: Data
                switch mode {
                case .youtube: atoms = buildYouTubeAtoms()
                case .apmp:    atoms = buildAPMPAtoms(baselineMM: Double(baseline))
                }

                try injectAtoms(inputURL: input, outputURL: output, injectData: atoms)

                let label = mode == .youtube ? "YouTube VR180" : "Vision Pro APMP (\(baseline)mm)"
                DispatchQueue.main.async {
                    self.showStatus("\(label) injected: \(output.lastPathComponent)", color: .systemGreen)
                    self.isProcessing = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.showStatus("Error: \(error.localizedDescription)", color: .systemRed)
                    self.isProcessing = false
                }
            }
        }
    }

    func showStatus(_ msg: String, color: NSColor) {
        DispatchQueue.main.async {
            self.status = msg
            self.statusColor = color
        }
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            inputURL = panel.url
            status = ""
        }
    }
}

struct ContentView: View {
    @StateObject var model = InjectorModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("VR180 Metadata Injector")
                .font(.title).bold()
            Text("Inject VR180 metadata into SBS H.265 files — no re-encoding")
                .foregroundColor(.secondary).font(.caption)

            // Input
            GroupBox("Input") {
                HStack {
                    TextField("Select a SBS video file (.mp4, .mov)", text: .constant(model.inputName))
                        .textFieldStyle(.roundedBorder).disabled(true)
                    Button("Browse") { model.browse() }
                }
            }

            // Mode
            GroupBox("Injection Mode") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $model.mode) {
                        ForEach(InjectionMode.allCases, id: \.self) { mode in
                            Text(mode == .youtube
                                 ? "YouTube VR180  (st3d + sv3d)"
                                 : "Vision Pro APMP  (vexu + hfov, visionOS 26+)")
                                .tag(mode)
                        }
                    }.pickerStyle(.radioGroup).labelsHidden()

                    if model.mode == .apmp {
                        HStack {
                            Text("Camera baseline:")
                            TextField("63", value: $model.baseline, format: .number)
                                .frame(width: 70)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.center)
                            Text("mm")
                        }.padding(.leading, 20)
                    }
                }
            }

            Toggle("Overwrite original file (no copy)", isOn: $model.overwrite)
                .toggleStyle(.checkbox)

            Button(action: { model.inject() }) {
                Text("Inject Metadata")
                    .frame(width: 180, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.inputURL == nil || model.isProcessing)

            Text(model.status)
                .foregroundColor(Color(model.statusColor))
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            Spacer()

            Text("by Siyang Qi — no re-encoding, instant injection")
                .foregroundColor(.secondary).font(.caption2)
        }
        .padding()
        .frame(width: 520, height: 420)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            if let provider = providers.first {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async { model.inputURL = url }
                    }
                }
            }
            return true
        }
    }
}

@main
struct VR180InjectorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
