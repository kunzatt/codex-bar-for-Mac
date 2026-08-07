# CodexBar 아키텍처

```text
NSStatusItem + hover/click popovers
                │
                ▼
      UsageStore (@MainActor)
       │              │
       ▼              ▼
AccountRepository   PollingCoordinator (30 s / 2 min)
                       │
                       ▼
                 CodexClientPool actor
                       │
                       ▼
       CodexAppServerClient actor (profile마다 하나)
                       │
                       ▼
       codex app-server --stdio, profile CODEX_HOME
```

## UI와 상태

`StatusBarController`는 가변 너비 `NSStatusItem`을 만들고 `NSTrackingArea`로 hover를 감지합니다. 하나의 transient `NSPopover` 안에서 420ms hover 후 compact SwiftUI view를 보이고, 클릭하면 같은 창을 full view로 전환합니다. 하나의 창만 유지해 hover와 클릭 전환 중 보이지 않는 팝오버가 입력을 가로채지 않게 합니다.

`UsageStore`는 메인 액터에서 선호 설정과 계정 snapshot을 소유합니다. 한 계정의 실패는 그 계정 snapshot을 stale/auth-required로만 전환하므로 다른 계정의 갱신과 메뉴바는 계속 동작합니다.

## 프로토콜 경계

`JSONValue`, `JSONLMessage`, `JSONLLineBuffer`, `ProtocolMapper`는 app-server의 불안정한 JSON 형태를 캡슐화합니다. DTO 키가 추가되거나 nullable 값이 늘어나도 관대한 디코딩을 하며, UI는 `AccountUsageSnapshot`, `RateLimitBucket`, `TokenUsageSummary` 같은 도메인 모델만 봅니다.

클라이언트는 `initialize` 응답 뒤에만 요청을 전송하고 `initialized` 알림을 보냅니다. stdout은 JSONL buffer가 처리합니다. 잘못된 JSON 한 줄은 건너뛰고 다음 행을 계속 읽습니다. ID가 있는 응답은 actor 내부 continuation 사전에 연결하고, `account/login/completed`는 login waiter에 전달합니다.

`account/rateLimits/read`와 `account/usage/read`는 최신 생성 스키마에 맞춰 params를 생략합니다. `account/read`에는 app-server가 요구하는 `{ "refreshToken": ... }` 필드를 항상 넣으며, 새 프로세스의 첫 요청만 `true`, 이후 폴링은 `false`로 보냅니다. 첫 계정 읽기를 완료한 뒤 사용량 요청을 시작해 만료 직전 세션의 경합을 피합니다. `account/rateLimits/updated`와 `account/updated` 알림은 `UsageStore`에 전달되어 즉시 안전한 read를 다시 요청합니다. 이미 읽는 중이면 한 번의 후속 read를 큐잉하므로 sparse nullable 필드가 마지막 정상 snapshot을 지우지 않습니다.

## 계정 격리와 수명

계정은 `CodexClientPool`의 UUID 키와 해당 계정 `CODEX_HOME`으로 분리됩니다. 앱 관리 프로필은 `cli_auth_credentials_store = "file"`을 갖고, `Process.environment["CODEX_HOME"]`이 항상 그 계정 경로를 가리킵니다. 앱은 인증 파일을 해석하지 않습니다.

각 client는 한 지속 프로세스를 유지합니다. 종료 시 pending request/login continuation을 실패 처리하고, 이후 polling refresh가 프로세스를 다시 시작합니다. Polling은 30/60/120/300초 backoff에 작은 jitter를 더하고, 성공하면 기본 주기로 복귀합니다. 앱 종료 요청은 `terminateLater`로 잠시 보류한 뒤 모든 child process에 종료 신호를 보내고 짧은 grace period를 기다린 후 macOS 종료를 승인합니다. 팝오버 내부 입력과 같은 앱의 닫힘은 macOS transient 동작에 맡기고, 다른 앱이나 Desktop 클릭만 global mouse monitor가 보완합니다. 이 감시는 팝오버가 닫히면 즉시 제거하며, 클릭 시점의 좌표와 timestamp로 늦게 도착한 이벤트가 새 팝오버를 닫지 않게 합니다. hover 미리보기의 tracking area는 하나만 유지합니다.

## 저장 및 삭제 안전성

`AccountRepository`는 `accounts.json`을 원자적으로 저장합니다. 앱 관리 프로필 삭제는 `Accounts/<UUID>/codex-home`와 정확히 일치하는 경로인지 확인한 후 그 UUID 폴더만 제거합니다. Application Support 전체나 `~/.codex`를 재귀 삭제하지 않습니다.

## 검증 경계

`scripts/test.sh`는 UI·실제 자격 증명 없이 core Swift source를 컴파일한 뒤 독립 unit runner를 실행합니다. GUI hover, device-code 로그인, sleep/wake와 실제 child process 수명은 Xcode/로그인된 macOS GUI 환경에서 수행할 수동 통합 검증 항목입니다.
