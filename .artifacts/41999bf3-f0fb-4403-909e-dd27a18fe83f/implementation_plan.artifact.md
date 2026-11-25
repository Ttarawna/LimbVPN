# Implementation Plan: LimbVPN v1.0

## Goal Description
This project aims to develop a minimalist, fault-tolerant, and secure VPN client for LimbVPN, based on the Mieru protocol. The goal is to provide comprehensive VPN functionality across Android, iOS, Windows, macOS, and Linux, focusing on advanced features like intelligent traffic splitting, automatic RU application detection, and robust metadata obfuscation to hide user location and activity.

## User Review Required
1.  **Kernel-Level Networking & VPN Implementation**: The implementation of traffic splitting (Split Tunneling) and routing requires deep interaction with the operating system's network stack (`VpnService` on Android, Network Extensions/Routing APIs on iOS/macOS/Linux). This is the most technically challenging part and requires careful consideration of stability and performance.
2.  **Metadata Spoofing Implementation**: Faking GPS and modifying network headers (spoofing to NL) requires system-level permissions and potentially root access or specific OS-level hooks. The viability of these features across all target platforms (especially Windows/Linux) needs careful architectural review.
3.  **Mieru Protocol Implementation**: Since Mieru is likely a custom or specialized protocol, we must confirm if there are existing libraries or if the entire client stack (encryption, packet handling) must be implemented natively.

## Open Questions
*   **Mieru Protocol Specification**: Do we have the source code or full RFC for the Mieru protocol to begin implementation, or will it need to be derived from existing examples?
*   **Platform Abstraction**: Given the diverse OS targets (Android, iOS, Windows, macOS, Linux), should we aim for a highly abstracted Dart layer (Flutter) with extensive Platform Channels, or should we implement core Mieru logic in a shared native layer (e.g., using a common C/C++ core) and wrap it across all platforms?
*   **Traffic Detection Logic**: What is the primary heuristic or database we should use to reliably identify "RU applications" and their traffic? (e.g., application package name list, IP destination ranges).

## Proposed Changes

### 🛠️ Core Architecture & Foundation (Initial Phase)
*   **[NEW] `lib/core/vpn_service.dart`**: Dart interface for the VPN service.
*   **[NEW] `lib/core/native_interface.dart`**: Platform channel definitions for accessing OS-specific VPN APIs (Android `VpnService`).
*   **[NEW] `lib/core/mieru_client.dart`**: Placeholder for the Mieru protocol stack implementation.
*   **[MODIFY] `pubspec.yaml`**: Add necessary dependencies for native interop, networking, and OS-specific features.

### 📱 Android Implementation (Platform Specific)
*   **[NEW] `android/app/vpn_service/LimbVpnService.kt`**: Native implementation of `VpnService` to handle packet interception and routing.
*   **[NEW] `android/core/traffic_router.kt`**: Logic for split tunneling, identifying RU apps, and routing traffic to/from the Mieru tunnel.
*   **[NEW] `android/core/metadata_faker.kt`**: Native component for Fake GPS and header manipulation.

### 📱 iOS/macOS/Windows/Linux Implementation
*   **[NEW] `ios/LimbVpnService.swift`**: Native implementation using `NEPacketTunnelProvider` or equivalent for routing.
*   **[NEW] Platform-specific routing and metadata components** for each OS, following the pattern established in the Android implementation.

### 🛡️ Security and Privacy Features
*   **[MODIFY] `lib/model/app_list.dart`**: Data model/service for maintaining and checking RU application lists.
*   **[NEW] `lib/security/fingerprint_service.dart`**: Logic to minimize telemetry and metadata leaks (e.g., randomizing connection IDs).

## Verification Plan

### Automated Tests
*   **Unit Tests**: Implement unit tests for the Mieru protocol logic, routing rules, and app identification logic in Dart and native modules.
*   **Integration Tests**: Run end-to-end tests on a dedicated Android emulator/device to confirm split-tunnel traffic routing (e.g., checking if `google.ru` is direct while `youtube.com` is tunneled).
*   **Security/Privacy Checks**: Use tools to confirm the absence of detectable metadata fingerprints (fingerprinting checks).

### Manual Verification
*   **Device Testing**: Deploy the app to physical devices on all target platforms and manually verify the RU direct vs. VPN tunnel status for various test applications.
*   **Network Inspection**: Use network analyzers (Wireshark, Fiddler) to confirm that outgoing traffic headers are spoofed to the Netherlands (NL) as required.
*   **Location Spoofing**: Verify that third-party location services detect the Fake GPS coordinates correctly.

## Next Steps
1.  Finalize the implementation plan with the user.
2.  Implement the basic Flutter/Dart structure and platform communication channels.
3.  Develop the Android `VpnService` implementation, as this is the foundational piece.