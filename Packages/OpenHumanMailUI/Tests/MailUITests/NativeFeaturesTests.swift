import Foundation
import Testing
@testable import MailUI

@MainActor
@Suite(.serialized) struct NativeFeaturesTests {
    @Test func theSystemFlagsFollowTheRunningOS() {
        if #available(macOS 27, iOS 27, *) {
            #expect(NativeFeatures.system == .macOS27)
        } else {
            #expect(NativeFeatures.system == .macOS26)
        }
        #expect(NativeFeatures.override == nil)
        #expect(NativeFeatures.current == NativeFeatures.system)
    }

    @Test func theFallbacksAreAllOff() {
        #expect(!NativeFeatures.macOS26.splitPickerTabs && !NativeFeatures.macOS26.menuItemImages)
        #expect(NativeFeatures.macOS27.splitPickerTabs && NativeFeatures.macOS27.menuItemImages)
    }

    @Test func anOverrideTurnsFeaturesOffForItsScopeOnly() {
        let inside = NativeFeatures.withOverride(.macOS26) { NativeFeatures.current }
        #expect(inside == .macOS26)
        #expect(NativeFeatures.override == nil && NativeFeatures.current == NativeFeatures.system)
    }

    @Test func anAsyncOverrideIsRestoredAfterTheBody() async throws {
        let inside = try await NativeFeatures.withOverride(.macOS26) { @MainActor () async throws -> NativeFeatures in
            NativeFeatures.current
        }
        #expect(inside == .macOS26 && NativeFeatures.override == nil)
    }

    @Test func anOverrideCannotEnableWhatTheSystemLacks() {
        #expect(NativeFeatures.macOS27.limited(to: .macOS26) == .macOS26)
        #expect(NativeFeatures.macOS26.limited(to: .macOS27) == .macOS26)
        let mixed = NativeFeatures(splitPickerTabs: true, menuItemImages: false)
        #expect(mixed.limited(to: .macOS27) == mixed)
        let forced = NativeFeatures.withOverride(.macOS27) { NativeFeatures.current }
        #expect(forced == NativeFeatures.system)
    }

    @Test func theLaunchArgumentNamesAVersion() {
        #expect(NativeFeatures.named("26") == .macOS26 && NativeFeatures.named(" macOS26 ") == .macOS26)
        #expect(NativeFeatures.named("27") == .macOS27)
        #expect(NativeFeatures.named("25") == nil && NativeFeatures.named(nil) == nil && NativeFeatures.named("") == nil)
        #expect(NativeFeatures.macOS26.description == "macOS 26")
    }

    @Test func theSystemListSelectionIsOnByDefaultOnEverySystem() {
        #expect(NativeFeatures.macOS26.systemListSelection && NativeFeatures.macOS27.systemListSelection)
        #expect(NativeFeatures.system.systemListSelection && NativeFeatures.current.systemListSelection)
        #expect(NativeFeatures(splitPickerTabs: true, menuItemImages: true) == .macOS27)
        #expect(NativeSelectionStyle.current == .system)
    }

    @Test func theTintedSelectionIsAnOverrideForItsScopeOnly() {
        let tinted = NativeFeatures.system.withTintedListSelection
        #expect(!tinted.systemListSelection)
        #expect(tinted.splitPickerTabs == NativeFeatures.system.splitPickerTabs)
        #expect(tinted.menuItemImages == NativeFeatures.system.menuItemImages)
        let inside = NativeFeatures.withOverride(tinted) { (NativeFeatures.current, NativeSelectionStyle.current) }
        #expect(inside.0 == tinted && inside.1 == .tint)
        #expect(NativeFeatures.current.systemListSelection && NativeSelectionStyle.current == .system)
        #expect(tinted.description.hasSuffix("systemListSelection=false"))
        #expect(NativeFeatures.macOS27.limited(to: tinted) == tinted, "an override cannot turn the system selection back on")
    }

    @Test func theListSelectionLaunchArgumentNamesALook() {
        #expect(NativeFeatures.listSelection(named: "tint") == false && NativeFeatures.listSelection(named: " Tint ") == false)
        #expect(NativeFeatures.listSelection(named: "0") == false && NativeFeatures.listSelection(named: "NO") == false)
        #expect(NativeFeatures.listSelection(named: "system") == true && NativeFeatures.listSelection(named: "1") == true)
        #expect(NativeFeatures.listSelection(named: nil) == nil && NativeFeatures.listSelection(named: "accent") == nil)

        #expect(NativeFeatures.launchOverride(features: nil, listSelection: nil) == nil)
        #expect(NativeFeatures.launchOverride(features: nil, listSelection: "system") == nil)
        #expect(NativeFeatures.launchOverride(features: "26", listSelection: nil) == .macOS26)
        #expect(NativeFeatures.launchOverride(features: "26", listSelection: "tint") == NativeFeatures.macOS26.withTintedListSelection)
        #expect(NativeFeatures.launchOverride(features: nil, listSelection: "tint") == NativeFeatures.system.withTintedListSelection)
    }

    @Test func theSelectionPlateFollowsTheStyleAndTheWindowsKeyState() {
        typealias Look = NativeSelectionPlate.Look
        #expect(Look.of(isSelected: false, isEmphasized: true, style: .system) == .hidden)
        #expect(Look.of(isSelected: false, isEmphasized: true, style: .tint) == .hidden)
        #expect(Look.of(isSelected: true, isEmphasized: true, style: .system) == .accent)
        #expect(Look.of(isSelected: true, isEmphasized: false, style: .system) == .unemphasized)
        #expect(Look.of(isSelected: true, isEmphasized: true, style: .tint) == .tint)
        #expect(Look.of(isSelected: true, isEmphasized: false, style: .tint) == .inactiveTint)
        #expect([Look.hidden, .accent, .unemphasized, .tint, .inactiveTint].filter(\.whiteText) == [.accent],
                "text turns white only on the full accent fill")
        let plate = NativeSelectionPlate(isSelected: true)
        #expect(plate.look == .accent)
        #expect(NativeFeatures.withOverride(NativeFeatures.system.withTintedListSelection) { plate.look } == .tint)
        #expect(NativeSelectionPlate(isSelected: true, isEmphasized: false, style: .tint).look == .inactiveTint)
    }
}
