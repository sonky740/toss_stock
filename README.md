# tossstock — Toss 보유·관심종목 메뉴바 앱

[토스증권 Open API](https://developers.tossinvest.com/docs)로 Toss 증권 데이터를 가져와 macOS 메뉴바에 표시하는 **SwiftUI 앱**이다. 펼친 채 **10초마다 실시간 갱신**된다.

- 메뉴바 한 줄에 보유종목을 **회전** 노출 (`종목명 현재가 ±수익률%`)
- **📊 보유종목** — 매입가 대비 누적 수익률·평가손익
- **⭐ 관심종목** — 당일 등락률·등락액
- 패널에서 관심종목 **인라인 추가·삭제**

자세한 동작 명세는 [SPEC.md](./SPEC.md) 참고.

> 과거 SwiftBar 셸 플러그인과 병행했으나, **결정 #2에 따라 플러그인을 제거하고 네이티브 앱으로 일원화**했다. SwiftBar 드롭다운은 펼치면 멈추지만(NSMenu 런루프 제약), 네이티브 앱은 `MenuBarExtra(.window)`라 펼친 채로도 갱신된다.

---

## 요구 사항

| 항목 | 비고 |
|---|---|
| macOS 14+ | |
| Swift 6 툴체인 | Xcode 16+ 또는 swift toolchain. SwiftPM, **외부 의존성 0** |
| 토스 Open API 자격증명 | 토스증권 WTS → 설정 → Open API 에서 `client_id` / `client_secret` 발급 |

---

## 설치

### 1. 자격증명 설정

`~/.config/tossstock/auth.env` 를 만들고 발급받은 키를 적는다 (레포 밖, 권한 600):

```bash
mkdir -p ~/.config/tossstock
umask 077
cat > ~/.config/tossstock/auth.env <<'EOF'
TOSS_CLIENT_ID='발급받은_client_id'
TOSS_CLIENT_SECRET='발급받은_client_secret'
EOF
chmod 600 ~/.config/tossstock/auth.env
```

> 이 파일은 비밀이다. 절대 저장소에 커밋하지 말 것.

### 2. 빌드 · 실행

```bash
cd tossstock-app
./Packaging/build.sh           # swift build → build/TossStock.app (ad-hoc 서명)
open build/TossStock.app       # 메뉴바에 등록
```

> Xcode 불필요(SwiftPM). 데이터 레이어만 헤드리스로 확인하려면 `build/TossStock.app/Contents/MacOS/TossStock --dump`.

### 인증

자격증명을 설정하면 앱이 OAuth2 토큰을 자동 발급·캐시한다 (`~/.config/tossstock/token.json`, 만료 5분 전 선제 재발급). 패널 하단 **인증 점검** 버튼으로 토큰 발급 여부·계좌번호·토큰 만료시각을 확인할 수 있다.

자격증명이 없으면 `🔐 Toss API 설정 필요` 화면이 표시된다.

> **토큰은 client당 1개**다. 재발급 시 이전 토큰이 즉시 무효화되므로, 같은 `client_id`를 다른 도구와 공유하면 서로 토큰을 무효화할 수 있다. 다른 도구와 함께 쓰려면 **도구별로 별도 `client_id`를 발급**하라.

---

## 관심종목 설정

관심종목은 TSV 파일에 저장된다.

- 경로: `~/.config/tossstock/symbols.tsv`
- 형식: 한 줄당 `종목코드<TAB>별칭` (별칭은 비워도 됨 → 종목명 사용)
- `#`로 시작하는 줄은 주석
- **종목코드**는 토스 Open API 표준 코드 — KR 주식 6자리 숫자(`005930`), 한국 ETF(`0190C0`), 미국 티커(`AAPL`)·ETF(`SOXX`).
- 최초 실행 시 기본값으로 자동 생성:

  ```tsv
  0190C0	현피AI
  0167A0	SOL탑
  ```

### 패널에서 관리 (권장)

- **관심종목 관리** 헤더를 클릭해 펼친다.
- **추가** — 코드 입력 + 별칭(선택) 입력 → `추가`. 이미 등록된 코드면 무시.
- **삭제** — 등록 종목 행의 `X` 클릭으로 즉시 제거.

직접 파일을 편집해도 되며, 다음 새로고침에 반영된다.

---

## 사용

| 위치 | 내용 |
|---|---|
| 메뉴바 (한 줄) | 보유종목을 새로고침마다 회전 표시. 보유종목이 없으면 관심종목으로 폴백, 둘 다 없으면 `📈 종목 없음` |
| 📊 보유종목 | `종목명  현재가  ±수익률%  평가손익` — 수익 초록 / 손실 빨강 |
| ⭐ 관심종목 | `종목명  현재가  ▲등락률% (▲등락액)` — 상승 ▲초록 / 하락 ▼빨강 |
| 새로고침 | 즉시 갱신 |
| 인증 점검 | 패널 내 토큰·계좌 상태 표시 |

### 통화 표시

- 국내주식: ₩ (예: `₩351,500`, 평가손익 `+16,750원`)
- 미국주식: $ (예: `$1,234.05`, 평가손익 `+$232.00`)
- 보유종목 현재가·평가손익 모두 **종목 통화 그대로** 표시한다. 토스 Open API가 종목별 금액을 native 통화로 반환하기 때문이다 (자세한 이유는 SPEC.md §5).

---

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| `🔐 Toss API 설정 필요` | `~/.config/tossstock/auth.env` 미설정 → client_id/secret 작성 |
| `보유종목 조회 실패 (인증 확인)` | 토큰 무효/계좌 오류 → **인증 점검**으로 점검 |
| 메뉴바가 비거나 `종목 없음` | 보유·관심종목 모두 없음, 또는 네트워크/인증 실패 |
| 관심종목 `조회실패` | 종목코드 오타(표준 코드인지 확인) 또는 인증 문제 |
| 관심종목 `등락 데이터 없음` | 신규상장 등으로 전일 일봉이 없음 — 현재가만 표시 |

---

## 파일 구조

```
.
├── README.md              # 이 문서
├── SPEC.md                # 동작 명세 (source of truth)
└── tossstock-app/         # 네이티브 메뉴바 앱 (SwiftPM)
    ├── Package.swift
    ├── Sources/TossStock/*.swift
    └── Packaging/{Info.plist, build.sh}

~/.config/tossstock/auth.env      # client_id / client_secret (비밀, chmod 600)
~/.config/tossstock/token.json    # access token 캐시 (런타임 생성)
~/.config/tossstock/symbols.tsv   # 관심종목 설정 (런타임 생성)
```
