//
//  SidebarView.swift
//  kero
//

import AppKit
import SwiftUI

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    let bottomBarHeight: CGFloat
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("leftSidebarWidth") private var width: Double = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header-height strip housing the traffic-light buttons and the
            // control for collapsing this sidebar.
            HStack(spacing: 0) {
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                if manager.isFPSCounterVisible {
                    FPSBadge()
                        .padding(.trailing, 8)
                }
                ChromeIconButton(
                    systemImage: "sidebar.left",
                    tooltip: "Toggle Left Sidebar (⌘B)"
                ) {
                    manager.toggleLeftSidebar()
                }
            }
            .padding(.trailing, 8)
            .frame(height: 38)

            SidebarProjectList(
                manager: manager,
                fontSize: settings.sidebarFontSize
            )

            HStack(spacing: 2) {
                SidebarFooterButton(
                    systemImage: "plus",
                    tooltip: "New Project (⌘N)"
                ) { manager.newProject() }
                Spacer()
                SidebarFooterButton(
                    systemImage: "exclamationmark.bubble",
                    tooltip: "Send Feedback",
                    tooltipAlignment: .trailing
                ) {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/egoist/kero/issues/new")!
                    )
                }
                SidebarFooterButton(
                    systemImage: "gearshape",
                    tooltip: "Settings (⌘,)",
                    tooltipAlignment: .trailing
                ) { openSettings() }
            }
            .padding(.horizontal, 8)
            .frame(height: bottomBarHeight)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(height: 1)
            }
        }
        .frame(width: width)
        .background {
            // Kero's built-in Default themes keep the native translucent
            // sidebar material; every other theme — including the GitHub
            // originals they're based on — paints its flat sidebar shade so
            // the strip follows the palette.
            if Theme.isDefault(dark: colorScheme == .dark) {
                VisualEffectView(material: .sidebar)
            } else {
                Color(nsColor: Theme.sidebar)
            }
        }
        // Hairline between sidebar and content: themes fill both with the
        // same background, so the boundary needs its own line. The built-in
        // Defaults keep their material fill, whose contrast already draws
        // the edge.
        .overlay(alignment: .trailing) {
            if !Theme.isDefault(dark: colorScheme == .dark) {
                Rectangle()
                    .fill(Color(nsColor: Theme.divider))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            SidebarResizeHandle(
                edge: .trailing,
                width: $width,
                range: 160...400,
                defaultWidth: 220
            )
        }
    }
}

struct ChromeIconButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    var font: Font = .system(size: 12, weight: .medium)
    var iconSize: CGFloat = 16
    var tooltipEdge: TooltipEdge = .below
    var tooltipAlignment: HorizontalAlignment = .trailing
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, edge: tooltipEdge, alignment: tooltipAlignment)
    }
}

/// Live frames-per-second readout in the header strip, fed by `FPSCounter`.
/// It exists only while the manager's toggle is on, so the counter starts
/// when the badge appears and stops when it leaves the hierarchy.
private struct FPSBadge: View {
    @StateObject private var counter = FPSCounter()

    var body: some View {
        Text("\(counter.fps) fps")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.07))
            )
            .onAppear { counter.start() }
            .onDisappear { counter.stop() }
    }
}

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    var body: some View {
        ChromeIconButton(
            systemImage: systemImage,
            tooltip: tooltip,
            tooltipEdge: .above,
            tooltipAlignment: tooltipAlignment,
            action: action
        )
    }
}
