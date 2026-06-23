import SwiftUI
import AppKit

// ─────────────────────────────────────────────────────────────
// 진입점 + 앱 골격.
//   MenuBarExtra(.window): NSMenu가 아닌 플로팅 윈도우 → 메인 런루프 default 유지 →
//   팝업 펼친 채로도 Task.sleep 폴링이 화면을 갱신(SwiftBar NSMenu 동결의 반례, Phase 0 게이트 통과).
//   LSUIElement=true + setActivationPolicy(.accessory)로 Dock 미표시.
// ─────────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
enum Entry {
    static func main() {
        // 헤드리스 데이터 레이어 검증 경로(GUI 미기동). 그 외엔 메뉴바 앱 기동.
        if CommandLine.arguments.contains("--dump") {
            Dump.runBlocking()
            return
        }
        TossStockApp.main()
    }
}

struct TossStockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = StockModel()

    var body: some Scene {
        MenuBarExtra {
            PopupView(model: model)
        } label: {
            // 모노크롬 회전 타이틀. 컬러는 드롭다운에만.
            Text(model.titleText)
        }
        .menuBarExtraStyle(.window)
    }
}
