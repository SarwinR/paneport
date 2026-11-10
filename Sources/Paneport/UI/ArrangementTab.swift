import AppKit
import SwiftUI

/// A map of all displays. Virtual ones can be dragged; they snap next to the others.
struct ArrangementTab: View {
    @EnvironmentObject private var engine: StreamEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(engine.isRunning
                 ? "Drag the blue virtual displays to match where those monitors sit on your desk. "
                    + "They snap to the nearest edge. Grey displays are real and are moved in System Settings."
                 : "Start streaming to arrange the virtual displays. They appear here next to your real displays.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ArrangementCanvas(screens: engine.screens) { id, origin in
                engine.move(id, to: origin)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))

            HStack {
                legend
                Spacer()
                Button("Refresh") { engine.refreshScreens() }
                Button("Open Displays Settings…") { SystemSettingsLink.open(SystemSettingsLink.displays) }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendSwatch(Color.accentColor, "Virtual (streamed)")
            legendSwatch(Color.gray, "Real")
            HStack(spacing: 6) {
                Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 18, height: 3)
                Text("Menu bar").font(.caption)
            }
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color))
                .frame(width: 18, height: 12)
            Text(label).font(.caption)
        }
    }
}

struct ArrangementCanvas: View {
    let screens: [ScreenInfo]
    let onMove: (CGDirectDisplayID, CGPoint) -> Void

    @State private var dragging: CGDirectDisplayID?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let layout = CanvasLayout(screens: screens, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(screens) { screen in
                    tile(screen, layout: layout)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(minHeight: 280)
    }

    private func tile(_ screen: ScreenInfo, layout: CanvasLayout) -> some View {
        let isDragging = dragging == screen.id
        let rect = layout.rect(screen.bounds)
        return ScreenTile(screen: screen, isHighlighted: isDragging)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX + (isDragging ? translation.width : 0),
                    y: rect.minY + (isDragging ? translation.height : 0))
            .zIndex(isDragging ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        dragging = screen.id
                        translation = value.translation
                    }
                    .onEnded { value in
                        let origin = CGPoint(x: screen.bounds.minX + value.translation.width / layout.scale,
                                             y: screen.bounds.minY + value.translation.height / layout.scale)
                        dragging = nil
                        translation = .zero
                        onMove(screen.id, origin)
                    },
                including: screen.isVirtual ? .all : .subviews)   // real displays can't be dragged here
    }
}

/// Maps display coordinates (points) into the canvas, fitting all displays with a margin.
struct CanvasLayout {
    let scale: CGFloat
    let offset: CGPoint

    private static let marginFraction: CGFloat = 0.12

    init(screens: [ScreenInfo], size: CGSize) {
        let union = screens.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !union.isNull, union.width > 0, union.height > 0, size.width > 0, size.height > 0 else {
            scale = 1
            offset = .zero
            return
        }
        let margin = max(union.width, union.height) * Self.marginFraction
        let world = union.insetBy(dx: -margin, dy: -margin)
        let s = min(size.width / world.width, size.height / world.height)
        scale = s
        offset = CGPoint(x: (size.width - world.width * s) / 2 - world.minX * s,
                         y: (size.height - world.height * s) / 2 - world.minY * s)
    }

    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: offset.x + r.minX * scale, y: offset.y + r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }
}

struct ScreenTile: View {
    let screen: ScreenInfo
    let isHighlighted: Bool

    var body: some View {
        let color = screen.isVirtual ? Color.accentColor : Color.gray
        RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(isHighlighted ? 0.6 : 0.35))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color, lineWidth: isHighlighted ? 2.5 : 1.5))
            .overlay(alignment: .top) {
                if screen.isMain {
                    Rectangle().fill(Color.primary.opacity(0.7))
                        .frame(height: 3)
                        .padding(.horizontal, 6)
                        .padding(.top, 5)
                }
            }
            .overlay {
                VStack(spacing: 2) {
                    Text(screen.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("\(Int(screen.bounds.width)) × \(Int(screen.bounds.height))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(4)
                .minimumScaleFactor(0.5)
            }
            .contentShape(Rectangle())
            .help(screen.isVirtual ? "Drag to rearrange" : "Real display: arrange in System Settings")
    }
}
