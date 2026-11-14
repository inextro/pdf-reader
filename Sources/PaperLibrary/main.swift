import AppKit
import AppUpdater

// 1.0.5에서 PaperLibrary가 Quillo로 이름을 바꿨다. 업데이트로 받은 PaperLibrary.app을 Quillo.app으로 옮긴다.
UpdateController.adoptCurrentName(from: "PaperLibrary")

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
