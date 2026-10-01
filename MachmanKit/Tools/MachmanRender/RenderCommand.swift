//
//  RenderCommand.swift
//  MachmanRender
//
//  The command line: pick scenes by glob, draw each at its widths in the chosen schemes,
//  write <out>/<scene>@<width>-<scheme>.png.
//

import AppKit
import Darwin

@MainActor
enum RenderCommand {
	static let usage = """
		usage: scripts/render.sh [--list] [--out DIR] [--scheme light|dark|both]
		                         [--widths W,W…] [SCENE-GLOB …]
		  --list      print the scenes (name, widths, summary) and exit
		  --out       directory for the PNGs (required unless --list)
		  --scheme    default both
		  --widths    override every selected scene's widths (points)
		  SCENE-GLOB  e.g. 'inspector.*' 'window.main'; default: every scene
		"""

	static func run(_ args: [String]) -> Int32 {
		var list = false
		var out: String?
		var schemes = [false, true]
		var widths: [CGFloat]?
		var globs: [String] = []
		var rest = args[...]
		while let arg = rest.popFirst() {
			switch arg {
			case "--list": list = true
			case "--out": out = rest.popFirst()
			case "--scheme":
				switch rest.popFirst() {
				case "light": schemes = [false]
				case "dark": schemes = [true]
				case "both": schemes = [false, true]
				default: return fail("--scheme takes light, dark or both")
				}
			case "--widths":
				let parsed = (rest.popFirst() ?? "").split(separator: ",")
					.compactMap { Double($0).map { CGFloat($0) } }
				guard !parsed.isEmpty else { return fail("--widths takes W,W,…") }
				widths = parsed
			case "-h", "--help":
				Console.out(usage)
				return 0
			default:
				if arg.hasPrefix("-") { return fail("unknown option \(arg)") }
				globs.append(arg)
			}
		}

		let scenes = SceneRegistry.all.filter { scene in
			globs.isEmpty || globs.contains { fnmatch($0, scene.name, 0) == 0 }
		}
		guard !scenes.isEmpty else { return fail("no scene matches \(globs)") }
		if list {
			for scene in scenes {
				let w = scene.widths.map { $0.map { "\(Int($0))" } ?? "fit" }
				Console.out("\(scene.name)\t\(w.joined(separator: ","))\t\(scene.summary)")
			}
			return 0
		}
		guard let out else { return fail("--out DIR is required") }
		let dir = URL(fileURLWithPath: out, isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		} catch {
			return fail("cannot create \(out): \(error)")
		}

		var failures = 0
		for scene in scenes {
			for width in widths.map({ $0.map { Optional($0) } }) ?? scene.widths {
				for dark in schemes {
					let context = SceneContext(vms: scene.vms())
					let file = "\(scene.name)@\(width.map { "\(Int($0))" } ?? "fit")"
						+ "-\(dark ? "dark" : "light").png"
					// Never expected; if it happens, stop before another scene can. png() checks
					// while its window exists; this catches what outlives the scene.
					let rendered: (data: Data, size: CGSize)?
					do {
						rendered = try Offscreen.png(
							scene.make(context), width: width, height: scene.height, dark: dark,
							chrome: scene.chrome, panels: scene.panels?(context) ?? [])
					} catch {
						return stop(at: file)
					}
					if Offscreen.reachedScreen() { return stop(at: file) }
					guard let rendered else {
						Console.err("FAILED \(file)")
						failures += 1
						continue
					}
					do {
						try rendered.data.write(to: dir.appendingPathComponent(file))
						Console.out("\(dir.appendingPathComponent(file).path)\t"
							+ "\(Int(rendered.size.width))×\(Int(rendered.size.height)) pt")
					} catch {
						Console.err("FAILED \(file): \(error)")
						failures += 1
					}
				}
			}
		}
		// A scene wrote the real home's defaults (see RenderSandbox): fail here, where the
		// writer ran, rather than only in the next run's refusal.
		let leftovers = RenderSandbox.standardDomainKeys()
		if !leftovers.isEmpty {
			Console.err("MachmanRender: a scene wrote \(leftovers.joined(separator: ", ")) to "
				+ "the real home's '\(RenderSandbox.standardDomain)' defaults domain; scenes "
				+ "must not write UserDefaults.standard")
			return 1
		}
		return failures == 0 ? 0 : 1
	}

	private static func stop(at file: String) -> Int32 {
		Console.err("MachmanRender: stopping at \(file): a window became visible or reached "
			+ "the screen, or the app became active")
		return 1
	}

	private static func fail(_ why: String) -> Int32 {
		Console.err("MachmanRender: \(why)")
		Console.err(usage)
		return 64
	}
}
