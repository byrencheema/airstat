import AppKit
import AirStatKit
import AirStatUI

/// `AirStat --render` writes PNGs of every surface without needing a screen or a
/// Screen Recording grant, using deterministic fixture data.
enum RenderCLI {

    static func run(_ arguments: [String]) {
        var surfaces: [OffscreenRenderer.Surface] = []
        var scenarios: [OffscreenRenderer.Scenario] = []
        var scales: [CGFloat] = []
        var appearances: [Bool] = []
        var outputDirectory = URL(fileURLWithPath: "render", isDirectory: true)

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--out":
                index += 1
                if index < arguments.count {
                    outputDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
                }
            case "--scale":
                index += 1
                if let value = Double(arguments[safe: index] ?? "") { scales.append(CGFloat(value)) }
            case "--light": appearances.append(false)
            case "--dark": appearances.append(true)
            case "--scenario":
                index += 1
                if let scenario = OffscreenRenderer.Scenario(rawValue: arguments[safe: index] ?? "") {
                    scenarios.append(scenario)
                }
            default:
                if let surface = OffscreenRenderer.Surface(rawValue: arguments[index]) {
                    surfaces.append(surface)
                } else {
                    FileHandle.standardError.write(Data("unknown argument '\(arguments[index])'\n".utf8))
                    exit(2)
                }
            }
            index += 1
        }

        // Default to the full matrix: every surface, every state, both appearances,
        // both backing scales. That is what a visual reviewer needs to see at once.
        if surfaces.isEmpty { surfaces = OffscreenRenderer.Surface.allCases }
        if scenarios.isEmpty { scenarios = OffscreenRenderer.Scenario.allCases }
        if appearances.isEmpty { appearances = [false, true] }
        if scales.isEmpty { scales = [1, 2] }

        // Rendering AppKit and SwiftUI views needs a running NSApplication even
        // though nothing is ever shown, so the app is brought up as an accessory
        // and torn down as soon as the images are written.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        MainActor.assumeIsolated {
            var written = 0
            var failures: [String] = []
            for surface in surfaces {
                for scenario in scenarios {
                    for isDark in appearances {
                        for scale in scales {
                            let request = OffscreenRenderer.Request(
                                surface: surface, scenario: scenario,
                                isDark: isDark, scale: scale)
                            do {
                                let url = try OffscreenRenderer.render(request, to: outputDirectory)
                                print(url.path)
                                written += 1
                            } catch {
                                failures.append("\(request.fileName): \(error)")
                            }
                        }
                    }
                }
            }
            print("\nwrote \(written) image(s) to \(outputDirectory.path)")
            for failure in failures {
                FileHandle.standardError.write(Data("FAILED \(failure)\n".utf8))
            }
            if !failures.isEmpty { exit(1) }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
