import AppKit
import SwiftUI

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading) {
                        Text("Apen").font(.title.bold())
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                }
                Text("Local dictation for macOS. Your voice is transcribed on this Mac; nothing is sent to a server.")

                Text("Models").font(.headline)
                credit(
                    "Parakeet Unified EN 0.6B",
                    "Licensed by NVIDIA Corporation under the NVIDIA Open Model License. Core ML conversion by FluidInference."
                )
                credit("Parakeet CTC 110M", "NVIDIA, CC-BY-4.0. Core ML conversion by FluidInference.")
                credit("Qwen3-4B-Instruct-2507", "Alibaba Qwen team, Apache-2.0. GGUF quantization by Unsloth.")

                Text("Libraries").font(.headline)
                credit("FluidAudio", "Apache-2.0")
                credit("llama.cpp", "MIT")
                credit("GRDB.swift", "MIT")
                credit("KeyboardShortcuts", "MIT")
                credit("MenuBarExtraAccess", "MIT")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
