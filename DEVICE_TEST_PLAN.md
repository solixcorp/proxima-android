# Mihomo 기기 회귀 검증 계획

상태: **미실행**. 호스트 통과는 Android VPN, 피어 상호운용 또는 누수 방지의 증거가 아니다. 실행자는 기기 모델/ABI, Android 버전, APK 커밋 및 빌드, 서버·프로토콜 설정, 시간, 결과와 로그를 기록하고 각 항목을 별도 PASS/FAIL/BLOCKED로 남긴다. 비밀번호·키·구독 URL은 기록하지 않는다.

## 준비 및 실행

JDK 17로 `cd android && ./gradlew :app:assembleDebug` 후 테스트 기기에서 `adb install -r ../build/app/outputs/apk/debug/app-debug.apk`. VPN 권한을 승인한다. Mihomo는 유일한 엔진이므로 별도 엔진 선택은 없다. 테스트용 피어와 신뢰 가능한 DNS/관측 서버, Wi-Fi와 모바일 네트워크를 준비한다. 실행 전후 `adb logcat`과 `adb shell dumpsys connectivity`를 수집하되 개인정보를 제거한다. 기기에서 발생시키는 프로세스 종료 이외의 강제 종료는 하지 않는다.

에뮬레이터는 Android Studio AVD(x86_64 또는 arm64, Google APIs 이미지)를 생성하고 `adb devices`로 확인한 후 같은 APK를 설치한다. VPN 권한과 TCP/UDP/DNS 및 앱 재시작을 확인할 수 있지만, AVD의 가상 네트워크 전환은 실제 Wi-Fi↔셀룰러·절전·배터리 및 제조사 VPN 동작을 대체하지 않는다. 실제 기기 항목을 AVD 결과로 통과 처리하지 않는다.

## 시나리오 및 통과 기준 (16항목)

| # | 시나리오 | 예상 결과 / 통과 기준 |
|---|---|---|
| 1 | 지원 프로토콜별 실제 인증 연결: HTTP, SOCKS5, SS, SSR, VMess, VLESS, Trojan, Snell, Hysteria, Hysteria2, TUIC, WireGuard, SSH, AnyTLS, Mieru(TCP/UDP); direct/reject도 확인 | 각 설정의 TCP 요청 성공과 서버 측 경로 확인. reject는 차단. 미준비 피어는 BLOCKED, 성공으로 추정하지 않음 |
| 2 | VMess/VLESS/Trojan 전송 변형 및 REALITY | 지원 TCP/WS/gRPC와 해당 옵션의 인증 연결 성공; 미지원 조합은 명시적 오류 |
| 3 | UDP 및 Hysteria2/TUIC QUIC | UDP 왕복과 QUIC 요청 성공, 서버 관측 경로 일치; 종료 후 트래픽 중단 |
| 4 | Wi-Fi↔셀룰러 전환, 네트워크 손실/복구 | 보호 소켓이 VPN 루프에 빠지지 않고 상태가 정확; 실패 시 명시적 재연결로 회복, 누수 없음 |
| 5 | worker를 bind/Start/트래픽/Stop 중 각각 종료 | 연결 종료 상태로 전이, 엔진 폴백·자동 재시작 없음, VPN 표시와 FD 잔존 없음; 명시적 재연결은 새 PID |
| 6 | Binder 사망과 stop/reconnect 경합, 메인 프로세스 종료 | 오래된 콜백이 새 세션에 영향을 주지 않고 worker 종료 및 원본 TUN 정리; 재연결 성공 |
| 7 | 큰 설정의 사이드카·Binder FD 복제 | 64 KiB 초과 정상 설정이 온전히 적용되고 파일 제거; 손상/길이·해시 불일치는 시작 거부 |
| 8 | 노드 선택 및 모드 변경 | 선택 노드로 실제 트래픽, 재조립 후 선택 일치; 존재하지 않는 노드는 선택 초기화와 안내 |
| 9 | 구독 가져오기/갱신, 노드 삭제 및 잘못된 항목 | 원문 보존, 유효/건너뜀과 사유 표시; 삭제된 선택 초기화, 부적합 설정은 조용히 실행되지 않음 |
| 10 | redir-host DNS 및 누수 | 도메인 질의와 응답 성공, fake-IP 미사용, 설정한 경로 밖 DNS 질의가 캡처되지 않음 |
| 11 | 합성 DNS 172.19.0.2 UDP/TCP 53 | VPN 중 두 전송 모두 질의 성공, 외부로 해당 합성 주소 패킷 누출 없음; 주소 충돌 시 명시적 실패 기록 |
| 12 | Android always-on 및 VPN revoke | always-on 미지원/비활성 확인; revoke 후 서비스·worker 종료 및 VPN 표시 제거 |
| 13 | 앱 및 서비스 재시작, 타일/위젯 | 앱 cold/warm 상태 모두 타일/위젯으로 앱이 열리고 새 설정 조립·권한 승인 후 연결; 권한 거부와 중복 클릭 안전 처리; 설정 저장 중 요청은 완료 후 연결; 해제는 서비스에 직접 전달; 오래된 설정 재사용 없음 |
| 14 | 트래픽/연결 목록/지연, 대형 스냅샷 | 실제 트래픽과 카운터 변화·연결 표시 일치, 지연 성공/실패 정확, 큰 스냅샷도 안전히 전달 또는 명시 오류 |
| 15 | ABI 설치, IPv4/IPv6, MTU/LAN 예외 | 대상 ABI에서 JNI 로딩 성공, 설정된 IP 버전과 MTU·LAN 제외 경로가 기대대로 동작 |
| 16 | 반복 연결/종료 후 메모리·배터리 기본 관측 | 30회 반복 전후 메모리/FD와 30분 유휴 배터리를 기록해 지속 증가·비정상 소모가 없음을 확인; Mihomo 연결/종료 정상 |

