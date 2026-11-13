/* Host-only fixture: reuse the existing raw-packet JNI test implementation.
 * Never compiled into an Android or engine library. */
#define Java_NativeDiagnosticsTest_openPair Java_NativeManagementTest_openPair
#define Java_NativeDiagnosticsTest_sendPacket Java_NativeManagementTest_sendPacket
#define Java_NativeDiagnosticsTest_receivePacket Java_NativeManagementTest_receivePacket
#define Java_NativeDiagnosticsTest_unboundSocket Java_NativeManagementTest_unboundSocket
#define Java_NativeDiagnosticsTest_closeFD Java_NativeManagementTest_closeFD
#include "../../mihomo-app/tests/packet_fixture.c"
