import QuerywellCore
import SwiftUI

/// Live progress and outcome of Test Connection.
struct TestResultView: View {
    var state: ConnectionEditorModel.TestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running(let stage):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage.map { $0.title + "…" } ?? "Starting…")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(12)
            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .accessibilityElement(children: .combine)
        case .finished(let report):
            if report.succeeded { success(report) } else { failure(report) }
        }
    }

    private func success(_ report: ConnectionTestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Connection successful").font(.headline)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.connectedDot)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let info = report.serverInfo { line("Server", info.shortDescription) }
                if let latency = report.latency { line("Latency", "\(latency.wholeMilliseconds) ms") }
                line("TLS", report.tlsActive ? "On" : "Off")
                line("Route", report.usedTunnel ? "Via SSH tunnel" : "Direct")
                line("Total time", "\(report.totalDuration.wholeMilliseconds) ms")
            }
            if !report.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.warningText)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .accessibilityElement(children: .contain)
    }

    private func failure(_ report: ConnectionTestReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(report.failedStage.map { "Failed: \($0.title)" } ?? "Connection failed").font(.headline)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.dangerText)
            }
            if let error = report.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.message)
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion).foregroundStyle(Theme.textSecondary)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.dangerBackground, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .accessibilityElement(children: .contain)
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(name).foregroundStyle(Theme.textSecondary).frame(width: 80, alignment: .leading)
            Text(value)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
