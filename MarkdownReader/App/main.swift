import AppKit

// Plain AppKit entry point: no storyboard or nib to load, which keeps
// launch fast and the menu definition in one readable place (MainMenu.swift).
LaunchTrace.mark("main")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