실패/미실행은 출시 게이트 미충족이다. 상세 수명주기·소켓 감사는 `native/mihomo-engine/VERIFICATION.md`, `native/mihomo-engine/DIALERS.md`, 실행 계약은 `android/MIHOMO_RUNTIME.md`를 참조한다.

## 2026-11-14 호스트 회귀 점검

- Flutter 정적 분석: 통과. 전체 테스트 331개 통과, 명시적인 외부 캡처 환경이 필요한 테스트 4개 스킵.
- Android 호스트 테스트: 6개 실행 항목 통과. 설정 저장, 명시적 구독 마커, 외부 연결 요청 소비, 사이드카/FD 경계와 오래된 상태 이벤트·서비스 세대 경합을 검증.
- 네이티브 Go vet/race/JNI 테스트와 네 ABI 라이브러리 빌드: 통과.
- 네 ABI Mihomo 라이브러리의 ELF `PT_LOAD` 정렬을 직접 확인: 모두 16 KiB. 최종 debug/release APK의 `zipalign -c -P 16 4`도 통과. 실제 16 KiB 페이지 기기의 설치·실행은 별도 검증 항목.
- 실제 로컬 HTTP 서버로 성공/오류/크기 초과/본문 정지/느린 전송/리디렉션 본문 취소 및 IP 조회의 세션 변경 후 결과 폐기를 검증. 실제 구독 서버 인증과 Android TUN 경로는 별도 기기 검증 대상.
- GeoJS 실제 HTTPS 응답은 유효한 IPv4를 포함한 JSON 계약과 일치함을 확인. 로컬 개발 환경에서의 확인으로, VPN 서버의 출구 IP를 검증한 결과는 아님.
- 최종 `:app:assembleDebug :app:assembleRelease --max-workers=2` 통과. Debug APK 403,205,667 bytes, 무서명 release APK 220,681,880 bytes. 두 APK 모두 Mihomo ABI `arm64-v8a`, `armeabi-v7a`, `x86_64`를 포함하며 release는 400 MiB 제한 이내. Debug APK의 v2 서명 검증 통과. 실제 배포 keystore로 서명한 최종 변경본은 아직 GitHub에서 빌드하지 않음.
- `adb devices -l` 결과 연결 기기 없음. 기존 AVD 데이터와 스냅샷을 사용하지 않는 격리 Pixel_10_Pro(arm64-v8a, Android 37.1 이미지)를 시작했으나 5분 넘게 `offline`이어서 설치·실행은 BLOCKED. 실행한 에뮬레이터만 종료함. 위 16개 기기 시나리오는 여전히 미실행이며 호스트 결과로 통과 처리하지 않음.

## 릴리즈 서명

CI는 `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`를 사용하고 APK 서명자가 지정 keystore 인증서와 일치하는지 발행 전에 확인한다. 로컬에서 서명 정보 없이 만드는 release APK는 무서명이다. 로컬 서명 시 `KEYSTORE_PATH`로 keystore 경로를 지정할 수 있다.

기존 workflow는 debug 키로 릴리즈에 서명했다. 새 릴리즈 키가 기존 설치 APK의 키와 다르면 Android에서 덮어쓰기 업데이트를 거부한다. 기존 설치본을 배포 키로 변환할 수는 없으므로 배포 전 기존 인증서를 확인하고 설치 이전 절차를 결정해야 한다. 앱 삭제는 로컬 프로필도 지우므로 필요한 프로필을 먼저 내보낸다.
