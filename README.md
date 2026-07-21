# CodexBar

CodexBar는 여러 ChatGPT Pro Codex 계정의 남은 쿼터를 macOS 메뉴바에서 확인하는 개인용 앱입니다. 대표 계정의 `C 41%` 같은 잔여량을 메뉴바에 표시하고, 잠깐 올리면 간단한 계정 비교를, 클릭하면 전체 사용량 패널을 엽니다.

Finder와 Desktop에는 파란 Codex 심볼 아래 굵은 `Codex Bar` 텍스트가 있는 전용 앱 아이콘을 사용합니다.

> 스크린샷 자리: 첫 실행 후 메뉴바의 CodexBar 아이콘과 팝오버를 캡처해 이곳에 추가하세요.

## Homebrew 설치와 원격 업데이트

Apple Silicon Mac에서는 Homebrew Cask로 설치할 수 있습니다. `codexbar`라는 이름은 이미 다른 앱이 사용 중이므로 이 앱의 Cask 이름은 `codexbar-for-mac`입니다.

```zsh
brew tap kunzatt/codex-bar-for-Mac
brew install --cask codexbar-for-mac
```

새 버전이 GitHub Release에 올라온 뒤 다음 명령으로 원격 업데이트합니다.

```zsh
brew update
brew upgrade --cask codexbar-for-mac
```

제거할 때 로그인 프로필까지 지우려면 다음을 사용합니다.

```zsh
brew uninstall --zap --cask codexbar-for-mac
```

릴리스 제작자는 앱의 `CFBundleShortVersionString`을 올린 뒤 아래 명령으로 GitHub Release용 ZIP과 SHA-256을 생성합니다. 생성된 SHA-256을 `Casks/kunzatt-codexbar.rb`에 반영하고, ZIP을 같은 버전의 `v<version>` GitHub Release에 업로드합니다.

```zsh
./scripts/package-release.sh
```

## 요구 사항

- macOS 14 Sonoma 이상, Apple Silicon 또는 Intel Mac
- 전체 Xcode(권장) 또는 Swift 6 명령행 도구
- ChatGPT 앱 또는 Codex CLI. 기본 탐색 경로는 `/Applications/ChatGPT.app/Contents/Resources/codex`입니다.
- ChatGPT Pro로 로그인할 수 있는 Codex 계정

CodexBar는 OpenAI Platform API 키, 웹 스크래핑, 비공식 REST 엔드포인트를 사용하지 않습니다. 로컬 `codex app-server --stdio`만 호출합니다.

## 빌드와 실행

Xcode가 설치된 환경에서는 [CodexBar.xcodeproj](CodexBar.xcodeproj/project.pbxproj)를 열고 `CodexBar` scheme을 실행합니다. 앱은 `LSUIElement` 설정을 사용하므로 Dock 아이콘 없이 메뉴바에서만 동작합니다.

터미널에서는 다음을 실행할 수 있습니다.

```zsh
cd CodexBar
./scripts/build.sh
```

터미널 없이 실행할 `.app` 번들은 다음 명령으로 만듭니다.

```zsh
cd CodexBar
./scripts/package-app.sh
open dist/CodexBar.app
```

생성된 `dist/CodexBar.app`을 `/Applications`로 드래그하면 일반 macOS 앱처럼 Finder나 Spotlight에서 실행할 수 있습니다. 같은 앱을 터미널과 Finder에서 동시에 실행하면 메뉴바 항목이 중복되므로, 한 방식만 실행하세요.

한 위치에 설치한 앱을 이후 버전으로 교체하려면 앱을 먼저 종료한 뒤 다음을 실행합니다. 기존 번들은 휴지통으로 이동하므로 필요하면 복구할 수 있습니다.

```zsh
cd CodexBar
./scripts/install-or-update.sh "$HOME/Applications/CodexBar.app"
```

다른 위치를 계속 쓰려면 해당 위치를 인자로 넘기면 됩니다. 예를 들어 Desktop 설치본은 `./scripts/install-or-update.sh "$HOME/Desktop/CodexBar.app"`로 갱신합니다.

전체 Xcode가 없으면 스크립트가 Swift Package 빌드로 대체합니다. 이는 소스 컴파일 검증용이며, 메뉴바 UI 실행에는 macOS GUI 세션이 필요합니다.

## 테스트

프레임워크 의존성이 없는 단위 테스트 러너는 다음과 같습니다.

```zsh
cd CodexBar
./scripts/test.sh
```

