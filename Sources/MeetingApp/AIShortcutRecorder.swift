import AppKit
import SwiftUI

struct AIShortcutRecorder: NSViewRepresentable {
    let shortcut: AIShortcut
    let onChange: (AIShortcut) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(ShortcutButton.beginRecording)
        button.onShortcut = context.coordinator.onChange
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.onShortcut = context.coordinator.onChange
        button.shortcut = shortcut
        button.refreshTitle()
    }

    final class Coordinator {
        let onChange: (AIShortcut) -> Void

        init(onChange: @escaping (AIShortcut) -> Void) {
            self.onChange = onChange
        }
    }
}

final class ShortcutButton: NSButton {
    var shortcut = AIShortcut.defaultShortcut
    var onShortcut: ((AIShortcut) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        isRecording = true
        title = "Tapez le raccourci…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            isRecording = false
            refreshTitle()
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let acceptedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let normalizedModifiers = modifiers.intersection(acceptedModifiers)
        guard !normalizedModifiers.isEmpty,
              let characters = event.charactersIgnoringModifiers,
              let firstCharacter = characters.first,
              !firstCharacter.isWhitespace
        else {
            NSSound.beep()
            return
        }

        shortcut = AIShortcut(
            keyCode: UInt32(event.keyCode),
            modifiersRawValue: normalizedModifiers.rawValue,
            key: String(firstCharacter).uppercased()
        )
        isRecording = false
        refreshTitle()
        onShortcut?(shortcut)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        refreshTitle()
        return super.resignFirstResponder()
    }

    func refreshTitle() {
        guard !isRecording else { return }
        title = shortcut.displayValue
        toolTip = "Cliquez puis tapez le nouveau raccourci"
        setAccessibilityLabel("Raccourci IA : \(shortcut.displayValue)")
    }
}
