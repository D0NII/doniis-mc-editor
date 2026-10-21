// DONII's MC Editor – Minecraft-Sounds & -Texturen ansehen, abspielen, ersetzen, exportieren
// macOS 14+ · SwiftUI · Build: bash build.sh
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Hilfsfunktionen

struct MCError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@discardableResult
func run(_ exe: String, _ args: [String], cwd: URL? = nil, stdin: URL? = nil) throws -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    if let stdin { p.standardInput = try FileHandle(forReadingFrom: stdin) }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func findFFmpeg() -> String? {
    ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

func normalize(_ s: String) -> String {
    String(s.lowercased().map { "_/.:-".contains($0) ? " " : $0 })
}

/// Alle Dateien (relative Pfade) unterhalb von root.
func relFiles(_ root: URL) -> [String] {
    let base = root.resolvingSymlinksInPath().path
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
    var out: [String] = []
    for case let u as URL in en {
        let isFile = (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isFile else { continue }
        let p = u.resolvingSymlinksInPath().path
        guard p.hasPrefix(base + "/") else { continue }
        let rel = String(p.dropFirst(base.count + 1))
        if rel.hasSuffix(".DS_Store") || rel.hasPrefix("__MACOSX/") { continue }
        out.append(rel)
    }
    return out.sorted()
}

func loadFileURL(_ providers: [NSItemProvider], _ done: @escaping @Sendable (URL) -> Void) -> Bool {
    guard let p = providers.first else { return false }
    _ = p.loadObject(ofClass: URL.self) { url, _ in
        if let url { done(url) }
    }
    return true
}

/// macOS kann .ogg (Vorbis) nicht nativ abspielen → für die Vorschau per ffmpeg nach WAV.
func decodeToWav(_ src: URL) throws -> URL {
    guard let ff = findFFmpeg() else {
        throw MCError("Für die Vorschau fehlt ffmpeg (macOS spielt .ogg nicht nativ ab). Im Terminal: brew install ffmpeg")
    }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("MCAssetStudio-preview", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let date = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    let stamp = Int((date?.timeIntervalSince1970 ?? 0) * 1000)
    let out = dir.appendingPathComponent("\(abs(src.path.hashValue))_\(stamp).wav")
    if fm.fileExists(atPath: out.path) { return out }
    let r = try run(ff, ["-v", "error", "-y", "-i", src.path, "-vn", "-c:a", "pcm_s16le", out.path])
    if r.code != 0 { throw MCError("ffmpeg konnte die Datei nicht dekodieren: \(r.output)") }
    return out
}

// MARK: - Datenmodell

struct Asset: Identifiable, Hashable {
    enum Kind { case sound, texture }
    let id: String          // relativer Pfad, z. B. assets/minecraft/sounds/block/stone/break1.ogg
    let kind: Kind
    let events: [String]    // Sound-Events aus sounds.json, z. B. block.stone.break
    let subtitle: String    // Untertitel-Text (de/en), z. B. „Block abgebaut“
    let searchKey: String
    var name: String { (id as NSString).lastPathComponent }
    var folder: String { (id as NSString).deletingLastPathComponent }
}

struct Node: Identifiable, Hashable {
    let id: String
    let name: String
    var children: [Node]?   // nil = Datei
}

enum Tree {
    final class Builder { var kids: [String: Builder] = [:]; var isFile = false }

    static func build(_ assets: [Asset]) -> [Node] {
        let root = Builder()
        for a in assets {
            var cur = root
            for part in a.id.split(separator: "/") {
                let k = String(part)
                if let n = cur.kids[k] { cur = n } else { let n = Builder(); cur.kids[k] = n; cur = n }
            }
            cur.isFile = true
        }
        func convert(_ b: Builder, _ prefix: String) -> [Node] {
            let names = b.kids.keys.sorted { x, y in
                let fx = b.kids[x]!.isFile, fy = b.kids[y]!.isFile
                if fx != fy { return !fx }   // Ordner zuerst
                return x.localizedStandardCompare(y) == .orderedAscending
            }
            return names.map { n in
                let kid = b.kids[n]!
                let id = prefix.isEmpty ? n : prefix + "/" + n
                return Node(id: id, name: n, children: kid.isFile ? nil : convert(kid, id))
            }
        }
        return convert(root, "")
    }
}

struct SoundMeta {
    var events: [String: Set<String>] = [:]      // Dateipfad → Events
    var eventSubtitle: [String: String] = [:]    // Event → Untertitel-Key
    var lang: [String: String] = [:]
}

func parseSoundMeta(_ root: URL) -> SoundMeta {
    var meta = SoundMeta()
    let assetsDir = root.appendingPathComponent("assets")
    for ns in (try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path)) ?? [] {
        let jsonURL = assetsDir.appendingPathComponent(ns).appendingPathComponent("sounds.json")
        guard let d = try? Data(contentsOf: jsonURL),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        for (event, value) in obj {
            guard let e = value as? [String: Any] else { continue }
            let evName = ns == "minecraft" ? event : "\(ns):\(event)"
            if let sub = e["subtitle"] as? String { meta.eventSubtitle[evName] = sub }
            for s in (e["sounds"] as? [Any]) ?? [] {
                var name: String?
                var type = "file"
                if let str = s as? String { name = str }
                else if let dict = s as? [String: Any] {
                    name = dict["name"] as? String
                    type = (dict["type"] as? String) ?? "file"
                }
                guard let n = name, type == "file" else { continue }
                let parts = n.split(separator: ":", maxSplits: 1).map(String.init)
                let (sns, path) = parts.count == 2 ? (parts[0], parts[1]) : ("minecraft", n)
                meta.events["assets/\(sns)/sounds/\(path).ogg", default: []].insert(evName)
            }
        }
    }
    for l in ["en_us", "de_de"] {   // Deutsch überschreibt Englisch
        let u = assetsDir.appendingPathComponent("minecraft/lang/\(l).json")
        if let d = try? Data(contentsOf: u),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            meta.lang.merge(dict) { _, new in new }
        }
    }
    return meta
}

// MARK: - Laden (.jar / .zip / Ordner + Asset-Index des Launchers)

struct Loaded {
    var work: URL
    var root: URL
    var isJar: Bool
    var packFiles: Set<String>
    var indexed: Set<String>
    var assets: [Asset]
    var note: String
}

enum Loader {
    static func load(_ src: URL) throws -> Loaded {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MCAssetStudio-\(UUID().uuidString)", isDirectory: true)
        var root = work.appendingPathComponent("content", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: src.path, isDirectory: &isDir)
        if isDir.boolValue {
            try fm.removeItem(at: root)
            try fm.copyItem(at: src, to: root)
        } else {
            let r = try run("/usr/bin/unzip", ["-q", "-o", src.path, "-d", root.path])
            if r.code > 1 { throw MCError("Entpacken fehlgeschlagen: \(r.output)") }
        }
        // Falls der Inhalt in einem Unterordner steckt
        if !fm.fileExists(atPath: root.appendingPathComponent("assets").path),
           let subs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
           let hit = subs.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("assets").path) }) {
            root = hit
        }
        root = root.resolvingSymlinksInPath()

        let isJar = src.pathExtension.lowercased() == "jar"
            || fm.fileExists(atPath: root.appendingPathComponent("version.json").path)

        // Sounds liegen NICHT in der .jar, sondern im Asset-Index des Launchers → einzeln dazukopieren
        var indexed = Set<String>()
        if let idx = findAssetIndex(src: src, root: root),
           let d = try? Data(contentsOf: idx),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let objs = j["objects"] as? [String: Any] {
            let objDir = idx.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("objects")
            for (key, v) in objs {
                let wanted = key.hasPrefix("minecraft/sounds/") || key == "minecraft/sounds.json"
                    || key == "minecraft/lang/de_de.json" || key == "minecraft/lang/en_us.json"
                guard wanted, let h = (v as? [String: Any])?["hash"] as? String, h.count > 2 else { continue }
                let rel = "assets/" + key
                let dest = root.appendingPathComponent(rel)
                if fm.fileExists(atPath: dest.path) { continue }
                let obj = objDir.appendingPathComponent(String(h.prefix(2))).appendingPathComponent(h)
                guard fm.fileExists(atPath: obj.path) else { continue }
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.copyItem(at: obj, to: dest)) != nil { indexed.insert(rel) }
            }
        }

        let files = relFiles(root)
        let meta = parseSoundMeta(root)
        var assets: [Asset] = []
        for f in files {
            let l = f.lowercased()
            if l.hasSuffix(".ogg"), f.contains("/sounds/") {
                let ev = (meta.events[f] ?? []).sorted()
                let sub = ev.compactMap { meta.eventSubtitle[$0] }.compactMap { meta.lang[$0] }.first ?? ""
                assets.append(Asset(id: f, kind: .sound, events: ev, subtitle: sub,
                                    searchKey: normalize(([f] + ev + [sub]).joined(separator: " "))))
            } else if l.hasSuffix(".png"), f.contains("/textures/") {
                assets.append(Asset(id: f, kind: .texture, events: [], subtitle: "", searchKey: normalize(f)))
            }
        }
        var note = ""
        if !assets.contains(where: { $0.kind == .sound }) {
            note = "Keine Sounds gefunden – Version einmal im Minecraft-Launcher starten, damit die Sound-Dateien geladen sind."
        }
        return Loaded(work: work, root: root, isJar: isJar,
                      packFiles: isJar ? [] : Set(files).subtracting(indexed),
                      indexed: indexed, assets: assets, note: note)
    }

    static func findAssetIndex(src: URL, root: URL) -> URL? {
        let fm = FileManager.default
        var mcDirs: [URL] = []
        let comps = src.pathComponents
        if let i = comps.lastIndex(of: "versions"), i > 0 {
            mcDirs.append(URL(fileURLWithPath: NSString.path(withComponents: Array(comps[..<i]))))
        }
        mcDirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/minecraft"))

        var versionIDs = [src.deletingPathExtension().lastPathComponent]
        if let d = try? Data(contentsOf: root.appendingPathComponent("version.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let id = j["id"] as? String { versionIDs.insert(id, at: 0) }

        for mc in mcDirs {
            for v in versionIDs {
                let vj = mc.appendingPathComponent("versions/\(v)/\(v).json")
                if let d = try? Data(contentsOf: vj),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let ai = (j["assetIndex"] as? [String: Any])?["id"] as? String {
                    let idx = mc.appendingPathComponent("assets/indexes/\(ai).json")
                    if fm.fileExists(atPath: idx.path) { return idx }
                }
            }
        }
        // Fallback: neuester installierter Index
        func stamp(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        for mc in mcDirs {
            let dir = mc.appendingPathComponent("assets/indexes")
            let items = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
            if let newest = items.max(by: { stamp($0) < stamp($1) }) { return newest }
        }
        return nil
    }
}

// MARK: - Umwandlung & Export

enum Convert {
    static func toOgg(_ src: URL, out: URL, mono: Bool) throws {
        if src.pathExtension.lowercased() == "ogg" { try FileManager.default.copyItem(at: src, to: out); return }
        guard let ff = findFFmpeg() else { throw MCError("ffmpeg fehlt (nötig, um eigene Sounds in .ogg/Vorbis zu wandeln). Im Terminal: brew install ffmpeg") }
        var args = ["-v", "error", "-y", "-i", src.path, "-vn"]
        if mono { args += ["-ac", "1"] }
        args += ["-c:a", "libvorbis", "-q:a", "5", out.path]
        let r = try run(ff, args)
        if r.code != 0 { throw MCError("ffmpeg: \(r.output)") }
    }

    static func toPNG(_ src: URL, out: URL) throws {
        if src.pathExtension.lowercased() == "png" { try FileManager.default.copyItem(at: src, to: out); return }
        guard let img = NSImage(contentsOf: src), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw MCError("Bild konnte nicht gelesen werden.") }
        try png.write(to: out)
    }
}

enum Export {
    /// Texturepack (.zip): nur geänderte Dateien (bzw. der Inhalt des geladenen Packs) + pack.mcmeta
    static func pack(root: URL, paths: [String], fromJar: Bool, dest: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("MCAssetStudio-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        for p in paths {
            let d = stage.appendingPathComponent(p)
            try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: root.appendingPathComponent(p), to: d)
        }
        if fromJar {
            // Pack-Format-Angaben direkt aus der pack.mcmeta der .jar übernehmen (passt automatisch zur Version)
            var pack: [String: Any] = ["pack_format": 75]   // nur Fallback
            if let d = try? Data(contentsOf: root.appendingPathComponent("pack.mcmeta")),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let p = j["pack"] as? [String: Any] { pack = p }
            pack["description"] = "Erstellt mit DONII's MC Editor"
            let data = try JSONSerialization.data(withJSONObject: ["pack": pack], options: [.prettyPrinted])
            try data.write(to: stage.appendingPathComponent("pack.mcmeta"))
            let icon = root.appendingPathComponent("pack.png")
            if fm.fileExists(atPath: icon.path) { try? fm.copyItem(at: icon, to: stage.appendingPathComponent("pack.png")) }
        }
        try? fm.removeItem(at: dest)
        let r = try run("/usr/bin/zip", ["-r", "-X", "-q", dest.path, "."], cwd: stage)
        if r.code != 0 { throw MCError("zip fehlgeschlagen: \(r.output)") }
    }

    /// Komplette .jar neu packen (Original-Inhalt + Änderungen, ohne die vom Launcher dazukopierten, unveränderten Dateien)
    static func jar(root: URL, skip: Set<String>, dest: URL) throws {
        let fm = FileManager.default
        let list = fm.temporaryDirectory.appendingPathComponent("MCAssetStudio-\(UUID().uuidString).txt")
        defer { try? fm.removeItem(at: list) }
        let names = relFiles(root).filter { !skip.contains($0) }
        try names.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: dest)
        let r = try run("/usr/bin/zip", ["-X", "-q", dest.path, "-@"], cwd: root, stdin: list)
        if r.code != 0 { throw MCError("zip fehlgeschlagen: \(r.output)") }
    }
}

