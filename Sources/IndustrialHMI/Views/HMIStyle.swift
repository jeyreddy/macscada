import SwiftUI

// MARK: - HMI Design System (ISA-101 aligned)
//
// Central repository for fonts, spacing, and semantic colors used throughout
// the IndustrialHMI application.  All views should reference these constants
// instead of hard-coding `.caption`, `.body`, or literal padding values so that
// the visual language stays consistent as screens evolve.
//
// Alignment references:
//   • ISA-101.01-2015  Human Machine Interfaces for Process Automation Systems
//   • ISA-18.2-2016    Management of Alarm Systems
//   • ANSI/ISA-5.1     Instrumentation Symbols

enum HMIStyle {

    // MARK: - Typography

    /// Tag / node identifier — always monospaced for vertical alignment in tables.
    static let tagNameFont: Font       = .system(.callout, design: .monospaced)

    /// Primary process value in the detail panel (large, prominent, readable).
    static let processValueFont: Font  = .system(.title, design: .monospaced).bold()

    /// Inline process value inside table cells — monospaced, bold for legibility.
    static let inlineValueFont: Font   = .system(.callout, design: .monospaced).bold()

    /// Alarm-limit numeric values (Hi-Hi, High, Low, Lo-Lo rows).
    static let alarmValueFont: Font    = .system(.caption, design: .monospaced)

    /// Primary status-bar labels (connection state, alarm count).  One step above
    /// caption so operators can read without squinting at a 1–2 m distance.
    static let statusLabelFont: Font   = .callout.bold()

    /// Secondary status-bar data (server URL, poll interval).
    static let statusMetaFont: Font    = .caption

    /// Field label above a value (ISA-101: labels 30–50 % smaller than values).
    static let fieldLabelFont: Font    = .caption

    /// Timestamps, occurrence counts, and other tertiary metadata.
    static let metaFont: Font          = .caption2

    // MARK: - Spacing  (4-pt grid — aligns with macOS HIG and ISA-101 §6.3)

    static let spacingXS: CGFloat =  4
    static let spacingS:  CGFloat =  8
    static let spacingM:  CGFloat = 12
    static let spacingL:  CGFloat = 16
    static let spacingXL: CGFloat = 20

    // MARK: - Component sizes

    /// Minimum status-toolbar height (ensures readable tap/click targets).
    static let toolbarPaddingV: CGFloat = 8
    static let toolbarPaddingH: CGFloat = 12

    /// Quality-indicator dot diameter.
    static let qualityDotSize:  CGFloat = 8

    // MARK: - Semantic Colors  (ISA-18.2 §5.3 / ISA-101 §7.4)

    /// Unambiguous red — critical alarms, Hi-Hi limits, bad quality.
    static let colorCritical:   Color = .red

    /// Warning amber — High/Low limits, warning alarms, degraded state.
    static let colorWarning:    Color = .orange

    /// Normal / good — use sparingly; must stand out against neutral-gray background.
    static let colorNormal:     Color = .green

    /// Uncertain / stale data — distinct from both normal and bad.
    static let colorUncertain:  Color = Color(red: 0.95, green: 0.80, blue: 0.00)

    // MARK: - Color helpers

    static func qualityColor(_ quality: TagQuality) -> Color {
        switch quality {
        case .good:      return colorNormal
        case .bad:       return colorCritical
        case .uncertain: return colorUncertain
        }
    }

    static func severityColor(_ severity: AlarmSeverity) -> Color {
        switch severity {
        case .critical: return colorCritical
        case .warning:  return colorWarning
        case .info:     return .blue
        }
    }

    static func alarmStateColor(_ state: AlarmState) -> Color {
        switch state {
        case .unacknowledgedActive: return colorCritical
        case .acknowledgedActive:   return colorWarning
        case .unacknowledgedRTN:    return colorNormal
        case .normal:               return Color(nsColor: .secondaryLabelColor)
        case .suppressed:           return Color(nsColor: .tertiaryLabelColor)
        case .shelved:              return .purple
        case .outOfService:         return Color(nsColor: .tertiaryLabelColor)
        }
    }
}
