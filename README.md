# tossstock — Toss 보유·관심종목 메뉴바 플러그인

[SwiftBar](https://github.com/swiftbar/SwiftBar) 플러그인. [`tossctl`](https://github.com/) (tossinvest-cli)로 Toss 증권 데이터를 가져와 macOS 메뉴바에 표시한다.

- 메뉴바 한 줄에 보유종목을 **10초마다 회전** 노출 (`종목명 현재가 ±수익률%`)
- 드롭다운 **📊 보유종목 비교** — 매입가 대비 누적 수익률·평가손익
- 드롭다운 **⭐ 관심종목** — 당일 등락률·등락액
- 메뉴에서 관심종목 **추가·삭제** (osascript 다이얼로그)

자세한 동작 명세는 [SPEC.md](./SPEC.md) 참고.

---

## 요구 사항

| 항목 | 비고 |
|---|---|
| macOS | osascript(AppleScript) 다이얼로그 사용 |
| [SwiftBar](https://github.com/swiftbar/SwiftBar) | `brew install --cask swiftbar` |
| `tossctl` | `/usr/local/bin/tossctl` 에 설치 가정 (tossinvest-cli) |
| `jq` | `/opt/homebrew/bin/jq` 에 설치 가정 — `brew install jq` |

> **PATH 주의**: 스크립트 8번 줄이 `tossctl`(`/usr/local/bin`)·`jq`(`/opt/homebrew/bin`) 경로를 하드코딩한다. 설치 위치가 다르면 그 줄의 `PATH`를 수정해야 한다. `which tossctl jq`로 실제 경로를 확인하라.

---

## 설치

1. SwiftBar를 설치하고 실행한 뒤 플러그인 폴더를 지정한다. 현재 폴더 확인:

   ```bash
   defaults read com.ameba.SwiftBar PluginDirectory
   ```

2. `SwiftBar/tossstock.10s.sh`를 그 폴더에 두고 실행 권한을 준다 (이 저장소의 `SwiftBar/` 폴더 자체를 플러그인 폴더로 지정했다면 복사는 생략).

   ```bash
   DIR="$(defaults read com.ameba.SwiftBar PluginDirectory)"
   cp SwiftBar/tossstock.10s.sh "$DIR/"   # SwiftBar/ 를 플러그인 폴더로 지정했다면 생략
   chmod +x "$DIR/tossstock.10s.sh"
   ```

3. SwiftBar 메뉴 → **Refresh All**.

> 파일명의 `10s`가 새로고침 주기(10초)다. `.30s.`, `.1m.` 등으로 바꾸면 주기가 바뀐다.

### 인증

`tossctl`에 유효한 Toss 세션이 필요하다. 메뉴의 **인증 상태 확인**으로 점검하거나:

```bash
tossctl auth status
```

세션이 없으면 모든 시세가 `조회 실패 (인증 확인)`으로 표시된다. `tossctl auth` 관련 명령으로 로그인하라.

---

## 관심종목 설정

관심종목은 TSV 파일에 저장된다.

- 경로: `~/.config/tossstock/symbols.tsv`
- 형식: 한 줄당 `종목코드<TAB>별칭` (별칭은 비워도 됨 → 종목명 사용)
- `#`로 시작하는 줄은 주석
- 최초 실행 시 기본값으로 자동 생성:

  ```tsv
  0190C0	현피AI
  0167A0	SOL탑
  ```

### 메뉴에서 관리 (권장)

- **➕ 종목 추가…** — 종목코드 입력 → 별칭 입력(선택). 이미 등록된 코드면 알림.
- **➖ 종목 삭제** → **❌ 별칭 (코드)** 클릭으로 즉시 제거.

직접 파일을 편집해도 되며, 다음 새로고침에 반영된다.

---

## 사용

| 위치 | 내용 |
|---|---|
| 메뉴바 (한 줄) | 보유종목을 새로고침마다 회전 표시. 보유종목이 없으면 관심종목으로 폴백, 둘 다 없으면 `📈 종목 없음` |
| 📊 보유종목 비교 | `종목명  현재가  ±수익률%  평가손익` — 수익 green / 손실 red |
| ⭐ 관심종목 | `종목명  현재가  ▲등락률% (▲등락액)` — 상승 ▲green / 하락 ▼red |
| 🔄 새로고침 | 즉시 갱신 |
| 인증 상태 확인 | 터미널에서 `tossctl auth status` |

### 통화 표시

- 국내주식: ₩ (예: `₩351,500`)
- 미국주식: 현재가만 $ (예: `$1,234.05`)
- **평가손익은 항상 원화**로 표시한다. `tossctl portfolio positions`가 미국주식도 원화로 환산해 반환하고, 환율 역산이 부정확하기 때문 (자세한 이유는 SPEC.md 4절).

---

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| `보유종목 조회 실패 (인증 확인)` | 세션 만료/없음 → `tossctl auth status` 확인 후 재로그인 |
| 메뉴바가 비거나 `종목 없음` | 보유·관심종목 모두 없음, 또는 tossctl/jq 실행 실패 |
| 아무 항목도 안 뜸 | `tossctl`/`jq` 경로 문제 → 스크립트 8번 줄 `PATH` 확인 |
| 관심종목 `조회실패` | 종목코드 오타 또는 인증 문제 |
| 다이얼로그가 안 뜸 | macOS 자동화/접근성 권한에서 SwiftBar 허용 확인 |

---

## 파일 구조

```
.
├── README.md              # 이 문서
├── SPEC.md                # 동작 명세 (source of truth)
└── SwiftBar/
    └── tossstock.10s.sh   # 플러그인 본체

~/.config/tossstock/symbols.tsv   # 관심종목 설정 (런타임 생성)
/tmp/tossstock_rotate.idx         # 메뉴바 회전 인덱스 (런타임)
```