// MARK: - Store

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "Alle", sounds = "Sounds", textures = "Texturen"
    var id: String { rawValue }
}

@MainActor
final class Store: ObservableObject {
    @Published var query = ""
    @Published var filter: KindFilter = .all
    @Published var selection: String?
    @Published var expanded: Set<String> = []
    @Published var status = "Bereit – .jar oder Texturepack hineinziehen"
    @Published var alert: String?
    @Published private(set) var tree: [Node] = []
    @Published private(set) var assets: [Asset] = []
    @Published private(set) var modified: Set<String> = []
    @Published private(set) var root: URL?
    @Published private(set) var isJar = false
    @Published private(set) var revision = 0
    @Published private(set) var busy = false
    private(set) var assetByID: [String: Asset] = [:]
    private var sourceName = "minecraft"
    private var workDir: URL?
    private var packFiles = Set<String>()
    private var indexed = Set<String>()

    func url(for id: String) -> URL { root?.appendingPathComponent(id) ?? URL(fileURLWithPath: "/") }

    // Öffnen
    func openPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = "Minecraft-.jar (…/minecraft/versions/<Version>/<Version>.jar), Texturepack (.zip) oder Ordner wählen"
        let versions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/minecraft/versions")
        if FileManager.default.fileExists(atPath: versions.path) { p.directoryURL = versions }
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func open(_ src: URL) {
        guard !busy else { return }
        busy = true
        status = "Entpacke \(src.lastPathComponent) und lese Sounds …"
        Task.detached { [self] in
            do {
                let r = try Loader.load(src)
                await MainActor.run { self.apply(r, src: src) }
            } catch {
                await MainActor.run { self.busy = false; self.status = "Fehler"; self.alert = error.localizedDescription }
            }
        }
    }

