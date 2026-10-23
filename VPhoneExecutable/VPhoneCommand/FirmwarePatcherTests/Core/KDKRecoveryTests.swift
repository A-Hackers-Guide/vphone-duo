@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

struct KDKRecoveryTests {
    @Test func `symbol map formats`() throws {
        let data = Data(#"{"0xfffffe0000000000":"_one","18446741874686296065":["_two","_alias"]}"#.utf8)
        let map = try KDKLinkSymbols.loadKnown(data)
        #expect(map[0xFFFF_FE00_0000_0000] == ["_one"])
        #expect(map[0xFFFF_FE00_0000_0001] == ["_two", "_alias"])
        #expect(throws: PatcherError.self) { try KDKLinkSymbols.loadKnown(Data(#"{"no-address":"_bad"}"#.utf8)) }
        #expect(throws: PatcherError.self) { try KDKLinkSymbols.loadKnown(Data(#"{"0x1234":42}"#.utf8)) }
    }

    @Test func `bounded ULEB`() throws {
        var cursor = KDKCursor([0xE5, 0x8E, 0x26])
        #expect(try cursor.uleb() == 624_485)
        var malformed = KDKCursor([0x80])
        #expect(throws: PatcherError.self) { try malformed.uleb() }
        var overflow = KDKCursor(Array(repeating: UInt8(0xFF), count: 10))
        #expect(throws: PatcherError.self) { try overflow.uleb() }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KDK_PARITY_ROOT"] != nil))
    func `recovered inputs and exports match reference`() throws {
        let root = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["KDK_PARITY_ROOT"]))
        struct Symbol: Decodable {
            var name: String
            var indirectName: String?
            var type: UInt8
            var sect: UInt8
            var desc: UInt16
            var value: UInt64
            var model: KDKSymbol {
                .init(name: name, indirectName: indirectName ?? "", type: type, sect: sect, desc: desc, value: value)
            }
        }
        struct Input: Decodable {
            var entryID: String
            var output: String
            var baseAddress: UInt64
            var symbols: [Symbol]
            var references: [KDKReference]
        }
        let fm = FileManager.default
        var verified = 0
        for (label, kernel) in [("donor", "vphone600"), ("research", "vresearch101")] {
            print("KDK native recovery starting: \(label)")
            let collection = try KDKKernelCollection(Data(contentsOf: root.appending(path: "data/264beta/kernelcache.release.\(kernel).decompressed"), options: .mappedIfSafe))
            let recovery = try KDKRecovery(collection)
            let references = try recovery.recover()
            let corpus = root.appending(path: "parity/\(label)")
            let files = try fm.contentsOfDirectory(at: corpus.appending(path: "inputs"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let inputs = try files.map { try JSONDecoder().decode(Input.self, from: Data(contentsOf: $0)) }
            var differences = 0
            for input in inputs {
                let expected = Set(input.references), actual = Set(references[input.entryID] ?? [])
                if actual != expected {
                    let missing = expected.subtracting(actual).sorted { ($0.source, $0.kind, $0.extra) < ($1.source, $1.kind, $1.extra) }
                    let extra = actual.subtracting(expected).sorted { ($0.source, $0.kind, $0.extra) < ($1.source, $1.kind, $1.extra) }
                    print("KDK recovery difference \(label)/\(input.entryID): missing \(missing.count), extra \(extra.count)")
                    for r in missing.prefix(5) {
                        print("  missing kind=\(r.kind) source=\(String(r.source, radix: 16)) target=\(String(r.target, radix: 16)) extra=\(String(r.extra, radix: 16))")
                    }
                    for r in extra.prefix(5) {
                        print("  extra kind=\(r.kind) source=\(String(r.source, radix: 16)) target=\(String(r.target, radix: 16)) extra=\(String(r.extra, radix: 16))")
                    }
                    let payload = ["missing": missing, "extra": extra]
                    try JSONEncoder().encode(payload).write(to: root.appending(path: "recovery-\(label)-\(input.entryID).json"))
                    differences += 1
                }
            }
            guard differences == 0 else { Issue.record("\(label): reference differences in \(differences) images")
                return
            }
            let knownURL = corpus.appending(path: "symbols.json")
            let known = fm.fileExists(atPath: knownURL.path) ? try KDKLinkSymbols.loadKnown(Data(contentsOf: knownURL)) : [:]
            let symbols = try recovery.synthesizeSymbols(references: references, known: known)
            for input in inputs {
                let generated = (symbols.exports[input.entryID] ?? []) + (symbols.imports[input.entryID] ?? [])
                let expected = input.symbols.map(\.model)
                guard generated == expected else {
                    let difference = zip(generated, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(generated.count, expected.count)
                    print("KDK symbol difference \(label)/\(input.entryID) at \(difference), native \(generated.count), reference \(expected.count)")
                    if difference < generated.count {
                        print("native: \(generated[difference])")
                    }
                    if difference < expected.count {
                        print("reference: \(expected[difference])")
                    }
                    Issue.record("symbol synthesis differs: \(input.entryID)")
                    return
                }
                var image = try #require(recovery.images[input.entryID])
                if input.entryID == "com.apple.kernel", let thread = collection.unixThread,
                   let i = image.commands.firstIndex(where: { $0.command == KDKMachO.lcUnixThread })
                {
                    image.commands[i] = thread
                }
                var writer = try KDKImageExport(collection: collection, image: image, baseAddress: input.baseAddress,
                                                symbols: generated, references: references[input.entryID] ?? [], addressOnlyBinds: true)
                let output = try writer.export(), golden = try Data(contentsOf: corpus.appending(path: "out").appending(path: input.output))
                guard output == golden else {
                    try output.write(to: root.appending(path: "native-\(label)-\(input.entryID)"))
                    Issue.record("native export differs: \(label)/\(input.entryID)")
                    return
                }
                verified += 1
            }
            print("KDK native recovery verified: \(label), \(inputs.count) images; unresolved \(symbols.unresolved.count)")
        }
        #expect(verified == 264)
        print("KDK native recovery: all 264 reference sets, symbol arrays and output binaries match")
    }
}
