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

린트·포맷:

```bash
TOOLCHAIN_DIR=/Library/Developer/CommandLineTools swiftlint lint --strict   # 린트 (.swiftlint.yml)
swift format lint --strict -r Sources                                       # 포맷 검사 (.swift-format)
swift format -i Sources/TossStock/Format.swift                              # 포맷 자동 정리(파일 단위)
```

`TOOLCHAIN_DIR`이 필요한 이유 — 이 머신엔 Xcode 없이 Command Line Tools만 있어서 SwiftLint가 `sourcekitd`를 Xcode 레이아웃에서 찾다 크래시한다. 빼면 `Loading sourcekitdInProc.framework failed`로 죽는다. `swift format`은 툴체인 번들이라 이 변수가 필요 없고, 서드파티 SwiftFormat(nicklockwood, `.swiftformat`)과는 다른 도구다. **들여쓰기는 2칸**(swift-format 기본값 = Google·Airbnb 가이드 = apple/swift 저장소). 두 도구의 역할은 갈라 뒀다 — 포맷 계열은 swift-format이 담당하고 SwiftLint 쪽 대응 룰(`line_length`·`opening_brace` 등)은 꺼 뒀다. 같은 것을 다투면 고칠 수 없는 상태가 된다. 근거는 각 설정 파일 상단 주석.

- **테스트 스위트 없음.** 데이터 레이어 검증은 `--dump` 헤드리스 실행이 유일한 수단이다 (네트워크·인증·디코딩 경로를 GUI 없이 통과시킨다).
- 실행하려면 `~/.config/tossstock/auth.env`에 `TOSS_CLIENT_ID`/`TOSS_CLIENT_SECRET`가 있어야 한다 (레포 밖, `chmod 600`, README §설치 참고). 없으면 앱이 설정 안내 화면만 띄운다.

## 아키텍처 (여러 파일에 걸친 큰 그림)

레이어 체인 — 위→아래로만 의존한다:

```
Popup/PopupView.swift      뷰 (보유/관심/관리/하단/설정안내). 색 토큰은 Popup/Palette.swift
  ├ Popup/SearchSection.swift  관심종목 관리 안의 종목 검색 UI (팝업 전체 재평가를 피하려 분리)
  └ Popup/StockModel.swift @MainActor @Observable — 10초 폴링 루프·회전 인덱스·인증/검색 상태 소유
      └ Toss/TossService.swift  도메인 메서드(positionRows/watchRows/quotes/authStatus) + --dump
          └ Toss/TossAPI.swift  URLSession 요청계층 (Bearer·계좌헤더·401/429 재시도)
                ├ Toss/TokenStore.swift  actor TokenStore (토큰 캐시·in-flight 공유·디스크 재확인)
                ├ Toss/StockUniverse.swift  actor (검색용 전체 종목 수집·하루 캐시·로컬 검색)
              └ Toss/PrevCloseStore.swift  actor (전일종가 세션별 캐시 + candles 슬롯 예약)
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
- **국내 일봉 종가 ≠ 전일 기준가** (§3.3). 국내 종목의 일봉 `closePrice`는 **NXT 시간외(~20:00) 마감가**라서 토스 앱·웹이 쓰는 정규장 기준가와 다르다(실측 005930 2026-07-30: 213,500 vs 207,000). 그래서 국내는 일봉 `timestamp`로 직전 거래일을 얻고 그 날 **15:31 1분봉**(`before=<거래일>T06:32:00Z`)의 종가를 기준가로 쓴다. 미국은 일봉 종가가 정규장 종가라 그대로 쓴다 — 이 분기를 없애면 국내 등락률이 몇 %p 틀어진다. 현재가 쪽은 시간외에도 `/prices` 실시간가를 쓴다(토스와 동일 조합).
- **candles throttle + 세션별 캐시**: 전일종가는 세션 안에서 불변이라 종목당 세션당 1회만 조회한다(`PrevCloseStore`). 호출 간 0.25초 간격을 둔다 — 폴링마다 재조회하도록 되돌리면 10초 주기와 충돌한다 (§3.3). 실제 `MARKET_DATA_CHART` 한도는 응답 헤더 `X-RateLimit-Limit` 실측 기준 **초당 20회**이고 0.25초는 그보다 보수적인 값이다.
- **페이싱은 슬롯 예약이지 actor 안의 sleep이 아니다** (§3.3). `reserveCandleSlot()`은 중단점 없이 슬롯만 잡고 대기는 호출자가 한다. actor 메서드 안에서 `await Task.sleep`을 하는 형태로 되돌리면 그 중단점에서 격리가 풀려 다른 호출자가 같은 슬롯을 받는다 — 실측(동시 호출자 2)에서 호출 간격 11개 중 5개가 0.000초였다. 호출자가 폴링 하나뿐일 땐 안 드러나고, 검색이 함께 도는 순간 터진다. `--dump`의 `=== candles 페이싱 ===` 블록이 이 계약을 검사한다.
- **검색 등락률은 관심종목과 같은 경로를 타야 한다** (§3.4). `TossService.quotes`가 `prevClose`를 그대로 쓰고 `PrevCloseStore` 캐시도 공유한다. 검색 쪽에서 일봉 `closePrice`를 직접 쓰면 국내 종목이 NXT 시간외 마감가를 기준가로 잡아 같은 종목이 두 섹션에서 다른 등락률을 보인다.
- **유니버스 캐시만 벽시계 날짜 키를 쓴다** (§2.3). 위의 전일종가 캐시와 정반대라 헷갈리기 쉽다 — 유니버스는 일 배치 데이터라 갱신이 하루 늦어도 신규 상장 종목이 하루 늦게 검색될 뿐이고, 전일종가는 09:00 KST 세션 롤을 놓치면 등락률이 한 세션 어긋난다.
- **캐시 키를 KST 날짜로 되돌리지 말 것** (§3.3). 기준가가 갈리는 경계는 자정이 아니라 **09:00 KST**(국내 개장 / 미국 오버나이트 개장 = 20:00 ET)다. 날짜 키를 쓰면 00:00~09:00 KST에 채운 값이 세션 내내 남아 등락률이 한 세션 어긋나고, **앱을 재시작해야만** 맞는다. 그래서 키는 시장 시계 종목(`005930`/`SPY`)의 최신 일봉 날짜이고, 기준 봉도 인덱스가 아니라 날짜 비교로 고른다(현 세션 미거래 종목은 `candles[0]`이 곧 기준 봉). 미국 일봉 stamp(`T13:00+09:00` = 00:00 ET)는 롤 시각이 아니다 — 라벨보다 4시간 이르게 롤한다. 벽시계 계산으로 대체하려는 시도는 여기서 깨진다.

## 런타임 설정 파일 (레포 밖, 런타임 생성)

`~/.config/tossstock/` — `auth.env`(자격증명, 커밋 금지), `token.json`(토큰 캐시), `symbols.tsv`(관심종목, 줄 순서=표시 순서), `holdings_order.txt`(보유종목 드래그 순서), `universe.json`(검색용 전체 종목 15,176건·931KB, 하루 1회 갱신). 스키마는 SPEC.md §2.3.