    private func apply(_ r: Loaded, src: URL) {
        if let old = workDir, old != r.work { try? FileManager.default.removeItem(at: old) }
        workDir = r.work; root = r.root; isJar = r.isJar
        packFiles = r.packFiles; indexed = r.indexed
        assets = r.assets
        assetByID = Dictionary(uniqueKeysWithValues: r.assets.map { ($0.id, $0) })
        tree = Tree.build(r.assets)
        modified = []; selection = nil; query = ""
        expanded = ["assets", "assets/minecraft"]
        sourceName = src.deletingPathExtension().lastPathComponent
        busy = false
        let s = r.assets.filter { $0.kind == .sound }.count
        status = "\(src.lastPathComponent): \(s) Sounds, \(r.assets.count - s) Texturen" + (r.note.isEmpty ? "" : " – \(r.note)")
        revision += 1
    }

    // Suche & Navigation
    func results() -> [Asset] {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        return assets.filter { a in
            (filter == .all || (filter == .sounds && a.kind == .sound) || (filter == .textures && a.kind == .texture))
                && tokens.allSatisfy { a.searchKey.contains($0) }
        }
    }

    func expandAncestors(of path: String) {
        var acc = ""
        for part in path.split(separator: "/") {
            acc += (acc.isEmpty ? "" : "/") + String(part)
            expanded.insert(acc)
        }
    }

