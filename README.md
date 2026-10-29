# Proxima for Android

Proxima는 VLESS 링크에 집중한 Android VPN 클라이언트입니다. 사용자는 공유 링크나 HTTPS 구독을 추가하고, 앱은 이를 Xray JSON 구성으로 변환해 Android `VpnService`의 TUN 인터페이스에서 기기 트래픽을 처리합니다.

복잡한 범용 프록시 설정 편집기를 목표로 하지 않습니다. 대신 VLESS 프로필 추가, 연결 제어, 노드 선택, 트래픽 확인, 네트워크 진단처럼 Android에서 실제로 자주 쓰는 흐름을 앱 안에서 단순하게 다루는 것을 목표로 합니다.

## 제공 기능

- VLESS 공유 링크 추가, 편집, 검증
- VLESS 링크 목록을 제공하는 HTTPS 구독 가져오기
- VPN 연결 전에도 가능한 Rule/Global 모드의 노드 선택
- 구독 응답의 `subscription-userinfo` 기반 사용량·남은 트래픽·만료일 및 플랜명 표시
- 링크를 앱 내부 실행용 Xray 구성으로 자동 변환
- Android VPN 권한 요청과 포그라운드 `VpnService` 연결 제어
- Android 빠른 설정 타일에서 최근 프로필 즉시 연결·해제
- Rule, Global, Direct 작동 모드 전환
- Rule/Global 모드의 현재 노드 조회·선택(연결 중 변경 시 Xray 자동 재시작)
- Xray metrics 기반 실시간 업로드·다운로드 속도와 누적 트래픽 표시
- DNS 조회, 외부 IP 조회, 네트워크 진단 도구
- 로컬 VLESS 링크 파일 가져오기·내보내기
- IPv6/MTU 설정
- 앱 샌드박스 프로필 저장과 Android 백업 차단
- 휴대폰과 태블릿/넓은 화면에 맞춘 Material 3 UI

## 구조

```text
lib/                         Flutter UI와 상태 관리
android/app/src/main/kotlin/ MethodChannel, 프로필 저장소, VpnService
android/app/libs/            고정 버전 Android libXray AAR
```

Flutter 계층은 화면, 상태 관리, 프로필 입력 검증을 담당합니다. Android 계층은 프로필 저장소, MethodChannel, `VpnService`, 알림, 빠른 설정 타일을 담당합니다. 실제 프록시 코어 실행은 `libXray` AAR을 통해 연결되며, Android VPN 환경에 맞게 TUN fd와 소켓 `protect()` 처리를 수행합니다.

## 빌드

Flutter 3.47+, JDK 17, Android SDK가 준비된 환경에서 다음을 실행합니다. 프로젝트의 Gradle wrapper는 8.14.3으로 고정되어 있습니다. Flutter가 JDK 25처럼 호환되지 않는 JDK를 선택한다면 `flutter config --jdk-dir=/path/to/jdk17`로 JDK 17을 지정하세요.

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

포함된 `libxray-android-v26.9.9.aar`의 SHA-256은 `df0cabde00c20c08b9ece66e83fddeabcf9aa8061057674a647eb34508c72be3`입니다. AAR은 Android ABI를 포함합니다.

현재 `release` 빌드도 개발 편의를 위해 debug 키로 서명됩니다. 실제 배포 전에는 Play App Signing 또는 별도 release keystore로 교체해야 합니다.

## Proxima 계정 연결

구독 탭에서 Proxima 계정으로 로그인하고 계정의 플랜·사용량을 확인하거나 VPN 구독을 가져올 수 있습니다. 수동 VLESS 프로필은 로그인 없이 계속 사용할 수 있습니다.

관리자의 `/admin/oauth-apps`에 `Proxima for Android`가 다음 설정으로 등록되어 있습니다.

- 유형: 모바일·데스크톱 앱 (PKCE), 시크릿 없음
- 콜백: `kr.kimrasng.proxima://oauth/callback` (정확히 일치해야 함)
- 권한: `profile subscription:read plan:read`

등록된 공개 Client ID `pxc_mijtWOQwez9cG08Zq4MevOY-`를 기본값으로 사용하므로 일반 빌드로 계정 로그인을 사용할 수 있습니다. 다른 서버 등록을 사용하려면 Client ID를 빌드에 전달합니다. 서버 앱의 Client secret은 앱에 넣지 않습니다.

```bash
flutter build apk --debug --dart-define=PROXIMA_OAUTH_CLIENT_ID=등록된_Client_ID
```

로그인은 `m.proxima-cloud.space`의 시스템 브라우저 화면에서 진행됩니다. 네이티브 AppAuth가 요청마다 PKCE S256과 state를 만들고 콜백을 검증합니다. 액세스 토큰과 회전하는 리프레시 토큰은 하나의 세션으로 기기 보안 저장소에 보관합니다. 동시 API 요청은 갱신 작업을 공유하며, 계정 연결 만료 시 다시 로그인해야 합니다. 로그아웃은 서버 토큰 폐기에 성공한 뒤 저장된 계정 정보를 지웁니다. 서버에 연결할 수 없으면 재시도할 수 있도록 세션을 유지합니다. 이미 가져온 VPN 프로필은 계정 로그아웃과 별도로 관리합니다.

