// Sources/HeadphoneDetector.swift
// Aperture — Default output device transport type detection.
//
// Single-purpose module: reads CoreAudio's default output device transport type
// to determine if headphones are connected. Used by RecorderView to offer the
// headphone-aware nudge toward Mic + System mode.
//
// Fix: kAudioDeviceTransportTypeHeadphones does not exist in the CoreAudio SDK.
// Per ADR-031 approach, we use kAudioDeviceTransportTypeBuiltIn + a secondary
// kAudioDevicePropertyDataSource check for wired 3.5mm headphones ('hdpn').

import CoreAudio
import Foundation

enum HeadphoneDetector {
    /// Returns true if the default output device's transport type indicates
    /// headphones: Bluetooth, BluetoothLE, USB (unambiguous), or built-in
    /// with the headphones data source active (3.5mm wired).
    static func headphonesConnected() -> Bool {
        var deviceID = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard err == noErr else { return false }

        var transportType: UInt32 = 0
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let tErr = AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transportType
        )
        guard tErr == noErr else { return false }

        // Bluetooth and USB: strongly correlated with headphone/headset transports.
        // USB intentionally includes USB headsets and headphones. Known limitation:
        // USB audio interfaces (studio interfaces, capture cards) are a false positive
        // and would also trigger the headphone nudge banner. This is inherited from the
        // original implementation; a future follow-up could add a USB data-source check
        // similar to the built-in check below to filter audio interfaces out.
        let wirelessOrUSB: Set<UInt32> = [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeUSB,
        ]
        if wirelessOrUSB.contains(transportType) { return true }

        // Built-in transport: could be speakers OR 3.5mm headphones.
        // Disambiguate via data source.
        if transportType == kAudioDeviceTransportTypeBuiltIn {
            return isBuiltInOutputHeadphones(deviceID: deviceID)
        }

        return false
    }

    /// Check kAudioDevicePropertyDataSource on the output scope.
    /// 'hdpn' (0x6864706E) = headphones jack is active.
    static func isBuiltInOutputHeadphones(deviceID: AudioObjectID) -> Bool {
        var dataSource: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &dataSource)
        guard err == noErr else { return false }
        // 'hdpn' (0x6864706E) — headphones data source, as defined by CoreAudio
        // (not kIOAudioOutputPortSubTypeHeadphones, which is an IOKit symbol)
        return dataSource == 0x6864706E
    }
}