    func reveal(_ path: String) {
        expandAncestors(of: path)
        query = ""
        selection = path
    }

    // Ersetzen / Zurücksetzen
    func pickReplacement(_ a: Asset, mono: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.message = a.kind == .sound ? "Eigenen Sound wählen (ogg, wav, mp3, m4a, aiff …)" : "Eigene Textur wählen (PNG empfohlen)"
        if a.kind == .texture { p.allowedContentTypes = [.image] }
        if p.runModal() == .OK, let u = p.url { replace(a, with: u, mono: mono) }
    }

    func replace(_ a: Asset, with src: URL, mono: Bool) {
        guard let root, let work = workDir else { return }
        busy = true; status = "Ersetze \(a.name) …"
        let dest = root.appendingPathComponent(a.id)
        let backup = work.appendingPathComponent("backup").appendingPathComponent(a.id)
        let isSound = a.kind == .sound
        Task.detached { [self] in
            do {
                let fm = FileManager.default
                if !fm.fileExists(atPath: backup.path) {
                    try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: dest, to: backup)
                }
                let tmp = dest.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString)" + (isSound ? ".ogg" : ".png"))
                if isSound { try Convert.toOgg(src, out: tmp, mono: mono) } else { try Convert.toPNG(src, out: tmp) }
                try fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
                await MainActor.run {
                    self.modified.insert(a.id); self.revision += 1
                    self.busy = false; self.status = "\(a.name) ersetzt durch \(src.lastPathComponent)"
                }
            } catch {
                await MainActor.run { self.busy = false; self.status = "Fehler"; self.alert = error.localizedDescription }
            }
        }
    }

    func reset(_ a: Asset) {
        guard let root, let work = workDir else { return }
        let fm = FileManager.default
        let backup = work.appendingPathComponent("backup").appendingPathComponent(a.id)
        let dest = root.appendingPathComponent(a.id)
        guard fm.fileExists(atPath: backup.path) else { return }
        do {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: backup, to: dest)
            modified.remove(a.id); revision += 1
            status = "\(a.name) zurückgesetzt"
        } catch { alert = error.localizedDescription }
    }

    // Export
    private func runBusy(_ msg: String, _ work: @escaping @Sendable () throws -> URL?) {
        busy = true; status = msg
        Task.detached { [self] in
            do {
                let u = try work()
                await MainActor.run {
                    self.busy = false; self.status = "Fertig: \(u?.lastPathComponent ?? "")"
                    if let u { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
            } catch {
                await MainActor.run { self.busy = false; self.status = "Fehler"; self.alert = error.localizedDescription }
            }
        }
    }

    func exportAsset(_ a: Asset, wav: Bool = false) {
        let src = url(for: a.id)
        let p = NSSavePanel()
        p.nameFieldStringValue = wav ? (a.name as NSString).deletingPathExtension + ".wav" : a.name
        guard p.runModal() == .OK, let dest = p.url else { return }
        runBusy("Exportiere \(dest.lastPathComponent) …") {
            try? FileManager.default.removeItem(at: dest)
            if wav {
                guard let ff = findFFmpeg() else { throw MCError("ffmpeg fehlt – im Terminal: brew install ffmpeg") }
                let r = try run(ff, ["-v", "error", "-y", "-i", src.path, dest.path])
                if r.code != 0 { throw MCError(r.output) }
            } else {
                try FileManager.default.copyItem(at: src, to: dest)
            }
            return dest
        }
    }

    func exportPack() {
        guard let root else { return }
        let paths = Array(packFiles.union(modified)).sorted()
        if paths.isEmpty { alert = "Es wurde noch nichts geändert – ersetze zuerst einen Sound oder eine Textur."; return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(sourceName)-texturepack.zip"
        guard p.runModal() == .OK, let dest = p.url else { return }
        let jar = isJar
        runBusy("Erstelle Texturepack …") {
            try Export.pack(root: root, paths: paths, fromJar: jar, dest: dest)
            return dest
        }
    }

    func exportJar() {
        guard let root, isJar else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(sourceName)-modified.jar"
        guard p.runModal() == .OK, let dest = p.url else { return }
        let skip = indexed.subtracting(modified)
        runBusy("Packe .jar …") {
            try Export.jar(root: root, skip: skip, dest: dest)
            return dest
        }
    }
}

// MARK: - Audio-Vorschau

@MainActor
final class AudioPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var current: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var message = ""
    @Published var loop = false { didSet { player?.numberOfLoops = loop ? -1 : 0 } }
    @Published var volume: Float = 0.8 { didSet { player?.volume = volume } }
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var ticket = 0

    func load(_ url: URL, autoplay: Bool) {
        stop(); player = nil
        duration = 0; current = 0; message = "Lade Vorschau …"
        ticket += 1
        let mine = ticket
        Task.detached {
            let result = Result { try decodeToWav(url) }
            await MainActor.run { [weak self] in
                guard let self, self.ticket == mine else { return }
                switch result {
                case .success(let wav):
                    do {
                        let p = try AVAudioPlayer(contentsOf: wav)
                        p.delegate = self
                        p.volume = self.volume
                        p.numberOfLoops = self.loop ? -1 : 0
                        p.prepareToPlay()
                        self.player = p; self.duration = p.duration; self.message = ""
                        if autoplay { self.play() }
                    } catch { self.message = error.localizedDescription }
                case .failure(let e):
                    self.message = e.localizedDescription
                }
            }
        }
    }

    func play() {
        guard let p = player else { return }
        if p.currentTime >= p.duration - 0.01 { p.currentTime = 0 }
        p.play(); isPlaying = true; startTimer()
    }
    func pause() { player?.pause(); isPlaying = false; stopTimer() }
    func toggle() { if isPlaying { pause() } else { play() } }
    func stop() { player?.stop(); player?.currentTime = 0; current = 0; isPlaying = false; stopTimer() }
    func seek(_ t: TimeInterval) { player?.currentTime = t; current = t }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func tick() { if let p = player { current = p.currentTime } }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false; self.stopTimer(); self.current = 0 }
    }
}

