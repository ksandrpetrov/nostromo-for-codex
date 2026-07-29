import AppKit
import NostromoCodexCore
import SwiftUI

struct ShortcutRecorderField: View {
    @Binding var shortcut: ShortcutBinding
    @State private var recording = false

    var body: some View {
        Button {
            recording.toggle()
        } label: {
            HStack {
                Image(systemName: recording ? "keyboard.fill" : "keyboard")
                    .foregroundStyle(recording ? NostromoTheme.accent : .secondary)
                Text(recording ? "Нажмите сочетание клавиш…" : shortcut.displayText)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                Spacer()
                Text(recording ? "Esc — отмена" : "Записать")
                    .font(.caption)
                    .foregroundStyle(NostromoTheme.mutedForeground)
            }
            .padding(.horizontal, 12)
            .frame(height: NostromoControlHeight.large)
            .background(
                recording ? NostromoTheme.selected : NostromoTheme.hover,
                in: RoundedRectangle(cornerRadius: NostromoRadius.small)
            )
            .overlay {
                RoundedRectangle(cornerRadius: NostromoRadius.small)
                    .strokeBorder(
                        recording ? NostromoTheme.focus : NostromoTheme.input,
                        lineWidth: recording ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .background {
            ShortcutCaptureRepresentable(isActive: recording) { captured in
                if let captured {
                    shortcut = captured
                }
                recording = false
            }
            .frame(width: 1, height: 1)
            .opacity(0.001)
        }
        .accessibilityLabel("Сочетание клавиш")
        .accessibilityValue(recording ? "Запись" : shortcut.displayText)
        .accessibilityHint("Нажмите, чтобы записать новое сочетание клавиш")
    }
}

private struct ShortcutCaptureRepresentable: NSViewRepresentable {
    var isActive: Bool
    var onCapture: (ShortcutBinding?) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context _: Context) {
        nsView.onCapture = onCapture
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: ((ShortcutBinding?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCapture?(nil)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        onCapture?(
            ShortcutBinding(
                keyCode: event.keyCode,
                command: flags.contains(.command),
                option: flags.contains(.option),
                control: flags.contains(.control),
                shift: flags.contains(.shift)
            )
        )
    }
}

extension ShortcutBinding {
    var displayText: String {
        guard isConfigured else { return "Сочетание не записано" }
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Ввод",
            37: "L", 38: "J", 39: "’", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Пробел",
            50: "`", 51: "Удалить", 53: "Esc", 76: "Ввод", 115: "В начало",
            116: "Страница вверх", 117: "Удалить вперёд", 119: "В конец", 121: "Страница вниз",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return names[code] ?? "Клавиша \(code)"
    }
}
