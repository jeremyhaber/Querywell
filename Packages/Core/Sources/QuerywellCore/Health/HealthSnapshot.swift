import Foundation

public enum HealthStatus: Int, Sendable, Hashable, Comparable, Codable {
    /// No judgement (a plain fact, or too little data).
    case info
    case ok
    case warn
    case critical
    /// The account could not read this (missing privilege) or the server does not report it.
    case unavailable

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .info: "Info"
        case .ok: "OK"
        case .warn: "Warning"
        case .critical: "Critical"
        case .unavailable: "Not available"
        }
    }
}

public struct HealthMetric: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The headline figure ("93% used", "4.2 GiB"), or "Not available".
    public var value: String
    /// One line of context: the threshold crossed, or why it is unavailable.
    public var detail: String?
    public var status: HealthStatus

    public init(id: String, title: String, value: String, detail: String? = nil, status: HealthStatus) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.status = status
    }
}

public struct HealthRow: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: HealthStatus
    public init(id: String, title: String, detail: String, status: HealthStatus = .info) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

/// A list under the metrics ("Largest tables", "Tables without a primary key", …).
public struct HealthList: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var rows: [HealthRow]
    public var status: HealthStatus
    public init(id: String, title: String, summary: String, rows: [HealthRow], status: HealthStatus) {
        self.id = id
        self.title = title
        self.summary = summary
        self.rows = rows
        self.status = status
    }
}

public struct HealthGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var metrics: [HealthMetric]
    public init(id: String, title: String, metrics: [HealthMetric]) {
        self.id = id
        self.title = title
        self.metrics = metrics
    }
}

public struct HealthSnapshot: Sendable, Hashable {
    public var engine: DatabaseEngine
    public var groups: [HealthGroup]
    public var lists: [HealthList]
    public var collectedAt: Date

    /// The worst judged status on the page (info / unavailable do not count).
    public var overall: HealthStatus {
        let all = groups.flatMap(\.metrics).map(\.status) + lists.map(\.status)
        return all.filter { $0 == .ok || $0 == .warn || $0 == .critical }.max() ?? .info
    }

    public func metric(_ id: String) -> HealthMetric? { groups.flatMap(\.metrics).first { $0.id == id } }
    public func list(_ id: String) -> HealthList? { lists.first { $0.id == id } }
    public var warningCount: Int { groups.flatMap(\.metrics).filter { $0.status == .warn || $0.status == .critical }.count + lists.filter { $0.status == .warn || $0.status == .critical }.count }
}

/// Where a ratio turns amber and red. "Higher is worse" unless `lowerIsWorse`.
public struct HealthThreshold: Sendable, Hashable {
    public var warn: Double
    public var critical: Double
    public var lowerIsWorse: Bool

    public init(warn: Double, critical: Double, lowerIsWorse: Bool = false) {
        self.warn = warn
        self.critical = critical
        self.lowerIsWorse = lowerIsWorse
    }

    public func status(_ value: Double) -> HealthStatus {
        if lowerIsWorse {
            if value < critical { return .critical }
            if value < warn { return .warn }
        } else {
            if value >= critical { return .critical }
            if value >= warn { return .warn }
        }
        return .ok
    }
}

/// The defaults the Health page judges against (all documented in the metric's detail line).
public struct HealthThresholds: Sendable, Hashable {
    public var connectionUsage = HealthThreshold(warn: 0.70, critical: 0.90)
    public var maxUsedConnections = HealthThreshold(warn: 0.80, critical: 0.95)
    public var threadsRunning = HealthThreshold(warn: 16, critical: 64)
    /// Share of Questions that were slow.
    public var slowQueryShare = HealthThreshold(warn: 0.01, critical: 0.05)
    public var bufferPoolHit = HealthThreshold(warn: 0.99, critical: 0.95, lowerIsWorse: true)
    /// Buffer pool size as a share of InnoDB data + indexes.
    public var bufferPoolCoverage = HealthThreshold(warn: 0.25, critical: 0.05, lowerIsWorse: true)
    public var tmpDiskShare = HealthThreshold(warn: 0.25, critical: 0.50)
    public var tableOpenMisses = HealthThreshold(warn: 0.10, critical: 0.30)
    public var abortedConnects = HealthThreshold(warn: 0.02, critical: 0.10)
    public var pgCacheHit = HealthThreshold(warn: 0.99, critical: 0.95, lowerIsWorse: true)
    public var pgRollbackShare = HealthThreshold(warn: 0.05, critical: 0.20)
    public var pgDeadlocks = HealthThreshold(warn: 1, critical: 10)
    public var pgTempBytes = HealthThreshold(warn: 1_073_741_824, critical: 53_687_091_200)
    public var pgDeadTupleShare = HealthThreshold(warn: 0.20, critical: 0.50)
    /// Counters below these sample sizes are shown as info: ratios of a handful of events mean nothing.
    public var minimumSample: Int64 = 1_000

    public init() {}
}
