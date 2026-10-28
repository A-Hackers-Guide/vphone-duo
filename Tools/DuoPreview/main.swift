import AppKit
import RealityKit

// Preview harness: the Duo window without a VM. Renders poses to PNGs and
// replays clicks through real NSEvents.
//   harness <resources> <frame.png> <outdir> [script]
let args = CommandLine.arguments
let resources = URL(fileURLWithPath: args[1])
let frameURL = URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])

@MainActor
final class Harness: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var duo: VPhoneDuoView!
    let vmView = VPhoneVirtualMachineView()

    func applicationDidFinishLaunching(_: Notification) {
        let size = NSSize(width: 860, height: 820)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        duo = VPhoneDuoView(frame: NSRect(origin: .zero, size: size))
        duo.virtualMachineView = vmView
        duo.onHingeChange = { print(String(format: "hinge %.2f", $0)) }
        duo.onButton = { print("button \($0.rawValue) \($1 ? "down" : "up")") }
        duo.onActivePanelChange = { print("panel \($0)") }
        let source = CGImageSourceCreateWithURL(frameURL as CFURL, nil)!
        let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        if args.count > 4, args[4] == "live" || args[4] == "scroll" || args[4] == "readback" {
            duo.frameSource = { deliver in Task { deliver(await LiveVM.frame()) } }
            vmView.live = true
            duo.onHingeChange = { [duo] angle in Task { @MainActor in
                _ = await LiveVM.rpc("motion.hinge.set", ["enabled": true, "angle": angle, "velocity": 0])
                duo?.hingeDelivered()
            } }
            duo.readPublishedAngle = {
                let reply = await LiveVM.rpc("motion.hinge.get")
                let provider = (reply?["result"] as? [String: Any])?["provider"] as? [String: Any]
                let angle = ((provider?["configuration"] as? [String: Any])?["angle"] as? NSNumber)?.doubleValue
                print("iOS publishes", angle ?? -1)
                return angle
            }
            duo.onButton = { button, down in
                let usage: Int = switch button {
                case .volumeUp: 0xE9
                case .volumeDown: 0xEA
                case .side: 0x30
                case .cameraControl: 0x21
                }
                let page = button == .cameraControl ? 0x90 : 0x0C
                print("button \(button.rawValue) \(down ? "down" : "up") -> page \(page) usage \(usage)")
                Task { print("  hid reply", await LiveVM.rpc("input.hid", ["page": page, "usage": usage, "down": down]) ?? [:]) }
            }
        } else {
            duo.frameSource = { deliver in deliver(frame) }
        }
        window.contentView = duo
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await run() }
    }

    func snap(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(700))
        let view = duo.subviews.compactMap { $0 as? ARView }.first!
        let image: NSImage? = await withCheckedContinuation { c in view.snapshot(saveToHDR: false) { c.resume(returning: $0) } }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("snap failed \(name)"); return }
        try? png.write(to: outDir.appendingPathComponent(name + ".png"))
        print("saved \(name)")
    }

    func click(_ point: NSPoint, hold: Double = 0.1) async {
        let wp = duo.convert(point, to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        window.sendEvent(ev(.leftMouseDown))
        try? await Task.sleep(for: .milliseconds(Int(hold * 1000)))
        window.sendEvent(ev(.leftMouseUp))
    }

    func run() async {
        await duo.load(resources: resources)
        let script = args.count > 4 ? args[4] : "poses"
        switch script {
        case "poses":
            await snap("00_open_front")
            duo.setFinish(.black); await snap("01_open_front_black"); duo.setFinish(.white)
            duo.setHinge(110); await snap("02_laptop")
            duo.setHinge(70); await snap("03_tent")
            duo.setHinge(0); duo.resetView(); try? await Task.sleep(for: .milliseconds(900)); await snap("04_closed_outer")
            duo.setHinge(180); duo.resetView(); try? await Task.sleep(for: .milliseconds(900))
        case "buttons":
            // Click every button where it is drawn, from several angles and folds.
            let view = duo.subviews.compactMap { $0 as? ARView }.first!
            for (angle, yaw, pitch) in [(0.0, Float(-1.2), Float(0.1)), (0.0, Float(-1.6), Float(0.6)), (110.0, Float(-2.4), Float(0.3)), (180.0, Float(-0.9), Float(0.5))] {
                duo.setHinge(angle); duo.debugOrbit(yaw: yaw, pitch: pitch)
                try? await Task.sleep(for: .milliseconds(300))
                for button in VPhoneDuoModel.Button.allCases {
                    guard let world = duo.model?.center(of: button, relativeTo: nil), let p = view.project(world) else { print("no projection \(button)"); continue }
                    // ARView points are top-left; the overlay is bottom-left.
                    let point = NSPoint(x: p.x, y: p.y)
                    print("pose \(angle)/\(yaw): clicking \(button.rawValue)")
                    await click(point, hold: 0.15)
                }
            }
        case "look":
            // The outside, both finishes, and a three-quarter view of a tent.
            duo.setHinge(150); duo.resetView(animated: false)
            duo.debugOrbit(yaw: 2.6, pitch: 0.25)
            await snap("30_back_white")
            duo.setFinish(.black); await snap("31_back_black")
            duo.setHinge(75); duo.debugOrbit(yaw: 0.9, pitch: 0.35)
            await snap("32_tent_black")
            duo.setFinish(.white); await snap("33_tent_white")
            duo.setHinge(0); duo.debugOrbit(yaw: -1.2, pitch: 0.1)
            await snap("34_closed_edge_buttons")
            duo.setFinish(.black); await snap("35_closed_back_black")
            duo.debugOrbit(yaw: -2.2, pitch: 0.3); await snap("36_closed_black_edge")
            duo.setFinish(.white)
        case "live":
            func shot(_ name: String) async {
                _ = await LiveVM.call(["t": "screenshot", "path": outDir.appendingPathComponent(name + "_guest.png").path, "screen": false])
            }
            duo.setHinge(0); duo.resetView(animated: false)
            try? await Task.sleep(for: .seconds(3))
            await snap("40_live_closed")
            let view = duo.subviews.compactMap { $0 as? ARView }.first!
            func clickScreen(_ point: CGPoint, panel: VPhoneDuoModel.Panel) async {
                guard let world = duo.model?.position(of: point, on: panel, relativeTo: nil), let p = view.project(world) else { print("no projection"); return }
                print("clicking screen point \(point) at view \(p)")
                await click(NSPoint(x: p.x, y: p.y), hold: 0.12)
            }
            // Leave edit mode if a previous run left the icons jiggling.
            _ = await LiveVM.call(["t": "key", "name": "home", "screen": false])
            try? await Task.sleep(for: .seconds(2))
            // The Settings icon on the outer home screen.
            await clickScreen(CGPoint(x: 0.497, y: 0.867), panel: .outer)
            try? await Task.sleep(for: .seconds(10))
            print("foreground after tap:", ((await LiveVM.rpc("apps.foreground"))?["result"] as? [String: Any])?["bundle_id"] ?? "?")
            await snap("41_live_settings"); await shot("41_live_settings")
            _ = await LiveVM.call(["t": "key", "name": "home", "screen": false])
            try? await Task.sleep(for: .seconds(2))
            // Volume up on the model.
            duo.debugOrbit(yaw: -1.2, pitch: 0.35)
            try? await Task.sleep(for: .milliseconds(400))
            if let world = duo.model?.center(of: .volumeUp, relativeTo: nil), let p = view.project(world) {
                await click(NSPoint(x: p.x, y: p.y), hold: 0.15)
            }
            try? await Task.sleep(for: .milliseconds(700))
            await shot("42_live_volume")
            print("volume after:", await LiveVM.rpc("audio.volume") ?? [:])
            duo.animateHinge(to: 180)
            try? await Task.sleep(for: .seconds(1))
            duo.resetView(animated: false)
            try? await Task.sleep(for: .seconds(3))
            await snap("43_live_open")
            print("hinge now:", await LiveVM.rpc("motion.hinge.get") ?? [:])
        case "scroll":
            duo.setHinge(0); duo.resetView(animated: false)
            try? await Task.sleep(for: .seconds(3))
            _ = await LiveVM.call(["t": "screenshot", "path": outDir.appendingPathComponent("50_before.png").path, "screen": false])
            // A two-finger swipe up over the middle of the screen, as a trackpad sends it.
            let view = duo.subviews.compactMap { $0 as? ARView }.first!
            guard let world = duo.model?.position(of: CGPoint(x: 0.5, y: 0.6), on: .outer, relativeTo: nil), let p = view.project(world) else { break }
            let location = duo.convert(NSPoint(x: p.x, y: p.y), to: nil)
            func send(_ phase: Int64, _ dx: Int32) {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
                // A CG event belongs to no window, so AppKit reports its
                // screen position as the window position: aim it there.
                cg.location = CGPoint(x: location.x, y: NSScreen.screens[0].frame.maxY - location.y)
                if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
            }
            send(1, 0)  // began
            for _ in 0 ..< 10 { send(2, 30); try? await Task.sleep(for: .milliseconds(20)) }
            send(4, 0)  // ended
            try? await Task.sleep(for: .seconds(3))
            _ = await LiveVM.call(["t": "screenshot", "path": outDir.appendingPathComponent("51_after.png").path, "screen": false])
        case "readback":
            for angle in [87.5, 33.25, 180.0] {
                duo.setHinge(angle)
                print(String(format: "set %.2f", angle))
                try? await Task.sleep(for: .seconds(1.5))
            }
        case "clicks-closed":
            duo.setHinge(0); duo.resetView(animated: false)
            try? await Task.sleep(for: .milliseconds(500))
            await snap("20_closed_for_clicks")
            let b = duo.bounds
            for y in [0.3, 0.5, 0.7] {
                for x in stride(from: 0.4, through: 0.8, by: 0.1) {
                    print("click at \(x),\(y)")
                    await click(NSPoint(x: b.width * x, y: b.height * y))
                }
            }
        case "clicks":
            // A grid of clicks across the window, reporting what each hit.
            let b = duo.bounds
            for y in stride(from: 0.2, through: 0.8, by: 0.15) {
                for x in stride(from: 0.2, through: 0.8, by: 0.15) {
                    print("click at \(x),\(y)")
                    await click(NSPoint(x: b.width * x, y: b.height * y))
                }
            }
        case "static":
            duo.stream?.stop()
            let source = CGImageSourceCreateWithURL(frameURL as CFURL, nil)!
            let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let tex = try! await TextureResource(image: frame, options: .init(semantic: .color))
            duo.model?.setPanelTexture(.inner, tex, frameSize: CGSize(width: frame.width, height: frame.height))
            await snap("10_static_inner")
        default: break
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { Harness() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
