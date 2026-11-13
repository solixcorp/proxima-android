# Mihomo 기기 회귀 검증 계획

상태: **미실행**. 호스트 통과는 Android VPN, 피어 상호운용 또는 누수 방지의 증거가 아니다. 실행자는 기기 모델/ABI, Android 버전, APK 커밋 및 빌드, 서버·프로토콜 설정, 시간, 결과와 로그를 기록하고 각 항목을 별도 PASS/FAIL/BLOCKED로 남긴다. 비밀번호·키·구독 URL은 기록하지 않는다.

## 준비 및 실행

JDK 21로 `cd android && ./gradlew :app:assembleDebug` 후 테스트 기기에서 `adb install -r app/build/outputs/apk/debug/app-debug.apk`. VPN 권한을 승인하고 앱 설정에서 Mihomo를 명시적으로 선택한다. 테스트용 피어와 신뢰 가능한 DNS/관측 서버, Wi-Fi와 모바일 네트워크를 준비한다. 실행 전후 `adb logcat`과 `adb shell dumpsys connectivity`를 수집하되 개인정보를 제거한다. 기기에서 발생시키는 프로세스 종료 이외의 강제 종료는 하지 않는다.

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
| 13 | 앱 및 서비스 재시작, 타일/위젯 | 정상 앱 재연결은 새 설정; 사이드카 없는 Mihomo 타일/위젯 시작은 안내 오류, 오래된 설정 재사용 없음 |
| 14 | 트래픽/연결 목록/지연, 대형 스냅샷 | 실제 트래픽과 카운터 변화·연결 표시 일치, 지연 성공/실패 정확, 큰 스냅샷도 안전히 전달 또는 명시 오류 |
| 15 | ABI 설치, IPv4/IPv6, MTU/LAN 예외 | 대상 ABI에서 JNI 로딩 성공, 설정된 IP 버전과 MTU·LAN 제외 경로가 기대대로 동작 |
| 16 | 반복 연결/종료 후 메모리·배터리 기본 관측 | 30회 반복 전후 메모리/FD와 30분 유휴 배터리를 기록해 지속 증가·비정상 소모가 없음을 확인; Mihomo 연결/종료 정상 |

실패/미실행은 출시 게이트 미충족이다. 상세 수명주기·소켓 감사는 `native/mihomo-engine/VERIFICATION.md`, `native/mihomo-engine/DIALERS.md`, 실행 계약은 `android/MIHOMO_RUNTIME.md`를 참조한다.
