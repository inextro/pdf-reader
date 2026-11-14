import AppKit
import AppUpdater
import Reader

// 1.0.5에서 PaperLibrary가 Quillo로 이름을 바꿨다. 업데이트로 받은 PaperLibrary.app을 Quillo.app으로 옮긴다.
UpdateController.adoptCurrentName(from: "PaperLibrary")

// 처음 만든 NSDocumentController 인스턴스가 shared가 된다. PDF는 리더 문서(PMDocument)로 연다.
_ = PMDocumentController()

let delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