현재 테스트는 JSONL 응답/알림 디코딩, multi-bucket 제한, primary/secondary window, null payload, `Int64` 토큰, malformed JSONL 복구, 기간 포맷, backoff, 메타데이터 저장, 로그 마스킹을 검증합니다. 실제 계정 로그인이나 인증 파일을 읽지 않습니다.

## 첫 계정 추가

1. 메뉴바의 `C --`를 클릭하고 **계정 추가**를 선택합니다.
2. 별칭을 정하고 **Device Code 로그인 시작**을 누릅니다.
3. 브라우저가 열리면 원하는 ChatGPT Pro 계정으로 로그인하고 화면에 표시된 코드를 입력합니다.
4. 로그인 완료 알림을 받으면 CodexBar가 계정/플랜/쿼터를 다시 읽습니다.

추가 Pro 계정도 같은 순서를 반복합니다. 계정마다 독립된 `CODEX_HOME`과 `codex app-server` 프로세스를 사용하므로 인증이 섞이지 않습니다.

기존 기본 Codex 로그인(`~/.codex`)을 쓰려면 설정의 **기본 ~/.codex 등록**을 선택할 수 있습니다. 이 프로필은 외부 프로필로 표시되며, CodexBar가 디렉터리나 인증 파일을 삭제하지 않습니다.

## 대표 계정과 갱신

- 전체 패널의 계정 행을 선택하거나 설정의 별을 눌러 대표 계정을 변경합니다.
- 메뉴바는 대표 계정의 `codex` 버킷을 우선 표시합니다. 없으면 첫 번째 제공 버킷을 사용합니다.
- rate limit은 계정마다 30초마다 갱신하고, 토큰 누계는 2분마다 갱신합니다.
- 요청 실패 시 마지막 정상 값은 유지하고 30초 → 60초 → 120초 → 300초 backoff를 적용합니다. Mac이 잠자기에서 깨어나면 즉시 전체 갱신합니다.

## 데이터와 보안

앱이 만든 계정 메타데이터는 다음에 저장됩니다.

```text
~/Library/Application Support/CodexBar/
├── accounts.json
└── Accounts/<account-uuid>/codex-home/
```

애플리케이션 지원 디렉터리와 계정별 디렉터리는 `0700`, 메타데이터와 생성된 `auth.json`은 가능한 경우 `0600` 권한으로 유지합니다. `accounts.json`에는 별칭, UUID, 로컬 경로, 활성화/대표 계정 설정만 저장합니다.

CodexBar는 `auth.json`의 내용을 직접 읽거나 파싱하지 않습니다. 토큰·쿠키·API 키·프롬프트·대화 내용도 저장하거나 로그로 남기지 않습니다. stderr는 드레인만 하며 영구 저장하지 않고, 오류 표시도 자격 증명 문자열을 노출하지 않는 일반 메시지로 제한합니다.

## 알려진 제한

- `codex app-server`는 Codex CLI의 experimental 기능입니다. Codex 업데이트로 응답 스키마가 바뀔 수 있으므로 원시 JSON은 `ProtocolMapper` 경계에서만 처리합니다.
- v1은 ChatGPT Pro Codex 사용량만 다룹니다. API 비용, 다른 플랜용 최적화, 자동 계정 전환, reset credit 자동 소비는 지원하지 않습니다.
- 실제 device-code 로그인과 메뉴바 hover 검증은 GUI와 로그인된 계정이 필요합니다.

## 문제 해결

**Codex 실행 파일을 찾지 못함**

설정에서 `codex` 실행 파일을 직접 선택하세요. ChatGPT 앱 설치본은 일반적으로 `/Applications/ChatGPT.app/Contents/Resources/codex`에 있습니다.

**로그인이 만료됨**

팝오버에서 계정을 다시 추가하거나, 외부 `~/.codex` 프로필이라면 평소 사용하던 Codex CLI 로그인 절차를 완료한 뒤 새로고침하세요.

**사용량이 표시되지 않음**

Codex CLI가 최신인지 확인한 뒤 설정에서 실행 파일 경로를 점검하세요. 계정은 등록되지만 플랜/쿼터가 제공되지 않을 수 있으며, 이 경우 앱은 `C --` 및 마지막 오류 상태를 유지합니다.

**앱 제거와 인증 파일**

앱 관리 프로필은 설정의 **로그아웃 후 로컬 프로필 삭제**를 선택하면 해당 UUID 계정 폴더만 지웁니다. `~/.codex`를 포함한 외부 프로필은 목록에서만 제거되며, 앱을 삭제해도 인증 파일은 남습니다. 필요하면 Finder에서 `~/Library/Application Support/CodexBar`를 직접 제거하세요.