func fmt(_ t: TimeInterval) -> String {
    String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

// MARK: - App

@main
struct MCAssetStudioApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("DONII's MC Editor") {
            ContentView().environmentObject(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Öffnen …") { store.openPanel() }.keyboardShortcut("o")
            }
        }
    }
}

// MARK: - Hauptfenster

/// Kleine UI-Flags als ObservableObject (statt @State).
@MainActor
final class UIFlags: ObservableObject {
    @Published var dropOver = false
    @Published var mono = true
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @StateObject private var audio = AudioPreview()
    @AppStorage("autoplay") private var autoplay = true
    @StateObject private var flags = UIFlags()

    private var selected: Asset? { store.selection.flatMap { store.assetByID[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            if store.root == nil { EmptyState() } else { split }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 980, minHeight: 620)
        .onDrop(of: [.fileURL], isTargeted: $flags.dropOver) { providers in
            loadFileURL(providers) { url in Task { @MainActor in store.open(url) } }
        }
        .overlay {
            if flags.dropOver {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .onChange(of: store.selection) { _, new in
            if let new { store.expandAncestors(of: new) }
            syncAudio()
        }
        .onChange(of: store.revision) { _, _ in syncAudio() }
        .alert("Hinweis", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK") {}
        } message: { Text(store.alert ?? "") }
    }

    // Layout wie auf der Skizze: 1 = links, 2 = rechts oben, 3 = rechts unten
    private var split: some View {
        HSplitView {
            LeftColumn().frame(minWidth: 260, idealWidth: 330, maxWidth: 520)
            VSplitView {
                Group {
                    if let a = selected { ConfigPanel(asset: a) } else { InfoPlaceholder() }
                }
                .frame(minHeight: 170, idealHeight: 230)
                Group {
                    if let a = selected { PreviewPanel(audio: audio, autoplay: $autoplay, asset: a) } else { Color.clear }
                }
                .frame(minHeight: 260)
            }
            .frame(minWidth: 520)
        }
    }

    private func syncAudio() {
        if let a = selected, a.kind == .sound { audio.load(store.url(for: a.id), autoplay: autoplay) }
        else { audio.stop() }
    }
}

struct TopBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Alle Sounds & Texturen durchsuchen (z. B. „stone break“, „zombie“, „oak planks“)", text: $store.query)
                    .textFieldStyle(.plain)
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            Picker("", selection: $store.filter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)

            Button { store.openPanel() } label: { Label("Öffnen", systemImage: "folder") }

            Menu {
                Button("Als Texturepack (.zip) …") { store.exportPack() }
                Button("Als .jar …") { store.exportJar() }.disabled(!store.isJar)
            } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
            .fixedSize()
            .disabled(store.root == nil)
        }
        .padding(10)
    }
}

