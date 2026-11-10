import AppKit

extension NSWindow.Level {
    /// Just under the menu bar, the top of the band apps may use: no other app's float covers it.
    static let palette = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
    /// One step under the palette, so guides clear other apps but not the dragged panel.
    static let paletteDropGuide = NSWindow.Level(rawValue: palette.rawValue - 1)
    /// Above the palette, so a confirmation is never buried under its trigger.
    static let dialog = NSWindow.Level(rawValue: palette.rawValue + 1)
}
