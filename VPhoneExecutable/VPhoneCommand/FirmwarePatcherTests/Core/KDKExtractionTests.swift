@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

struct KDKExtractionTests {
    @Test func `bundle paths and metadata`() throws {
        let root = URL(fileURLWithPath: "/tmp/KDK/Extensions")
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.test.plugin", "CFBundleExecutable": "Plugin",
            "_PrelinkBundlePath": "/System/Library/Extensions/Parent.kext/Contents/PlugIns/Plugin.kext",
            "_PrelinkExecutableRelativePath": "Contents/MacOS/Plugin", "OSBundleUUID": Data([1]), "CFBundleNumericVersion": 3,
        ]
        let paths = try KDKExtraction.bundleLayout(root, identifier: "com.test.plugin", info: info)
        #expect(paths.plist.path == "/tmp/KDK/Extensions/Parent.kext/Contents/PlugIns/Plugin.kext/Contents/Info.plist")
        #expect(paths.executable?.lastPathComponent == "Plugin")
        #expect(KDKExtraction.standaloneInfo(info).count == 2)
        #expect(info.count == 6)
        for path in ["/tmp/escape", "../escape", "A/../../escape", "A//B", "A/./B", ""] {
            #expect(throws: PatcherError.self) { try KDKExtraction.child(root, path) }
        }
        let codeless = try KDKExtraction.bundleLayout(root, identifier: "com.test.personality", info: ["DTPlatformName": "macosx"])
        #expect(codeless.plist.path.hasSuffix(".kext/Contents/Info.plist"))
        #expect(codeless.executable == nil)
    }

    @Test func `pseudo executable retains UUID and symbols`() throws {
        let uuid = Array(UInt8(0) ..< 16)
        let data = KDKExtraction.pseudoMachO(uuid: uuid, symbols: ["_z", "_a"])
        let (header, commands) = try KDKMachO.loadCommands(in: .init(data: data), at: 0)
        #expect(header.fileType == 0xB)
        #expect(header.commandCount == 3)
        #expect(header.cpuSubtype == 2)
        #expect(Array(commands[2].bytes[8 ..< 24]) == uuid)
        let symbols = try KDKMachO.symbols(commands[1].bytes, in: .init(data: data))
        #expect(symbols.map(\.name) == ["_a", "_z"])
        #expect(symbols.allSatisfy { $0.isExternal && $0.isUndefined && $0.value == 0 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDK_PARITY_ROOT"] != nil))
    func `complete KDK trees match reference`() throws {
        let root = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["KDK_PARITY_ROOT"]))
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appending(path: "KDK-extraction-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        for (label, kernel) in [("donor", "vphone600"), ("research", "vresearch101")] {
            let source = root.appending(path: "data/264beta/kernelcache.release.\(kernel).decompressed")
            let corpus = root.appending(path: "parity/\(label)")
            let symbolURL = corpus.appending(path: "symbols.json")
            let known = fm.fileExists(atPath: symbolURL.path) ? try KDKLinkSymbols.loadKnown(Data(contentsOf: symbolURL)) : [:]
            let output: URL
            if label == "donor" {
                var repository = URL(fileURLWithPath: #filePath)
                for _ in 0 ..< 5 {
                    repository.deleteLastPathComponent()
                }
                let recipes = KernelCacheRecipes(root: repository.appending(path: "VPhoneExecutable/VPhoneVirtualization/Resources/kernelcache_recipes"))
                let donor = try recipes.donor(id: "vphone600_26.4_23E5207q")
                let mixer = KernelCacheMixer(recipes: recipes, cacheDirectory: temporary.appending(path: "cache"), verbose: false)
                output = try mixer.extract(kernelcache: source, symbols: donor.symbolsURL, kdk: donor.kernel.kdk, into: temporary.appending(path: label))
            } else {
                output = try KDKExtraction.extract(Data(contentsOf: source), to: temporary.appending(path: label), known: known)
            }
            let expected = corpus.appending(path: "out").appending(path: output.lastPathComponent)
            func files(_ directory: URL) throws -> Set<String> {
                let enumerator = try #require(fm.enumerator(atPath: directory.path))
                return Set((enumerator.allObjects as? [String] ?? []).filter { path in
                    var isDirectory: ObjCBool = false
                    return fm.fileExists(atPath: directory.appending(path: path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
                })
            }
            let paths = try files(expected)
            #expect(try files(output) == paths)
            for path in paths.sorted() {
                let actual = try Data(contentsOf: output.appending(path: path))
                let reference = try Data(contentsOf: expected.appending(path: path))
                if path.hasSuffix(".plist") {
                    let a = try PropertyListSerialization.propertyList(from: actual, format: nil) as? NSDictionary
                    let b = try PropertyListSerialization.propertyList(from: reference, format: nil) as? NSDictionary
                    #expect(a == b, "\(label)/\(path): plist values differ")
                } else {
                    #expect(actual == reference, "\(label)/\(path): executable bytes differ")
                }
                let permissions = try fm.attributesOfItem(atPath: output.appending(path: path).path)[.posixPermissions] as? NSNumber
                #expect(permissions?.intValue == 0o777)
            }
            #expect(throws: PatcherError.self) {
                try KDKExtraction.extract(Data(contentsOf: source), to: temporary.appending(path: label), known: known)
            }
            print("KDK tree parity: \(label), \(paths.count) files, all executable bytes and plist values match")
        }
    }
}
