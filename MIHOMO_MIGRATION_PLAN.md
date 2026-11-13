# Mihomo 전환 계획

## 목표와 원칙

libXray를 최종 제거하고 mihomo v1.19.33으로 전환한다. Mihomo가 지원하는 모든 프로토콜을 대상으로 Clash YAML을 패스스루하고 제네릭 검증한다. 앱이 프로토콜별로 변환하는 방식을 확장하지 않는다. 기존 구독 호환은 별도 검증한다.

## 확정 설계

- `:mihomo` 별도 프로세스와 JNI 세션을 유지한다. 시작 오류는 호출자에 반환하고 획득한 자원을 롤백한다. 종료는 업스트림 3계약 패치를 통한 joined shutdown으로 완료를 기다린다.
- Xray 기본값의 듀얼 엔진 플래그로 점진적으로 전환한다. Phase 0에서는 선택을 저장만 하며 실제 실행은 Xray다.
- 트래픽, 연결 목록·부하 및 지연 측정 관제 데이터는 external-controller HTTP 대신 JNI 콜백으로 전달한다.
- DNS는 redir-host를 우선 사용하고 fake-ip는 이후 옵션으로 검토한다. YAML 조립은 Dart에서 수행한다.

## 미결정

- GPL-3.0 배포 정책과 소스 제공 방식은 사용자 확정을 기다린다. 이번 단계에서 제3자 고지를 추가하되 배포 승인을 의미하지 않는다.

## 단계 및 완료 조건

Phase 3.3 구현: Mihomo 저장·실행 경로를 Dart 조립으로 전환했다.
구독 YAML 원문과 admission 요약을 분리 저장하고, 시작/재시작마다 최종 재검증한
설정을 64KiB 청크 → 앱 전용 일회용 사이드카(최대 8MiB) → 기존 Binder 설정 FD로
전달한다. 원문 SHA-256·설정 지문 및 MTU/mips/IPv6 일치 실패는 시작을 거부한다.
Kotlin 임시 단일 VLESS 조립은 제거했으며 Xray/Go/native 동작은 변경하지 않았다.
선택 노드 소멸 시 영속 선택 무효화·첫 노드 UI·재선택 안내와 가져오기 건너뜀 요약을
연결했다. 기존 레거시 파일/라우팅 메타데이터는 재저장·편집·내보내기 시 보존하고
실행 때 Dart에서 읽는다. 복합/GEO 규칙은 안전한 변환 대신 갱신을 요구한다.

기기 완료 판정은 보류: 실제 Binder/PFD·프로세스 사망·IPv4/IPv6/DNS/UDP/네트워크
전환 검증이 필요하다. Mihomo 타일/위젯의 headless Dart 준비와 JNI provider 관제는
미지원이며, 사이드카 없는 시작은 앱에서 재연결하도록 명시적으로 거부한다.
실행 계약과 이행 다이어그램은 `android/MIHOMO_RUNTIME.md`를 따른다.

2026-11-13 호스트 게이트: Flutter 전체 304 통과/캡처 전용 4 건너뜀,
Kotlin discovery 4/4(경계 26·실행 10 + 설정·소스 연결 검증), JDK 21
`:app:assembleDebug` 성공(215 tasks), 루트 native 7개 모듈 게이트 통과.

| 단계 | 내용 | 완료 조건 |
| --- | --- | --- |
| 0 | 엔진 선택 저장, 계획과 라이선스 고지 | 기본 Xray, 설정 왕복·기본값 테스트 통과, 실행 경로 불변 |
| 1 | 세션 수명주기 및 프로세스 경계 | 시작 실패 롤백과 3계약 joined shutdown, 프로세스 종료·재시작 검증 |
| 2 | TUN, 네트워크·DNS 연결 | FD 소유권, 보호 소켓, redir-host 및 IPv4/IPv6 기기 통신 검증 |
| 3 | Dart YAML 조립과 프로필 입력 | Clash YAML 패스스루, 제네릭 오류 처리와 구독 호환 검증 |
| 4 | JNI 관제 및 앱 연결 | 트래픽·연결 목록·지연 콜백과 UI 수명주기 검증 |
| 5 | 듀얼 엔진 실제 전환 | 선택된 엔진 기동·중지, 오류 복구 및 기존 Xray 회귀 검증 |
| 6 | Xray 제거 및 출시 준비 | GPL 정책 확정, 기기 검증 완료, Xray 코드·의존성 제거 및 배포 검토 |

