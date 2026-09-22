# Proxima for Android

Proxima는 VLESS + REALITY 링크에 집중한 Android VPN 클라이언트입니다. 사용자는 공유 링크나 HTTPS 구독을 추가하고, 앱은 이를 Android `VpnService`에서 실행 가능한 Mihomo 설정으로 변환해 기기 트래픽을 TUN 인터페이스로 처리합니다.

복잡한 범용 Mihomo YAML 편집기를 목표로 하지 않습니다. 대신 VLESS + REALITY 프로필 추가, 연결 제어, 정책 그룹 전환, 트래픽 확인, 네트워크 진단처럼 Android에서 실제로 자주 쓰는 흐름을 앱 안에서 단순하게 다루는 것을 목표로 합니다.

## 제공 기능

- VLESS + REALITY 공유 링크 추가, 편집, 검증
- VLESS + REALITY 링크 목록을 제공하는 HTTPS 구독 가져오기
- VPN 연결 전에도 가능한 전역 모드의 단일 노드 선택과 규칙 기반 라우팅
- 구독 응답의 `subscription-userinfo` 기반 사용량·남은 트래픽·만료일 및 플랜명 표시
- 링크를 앱 내부 실행용 Mihomo 설정으로 자동 변환
- Android VPN 권한 요청과 포그라운드 `VpnService` 연결 제어
- Android 빠른 설정 타일에서 최근 프로필 즉시 연결·해제
- Rule, Global, Direct 작동 모드 전환
- 정책 그룹과 프록시 노드 조회, 선택, 지연 시간 측정
- 활성 연결의 목적지, 적용 규칙, 프록시 체인, 트래픽 조회 및 종료
- Proxy Provider, Rule Provider 조회와 업데이트
- 실시간 업로드·다운로드 속도와 누적 트래픽 표시
- DNS 조회, 외부 IP 조회, 네트워크 진단 도구
- 로컬 VLESS 링크 파일 가져오기·내보내기
- System, gVisor, Mixed 네트워크 스택과 IPv6/MTU 설정
- 앱 샌드박스 프로필 저장과 Android 백업 차단
- 휴대폰과 태블릿/넓은 화면에 맞춘 Material 3 UI

## 구조

```text
lib/                         Flutter UI와 상태 관리
android/app/src/main/kotlin/ MethodChannel, 프로필 저장소, VpnService
android/app/libs/            고정 버전 Android mihomo AAR
```

Flutter 계층은 화면, 상태 관리, 프로필 입력 검증을 담당합니다. Android 계층은 프로필 저장소, MethodChannel, `VpnService`, 알림, 빠른 설정 타일을 담당합니다. 실제 프록시 코어 실행은 `libmihomo-android` AAR을 통해 연결되며, Android VPN 환경에 맞게 TUN fd와 소켓 `protect()` 처리를 수행합니다.

## 빌드

Flutter 3.47+, JDK 17, Android SDK가 준비된 환경에서 다음을 실행합니다. 프로젝트의 Gradle wrapper는 8.14.3으로 고정되어 있습니다. Flutter가 JDK 25처럼 호환되지 않는 JDK를 선택한다면 `flutter config --jdk-dir=/path/to/jdk17`로 JDK 17을 지정하세요.

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

포함된 `libmihomo-android-v0.3.1.aar`의 SHA-256은 `cd3dfb461d2ae46666260b38048b77a272aa58cae33db22a374b57308bab69ef`입니다. AAR은 arm64-v8a, armeabi-v7a, x86_64를 포함합니다.

현재 `release` 빌드도 개발 편의를 위해 debug 키로 서명됩니다. 실제 배포 전에는 Play App Signing 또는 별도 release keystore로 교체해야 합니다.

## 프로필 주의사항

- `vless://` 형식이며 `security=reality`, `encryption=none`, REALITY `pbk`가 포함된 링크만 사용할 수 있습니다.
- 여러 VLESS + REALITY 링크는 줄바꿈으로 입력할 수 있으며, 하나의 프로필 안에서 여러 노드로 변환됩니다.
- TCP(raw), WebSocket, gRPC 전송 방식을 지원합니다. WebSocket에는 `path`, gRPC에는 `serviceName`이 필요합니다.
- 링크는 앱 내부에서 실행용 Mihomo YAML로 변환되어 저장됩니다. 원본 링크도 앱 샌드박스의 메타데이터에 함께 보관되므로 편집·내보내기 시 다시 사용할 수 있습니다.
- 구독 요청은 VLESS URI 목록을 받는 클라이언트 User-Agent로 전송합니다. Mihomo 전용 구독에 섞일 수 있는 mieru 같은 비지원 노드는 앱에 가져오지 않습니다.
- Android TUN은 앱이 생성하므로 저장된 `tun.enable` 값은 실행 사본에서 항상 `false`로 정규화됩니다.
- Android 앱 권한으로는 프로세스 소켓 테이블을 읽을 수 없으므로 `find-process-mode: off`로 프로세스 기반 Mihomo 매칭을 사용하지 않습니다.
- 구독 URL은 자격 증명을 포함할 수 있으므로 화면에는 호스트명만 표시하고 로그에는 URL을 남기지 않습니다.
- 새로 설치한 앱에는 기본 Direct 프로필이 생성되지 않습니다. VLESS + REALITY 링크를 먼저 추가해 주세요.
- 이전 버전의 범용 Mihomo YAML 프로필은 이 버전에서 연결할 수 없습니다. 해당 프로필을 삭제하고 VLESS + REALITY 링크를 다시 추가해 주세요.

## 라이선스

Proxima는 GPL-3.0으로 배포됩니다. 포함된 Mihomo 계열 코어와 Android 브리지의 출처, 고정 버전, 라이선스 정보는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 확인하세요.
