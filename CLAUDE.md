# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

토스증권 Open API로 보유·관심종목을 macOS 메뉴바에 표시하는 **SwiftUI 앱** (`tossstock-app/`). 외부 의존성 0, SwiftPM, Swift 6.

> **[SPEC.md](./SPEC.md)가 동작 명세의 source of truth다.** 코드 변경 전 관련 절을 읽고, 변경이 명세를 바꾸면 SPEC.md도 함께 갱신한다. 이 문서는 SPEC을 복제하지 않고 진입점과 비자명한 함정만 가리킨다.

## 명령어

모든 명령은 `tossstock-app/`에서 실행한다.

```bash
./Packaging/build.sh                          # swift build -c release → build/TossStock.app 조립 + ad-hoc 서명
open build/TossStock.app                       # 메뉴바에 등록
./Packaging/build.sh && \
  build/TossStock.app/Contents/MacOS/TossStock --dump   # GUI 없이 데이터 레이어만 헤드리스 검증
./Packaging/deploy.sh                          # 재빌드 → 실행 인스턴스 종료 → /Applications 제자리 교체 → 재실행
swift build                                    # 빠른 타입체크(debug). VSCode launch.json에 debug/release 구성 있음
```

- **테스트 스위트 없음.** 데이터 레이어 검증은 `--dump` 헤드리스 실행이 유일한 수단이다 (네트워크·인증·디코딩 경로를 GUI 없이 통과시킨다).
- 실행하려면 `~/.config/tossstock/auth.env`에 `TOSS_CLIENT_ID`/`TOSS_CLIENT_SECRET`가 있어야 한다 (레포 밖, `chmod 600`, README §설치 참고). 없으면 앱이 설정 안내 화면만 띄운다.

## 아키텍처 (여러 파일에 걸친 큰 그림)

레이어 체인 — 위→아래로만 의존한다:

```
Popup/PopupView.swift      뷰 (보유/관심/관리/하단/설정안내). 색 토큰은 Popup/Palette.swift
  └ Popup/StockModel.swift @MainActor @Observable — 10초 폴링 루프·회전 인덱스·인증 상태 소유
      └ Toss/TossService.swift  도메인 메서드(positionRows/watchRows/authStatus) + --dump
          └ Toss/TossAPI.swift  URLSession 요청계층 (Bearer·계좌헤더·401/429 재시도)
              └ Toss/TokenStore.swift  actor TokenStore (토큰 캐시·in-flight 공유·디스크 재확인)
Popup/ReorderController.swift  드래그 재배치 세션 + edge 자동 스크롤 (뷰가 관찰)
Toss/TossDTO.swift  API 응답 DTO(수동 init + decimal 헬퍼) / Toss/DisplayRow.swift  service → view 표시용 Row
Storage/Watchlist.swift / Storage/HoldingsOrder.swift  설정 파일(symbols.tsv / holdings_order.txt) I/O + 드래그 순서 저장
Format.swift / ConfigPaths.swift  전 레이어 공용 — 표시 포맷 · ~/.config/tossstock 경로
```

파일별 상세 책임은 SPEC.md §4.6, 각 동작은 §3에 있다.

## 반드시 알아야 할 비자명한 제약 (건드리기 전에 확인)

이것들은 "정리"하면 앱이 조용히 깨진다. 대부분 SPEC.md에 근거가 있다.

- **`MenuBarExtra(.window)`는 의도적이다** (§4.1). NSMenu 드롭다운은 펼치면 런루프가 `.eventTracking`으로 바뀌어 타이머·redraw가 멈춘다. 그래서 폴링도 **`Task.sleep`이고 RunLoop `Timer`가 아니다** ([StockModel.swift:51](tossstock-app/Sources/TossStock/Popup/StockModel.swift#L51)). Timer로 바꾸면 팝업 펼친 채 갱신이 멈춘다.
- **토큰은 client당 1개** (§2.1, §4.4). 폴링마다 재발급 금지 — `TokenStore`가 캐시하고 만료 5분 전 선제 재발급, 401 시 디스크 재확인 후 1회 재발급. 같은 `client_id`를 다른 도구와 공유하면 서로 무효화한다.
- **API의 모든 수치 필드는 문자열**(`"72000"`, `"-0.0418"`) (§4.3). 합성 `Decodable`의 `decode(Double.self)`가 깨지므로 DTO마다 수동 `init(from:)` + `decimal()` 헬퍼로 흡수한다. `currency`는 unknown 값을 흡수하는 관대한 enum(throw하면 holdings 통째 블랭크).
- **통화는 native 그대로 표시**한다 (§5). holdings가 종목별 금액을 종목 통화로만 반환하므로 미국 보유종목의 현재가·평가손익은 **달러로 표시**한다(원화 환산 안 함).
- **색상은 토스증권 규약으로 반전**: 상승/수익 → **빨강**, 하락/손실 → **파랑**, flat → 회색. 일반적인 초록=상승과 반대다 (§3.2, §3.3).
- **드래그 재배치는 수동 `DragGesture`** (§3.2). 메뉴바 `.window`는 비활성 창이라 SwiftUI `.draggable`(AppKit `NSDraggingSession`)이 시작되지 않는다. commit-on-end로 놓는 순간 1회만 재정렬·영속화해 10초 폴링과 충돌하지 않는다.
- **App Sandbox OFF** (§4.2). 토큰 저장이 `~/.config/tossstock` 접근을 요구 → entitlements 파일 없음. 미샌드박스 앱은 `network.client` 없이 네트워크 가능. 서명은 ad-hoc(`codesign --sign -`).
- **ScrollView 높이 붕괴 주의** (§4.2). self-sizing 윈도우에서 `ScrollView` 고유 높이가 0이라 콘텐츠 실측 높이로 고정한다(최대 520).
- **candles throttle**: 관심종목 등락은 종목당 일봉 1회 호출이며 `MARKET_DATA_CHART`(초당 5회) 제한 때문에 호출 간 0.25초 간격을 둔다 (§3.3).

## 런타임 설정 파일 (레포 밖, 런타임 생성)

`~/.config/tossstock/` — `auth.env`(자격증명, 커밋 금지), `token.json`(토큰 캐시), `symbols.tsv`(관심종목, 줄 순서=표시 순서), `holdings_order.txt`(보유종목 드래그 순서). 스키마는 SPEC.md §2.3.