구독 가져오기는 기존 VLESS 검증과 구독 파서를 사용하며, 같은 구독 주소가 있으면 해당 프로필을 업데이트하고 선택합니다. 기본 구독 주소에서 소켓 연결 오류나 시간 초과가 발생하면 계정 API가 제공한 다른 HTTPS 구독 주소를 순서대로 시도합니다. 접근 거부나 잘못된 구독 내용은 다른 도메인으로 재시도하지 않습니다. 계정 데이터와 토큰을 WebView나 로그에 전달하지 않습니다.

UI 변경 기준: 기존 구독 화면의 Material 3 카드·ListTile·버튼을 재사용합니다. 로그인 전 주 동작은 계정 로그인, 로그인 후 주 동작은 구독 가져오기입니다. 계정 이름/이메일, 플랜/사용량, 가져오기 결과 순으로 정보를 표시하고 오류는 계정 카드 안에서 재시도할 수 있게 합니다. 별도 로그인 폼이나 비밀번호 입력은 추가하지 않습니다.

계정 카드의 오류·가져오기 결과는 17 logical px, 이메일·플랜 사용량·처리 상태는 15 logical px를 사용하며, 색상과 글꼴·굵기는 기존 테마를 따릅니다. 로그인 전 연결 목적은 'VPN 구독 연결' 제목으로 안내하며 중복 설명 문장은 두지 않습니다. 로딩 상태는 진행 표시와 같은 문구를 화면과 접근성 레이블에 함께 제공합니다.

계정 카드의 설명·오류·가져오기 결과는 17 logical px, 이메일·플랜 사용량·처리 상태는 15 logical px를 사용하며, 색상과 글꼴·굵기는 기존 테마를 따릅니다. 로딩 상태는 진행 표시와 같은 문구를 화면과 접근성 레이블에 함께 제공합니다.

Layout: 기존 `AppPage`의 단일 `CustomScrollView` 안에 계정 카드를 배치합니다. 휴대폰은 하단 탭, 넓은 화면은 기존 NavigationRail을 유지합니다. 카드에는 별도 스크롤을 만들지 않고, 텍스트와 동작 버튼은 줄바꿈하여 가로 넘침을 막습니다.

## 프로필 주의사항

- `vless://` 형식의 `security=none`, `security=tls`, `security=reality` 링크를 지원합니다. `security`를 생략하면 `none`으로 처리하며, REALITY 사용 시에는 `pbk`가 필요합니다. 세부 옵션은 번들된 libXray 변환기로 검증합니다.
- 여러 VLESS 링크는 줄바꿈으로 입력할 수 있으며, 하나의 프로필 안에서 여러 노드로 변환됩니다.
- Clash YAML 구독의 `rules`와 `proxy-groups`는 규칙 모드에서 목적지별 노드 선택에 사용됩니다. VLESS 공유 링크 자체에는 목적지 규칙이 없으므로, 링크 목록에는 `DOMAIN-SUFFIX,example.com,노드 이름` 또는 `IP-CIDR,203.0.113.0/24,노드 이름` 같은 규칙을 줄마다 추가할 수 있습니다. `MATCH,DIRECT`처럼 기본 경로도 지정할 수 있습니다. 규칙을 입력하지 않으면 기본 노드를 사용합니다.
- RAW(TCP), XHTTP, gRPC와 일반/TLS WebSocket 전송을 지원합니다. Xray-core에서 REALITY+WebSocket은 지원하지 않습니다.
- 링크는 앱 내부 저장용 메타데이터로 보관되며 연결 직전에 Xray JSON으로 변환됩니다.
- 구독 요청은 `clash.meta` User-Agent로 Clash YAML을 우선 요청하고, 규칙 포함 YAML이 아니면 `ClashForAndroid`로 한 번 더 시도합니다. 제공자가 링크 목록만 반환하면 해당 VLESS 노드를 가져옵니다. 비지원 노드는 앱에 가져오지 않습니다.
- Android TUN은 앱이 생성하고 그 fd를 Xray에 전달합니다. 외부 소켓은 Android `protect()`로 VPN 루프에서 제외합니다.
- 구독 URL은 자격 증명을 포함할 수 있으므로 화면에는 호스트명만 표시하고 로그에는 URL을 남기지 않습니다.
- 새로 설치한 앱에는 기본 Direct 프로필이 생성되지 않습니다. VLESS 링크를 먼저 추가해 주세요.
- 이전 버전의 범용 YAML 프로필은 이 버전에서 연결할 수 없습니다. 해당 프로필을 삭제하고 VLESS 링크를 다시 추가해 주세요.

## 라이선스

앱 자체 라이선스는 별도로 정할 수 있습니다. 포함된 Xray-core 및 Android 브리지의 출처, 고정 버전, 라이선스 정보는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 확인하세요.
