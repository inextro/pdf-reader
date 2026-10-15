import AppKit

// 처음 만든 NSDocumentController 인스턴스가 shared가 된다.
_ = PMDocumentController()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
