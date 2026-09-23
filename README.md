# Proxima for Android

Proxima는 VLESS + REALITY 링크에 집중한 Android VPN 클라이언트입니다. 사용자는 공유 링크나 HTTPS 구독을 추가하고, 앱은 이를 Xray JSON 구성으로 변환해 Android `VpnService`의 TUN 인터페이스에서 기기 트래픽을 처리합니다.

복잡한 범용 프록시 설정 편집기를 목표로 하지 않습니다. 대신 VLESS + REALITY 프로필 추가, 연결 제어, 노드 선택, 트래픽 확인, 네트워크 진단처럼 Android에서 실제로 자주 쓰는 흐름을 앱 안에서 단순하게 다루는 것을 목표로 합니다.

## 제공 기능

- VLESS + REALITY 공유 링크 추가, 편집, 검증
- VLESS + REALITY 링크 목록을 제공하는 HTTPS 구독 가져오기
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

## 프로필 주의사항

- `vless://` 형식이며 `security=reality`, REALITY `pbk`가 포함된 링크를 사용합니다. 세부 옵션은 번들된 libXray 변환기로 검증합니다.
- 여러 VLESS + REALITY 링크는 줄바꿈으로 입력할 수 있으며, 하나의 프로필 안에서 여러 노드로 변환됩니다.
- REALITY와 호환되는 RAW(TCP), XHTTP, gRPC 전송을 지원합니다. Xray-core에서 REALITY+WebSocket은 지원하지 않습니다.
- 링크는 앱 내부 저장용 메타데이터로 보관되며 연결 직전에 Xray JSON으로 변환됩니다.
- 구독 요청은 VLESS URI 목록을 받는 클라이언트 User-Agent로 전송합니다. 비지원 노드는 앱에 가져오지 않습니다.
- Android TUN은 앱이 생성하고 그 fd를 Xray에 전달합니다. 외부 소켓은 Android `protect()`로 VPN 루프에서 제외합니다.
- 구독 URL은 자격 증명을 포함할 수 있으므로 화면에는 호스트명만 표시하고 로그에는 URL을 남기지 않습니다.
- 새로 설치한 앱에는 기본 Direct 프로필이 생성되지 않습니다. VLESS + REALITY 링크를 먼저 추가해 주세요.
- 이전 버전의 범용 YAML 프로필은 이 버전에서 연결할 수 없습니다. 해당 프로필을 삭제하고 VLESS + REALITY 링크를 다시 추가해 주세요.

## 라이선스

앱 자체 라이선스는 별도로 정할 수 있습니다. 포함된 Xray-core 및 Android 브리지의 출처, 고정 버전, 라이선스 정보는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 확인하세요.
