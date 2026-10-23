import SwiftUI

extension View {
    public func ohLinkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    public func ohAccessoryBarButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.accessoryBar)
        #else
        buttonStyle(.borderless)
        #endif
    }

    public func ohCheckboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    public func ohRadioGroupPickerStyle() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.inline)
        #endif
    }

    public func ohBorderlessMenuStyle() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
}
