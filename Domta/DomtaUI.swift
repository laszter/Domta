//
//  DomtaUI.swift
//  Domta
//

import SwiftUI

/// การ์ดหัวข้อแบบเดียวกับหน้า Connections เพื่อให้หน้าใหม่ดูเป็นชุดเดียวกัน
struct DomtaSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 16, x: 0, y: 8)
    }
}

/// พื้นหลังไล่สีเดียวกับหน้าหลัก
struct DomtaPageBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.05),
                    Color.orange.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.08))
                .frame(width: 340, height: 340)
                .blur(radius: 70)
                .offset(x: -360, y: -250)

            Circle()
                .fill(Color.orange.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 70)
                .offset(x: 420, y: -180)
        }
        .ignoresSafeArea()
    }
}

/// ตัวเลขสรุปที่กดเพื่อกรองรายการได้
struct DomtaFilterChip: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)

                    Text(value)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(isActive ? tint.opacity(0.16) : Color(nsColor: .windowBackgroundColor).opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive ? tint.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

/// ช่องค้นหาแบบเดียวกับหน้า Comparable Tables
struct DomtaSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

extension SchemaChangeKind {
    var tint: Color {
        switch self {
        case .create: return .green
        case .alter: return .orange
        case .drop: return .red
        case .rebuild: return .purple
        case .other: return .secondary
        }
    }
}

extension SchemaDiffLineKind {
    var backgroundColor: Color {
        switch self {
        case .unchanged: return .clear
        case .sourceOnly: return Color.green.opacity(0.16)
        case .targetOnly: return Color.red.opacity(0.14)
        }
    }

    var gutterSymbol: String {
        switch self {
        case .unchanged: return " "
        case .sourceOnly: return "+"
        case .targetOnly: return "-"
        }
    }
}

extension SchemaSideBySideRowKind {
    var sourceBackground: Color {
        switch self {
        case .changed, .sourceOnly: return Color.green.opacity(0.16)
        case .unchanged, .targetOnly: return .clear
        }
    }

    var targetBackground: Color {
        switch self {
        case .changed, .targetOnly: return Color.red.opacity(0.14)
        case .unchanged, .sourceOnly: return .clear
        }
    }
}