// MARK: - 1 · Ordnerverlauf

struct LeftColumn: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 0) {
            Breadcrumb()
            Divider()
            if store.query.trimmingCharacters(in: .whitespaces).isEmpty {
                List(selection: $store.selection) { TreeView(nodes: store.tree) }
                    .listStyle(.sidebar)
            } else {
                let res = store.results()
                List(selection: $store.selection) {
                    ForEach(res.prefix(500)) { a in
                        ResultRow(asset: a).tag(a.id)
                            .contextMenu { Button("Im Ordnerverlauf anzeigen") { store.reveal(a.id) } }
                    }
                }
                Text("\(res.count) Treffer" + (res.count > 500 ? " (erste 500 angezeigt)" : ""))
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
    }
}

struct Breadcrumb: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let parts = (store.selection ?? "").split(separator: "/").map(String.init)
        VStack(alignment: .leading, spacing: 2) {
            Text("ORDNERVERLAUF").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    if parts.isEmpty { Text("–").foregroundStyle(.tertiary) }
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                        HStack(spacing: 2) {
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Button(part) { store.reveal(parts[0...i].joined(separator: "/")) }
                                .buttonStyle(.plain)
                                .foregroundStyle(i == parts.count - 1 ? Color.primary : Color.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

struct TreeView: View {
    @EnvironmentObject var store: Store
    let nodes: [Node]
    var body: some View {
        ForEach(nodes) { n in
            if let kids = n.children {
                DisclosureGroup(isExpanded: expandedBinding(n.id)) {
                    TreeView(nodes: kids)
                } label: {
                    Label(n.name, systemImage: "folder").tag(n.id)
                }
            } else {
                Label(n.name, systemImage: store.assetByID[n.id]?.kind == .sound ? "speaker.wave.2" : "photo").tag(n.id)
            }
        }
    }
    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { store.expanded.contains(id) },
                set: { if $0 { store.expanded.insert(id) } else { store.expanded.remove(id) } })
    }
}

struct ResultRow: View {
    let asset: Asset
    var body: some View {
        HStack {
            Image(systemName: asset.kind == .sound ? "speaker.wave.2" : "photo").frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.name).lineLimit(1)
                Text(asset.kind == .sound && !asset.events.isEmpty
                     ? asset.events[0]
                     : asset.folder.replacingOccurrences(of: "assets/minecraft/", with: ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - 2 · Config

struct ConfigPanel: View {
    @EnvironmentObject var store: Store
    let asset: Asset
    @StateObject private var flags = UIFlags()

    private var isModified: Bool { store.modified.contains(asset.id) }
    private var sizeText: String {
        let n = (try? store.url(for: asset.id).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(asset.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text(isModified ? "Ersetzt" : "Original")
                    .font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(isModified ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.15)))
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Pfad", asset.id, code: true)
                if asset.kind == .sound {
                    row("Event", asset.events.isEmpty ? "–" : asset.events.joined(separator: ", "))
                    if !asset.subtitle.isEmpty { row("Beschreibung", asset.subtitle) }
                }
                row("Größe", sizeText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { store.pickReplacement(asset, mono: flags.mono) } label: {
                    Label(asset.kind == .sound ? "Durch eigenen Sound ersetzen …" : "Durch eigene Textur ersetzen …",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                Menu {
                    if asset.kind == .sound {
                        Button("Original (.ogg) …") { store.exportAsset(asset) }
                        Button("Als WAV (.wav) …") { store.exportAsset(asset, wav: true) }
                    } else {
                        Button("PNG …") { store.exportAsset(asset) }
                    }
                } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                .fixedSize()
                Button { store.reset(asset) } label: { Label("Zurücksetzen", systemImage: "arrow.uturn.backward") }
                    .disabled(!isModified)
                if asset.kind == .sound {
                    Toggle("Mono (empfohlen für Welt-Sounds)", isOn: $flags.mono).toggleStyle(.checkbox)
                }
            }
            Text("Tipp: Eigene Datei einfach auf dieses Feld ziehen. Fremde Formate werden automatisch in \(asset.kind == .sound ? ".ogg (Vorbis)" : "PNG") umgewandelt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if flags.dropOver {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $flags.dropOver) { providers in
            loadFileURL(providers) { url in Task { @MainActor in store.replace(asset, with: url, mono: flags.mono) } }
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String, code: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).font(code ? .system(.callout, design: .monospaced) : .callout).textSelection(.enabled).lineLimit(2)
        }
    }
}

struct InfoPlaceholder: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "cursorarrow.click.2").font(.largeTitle).foregroundStyle(.tertiary)
            if let s = store.selection {
                Text(s).font(.callout.monospaced())
                Text("\(store.assets.filter { $0.id.hasPrefix(s + "/") }.count) Sounds/Texturen in diesem Ordner")
                    .foregroundStyle(.secondary)
            } else {
                Text("Links einen Sound oder eine Textur auswählen – oder oben suchen")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 3 · Vorschau

struct PreviewPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject var audio: AudioPreview
    @Binding var autoplay: Bool
    let asset: Asset
    var body: some View {
        Group {
            if asset.kind == .sound {
                SoundPlayer(audio: audio, autoplay: $autoplay, asset: asset)
            } else {
                TexturePreview(url: store.url(for: asset.id)).id(store.revision)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SoundPlayer: View {
    @ObservedObject var audio: AudioPreview
    @Binding var autoplay: Bool
    let asset: Asset
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text(asset.events.first ?? asset.name).font(.headline)
                if !asset.subtitle.isEmpty { Text(asset.subtitle).foregroundStyle(.secondary) }
                if asset.events.count > 1 {
                    Text("+ \(asset.events.count - 1) weitere Events").font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 12) {
                Text(fmt(audio.current)).monospacedDigit().frame(width: 62, alignment: .trailing)
                Slider(value: Binding(get: { audio.current }, set: { audio.seek($0) }), in: 0...max(audio.duration, 0.01))
                Text(fmt(audio.duration)).monospacedDigit().frame(width: 62, alignment: .leading)
            }
            .padding(.horizontal, 24)
            HStack(spacing: 18) {
                Button { audio.stop() } label: { Image(systemName: "stop.fill") }
                Button { audio.toggle() } label: { Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
                Toggle(isOn: $audio.loop) { Image(systemName: "repeat") }.toggleStyle(.button)
            }
            .buttonStyle(.bordered).controlSize(.large)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $audio.volume, in: 0...1).frame(width: 120)
                Toggle("Automatisch abspielen", isOn: $autoplay)
            }
            if !audio.message.isEmpty {
                Text(audio.message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
    }
}

struct TexturePreview: View {
    let url: URL
    var body: some View {
        let img = NSImage(contentsOf: url)
        let rep = img?.representations.first as? NSBitmapImageRep
        VStack(spacing: 6) {
            ZStack {
                Checker()
                if let img {
                    Image(nsImage: img).interpolation(.none).resizable().scaledToFit().padding(14)
                } else {
                    Text("Vorschau nicht verfügbar").foregroundStyle(.secondary)
                }
            }
            if let rep {
                Text("\(rep.pixelsWide) × \(rep.pixelsHigh) Pixel")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
            }
        }
    }
}

struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in 0...Int(size.height / s) {
                for x in 0...Int(size.width / s) where (x + y) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)),
                             with: .color(.gray.opacity(0.18)))
                }
            }
        }
        .background(Color.gray.opacity(0.08))
    }
}

// MARK: - Leerzustand & Statusleiste

struct EmptyState: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox").font(.system(size: 54)).foregroundStyle(.secondary)
            Text("Minecraft-.jar oder Texturepack hier hineinziehen").font(.title2)
            Text("Die .jar liegt unter ~/Library/Application Support/minecraft/versions/<Version>/<Version>.jar\nTexturepacks: .zip oder entpackter Ordner")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Datei oder Ordner wählen …") { store.openPanel() }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 8) {
            if store.busy { ProgressView().controlSize(.small) }
            Text(store.status).lineLimit(1).truncationMode(.middle)
            Spacer()
            if store.root != nil { Text("\(store.modified.count) geändert") }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}