### Phase 5 CI/릴리스 (워크플로 반영, 실제 CI 검증 대기)

```text
브랜치 push / PR → Flutter 분석·테스트 → Kotlin 호스트 테스트
                → native 전체 race/JNI 테스트 → debug assemble (엔진 4 ABI)
v* 태그 → 동일 호스트 게이트 → release 엔진 4 ABI → 서명 APK 빌드
       → APK 엔진 3 ABI 및 크기 검증 → GitHub Release
```

두 경로 모두 Flutter 3.47.5, JDK 17, Go 1.27.1 및 NDK 28.2.13676358을
사용한다. 앱의 Java 바이트코드 목표는 17이며 로컬 JDK 17 debug assemble이
성공하여 기존 릴리스 JDK를 유지한다. 엔진 스크립트는 NDK API 23 도구를
직접 사용하며 `-mod=readonly`로 빌드한다. 전체 7개 native 모듈의 race·JNI
게이트는 경계 회귀를 놓치지 않도록 릴리스에서도 축소하지 않는다. CI 시간은
첫 실행 후 확인한다. 테스트와 Gradle은 공유 스테이징 충돌을 피하도록 직렬이다.
setup-go는 모든 native go.sum을 키로 모듈 및 컴파일 캐시를 재사용한다. 경로가
포함된 임시 overlay와 Gradle 입력·출력 정합성 문제 때문에 native build 디렉터리
자체는 캐시하지 않는다. `**/build/`는 Git에서 제외되며 CI에서 APK 등 별도
아티팩트 업로드는 하지 않고 기존 태그 릴리스만 배포한다.

릴리스 엔진 빌드는 x86을 포함한 4 ABI지만 Flutter 패키징은 x86을 제외한다.
APK 검사에서 `arm64-v8a`, `armeabi-v7a`, `x86_64`의 엔진 라이브러리만 각각
하나씩 요구한다. 크기 상한은 400 MiB (419,430,400 bytes): 기존 로컬 엔진
미포함 universal release 181,042,118 bytes (약 173 MiB)에 엔진 3개 ABI의
미압축 합 약 187 MiB를 보수적으로 더하고 약 40 MiB 여유를 둔 임시 값이다.
서명·strip/압축·의존성에 따라 달라지므로 첫 CI 릴리스 실측 후 재조정한다.
이는 기기 동작 또는 GPL 배포 승인을 의미하지 않는다.

## 리스크

| 위험 | 대응 |
| --- | --- |
| 합성 DNS 172.19.0.2 충돌 또는 누수 | 라우팅·주소 충돌과 실제 DNS 경로를 기기에서 검증 |
| dialer 훅 우회 | 모든 아웃바운드의 protect/bind 경로를 감사하고 누수 테스트 |
| executor.Shutdown 미조인 | 업스트림 3계약 패치 및 반복 종료·재시작 테스트 |
| mips 스택 성숙도 | 지원 ABI 및 스택별 검증, 미검증 조합 명시 |
| APK 크기 | ABI별 크기 측정과 배포 방식 검토 |
| QUIC UDP 경로 | UDP 및 QUIC 실기기 연결·네트워크 전환 검증 |
| 비표준 구독 YAML | 공급자별 실제 사례와 실패 메시지 검증, 임의 변환 지양 |

## 검증 게이트

각 Phase 완료마다 `flutter analyze`, `flutter test`와 각 `native/*/build.sh test`가 모두 통과해야 한다. 호스트 테스트만으로 Android VPN 동작을 보증하지 않는다. 최종 Xray 제거 전에 실제 기기에서 연결·DNS·UDP·네트워크 전환·종료 및 복구를 검증해야 한다.

기기·에뮬레이터 실행 절차와 시나리오별 판정 기준은 [DEVICE_TEST_PLAN.md](DEVICE_TEST_PLAN.md)를 따른다. 기기 검증은 아직 실행되지 않았다.
