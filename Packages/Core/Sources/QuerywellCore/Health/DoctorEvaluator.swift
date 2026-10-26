import Foundation

public enum DoctorState: Sendable, Hashable {
    /// Matches the baseline.
    case ok
    /// Differs from the baseline; `recommendedValue` says what to set.
    case recommendation
    /// Cannot be judged without more information (the server's RAM).
    case needsInput
}

/// The result of one baseline rule on one server.
public struct DoctorFinding: Sendable, Hashable, Identifiable {
    public var id: String { ruleID }
    public var ruleID: String
    /// The variable the fix would set (usually the rule's own).
    public var variable: String
    public var title: String
    public var state: DoctorState
    public var severity: DoctorSeverity
    public var currentValue: String?
    public var recommendedValue: String?
    public var kind: SettingValueKind
    public var rationale: String
    /// What this server's numbers say (why this value), or what is missing.
    public var note: String?
    public var needsServerRAM: Bool
    public var restartRequired: Bool
    /// The server cannot change it while running: only `SET PERSIST_ONLY` (MySQL) or a config file edit.
    public var readOnlyAtRuntime: Bool
    public var scopes: [SettingScope]
    public var isIgnored: Bool
    /// `current` as the server reported it, for the revision's old value.
    public var currentIsDefault: Bool

    public var currentDisplay: String { SettingDisplay.pretty(variable: variable, value: currentValue, kind: kind, engineIsPostgres: scopes.contains(.alterSystem)) }
    public var recommendedDisplay: String { SettingDisplay.pretty(variable: variable, value: recommendedValue, kind: kind, engineIsPostgres: scopes.contains(.alterSystem)) }

    /// The change for `scope` (default: the most durable available), nil when nothing is recommended.
    public func change(scope: SettingScope? = nil) -> SettingChange? {
        guard state == .recommendation, let recommendedValue, let scope = scope ?? scopes.first else { return nil }
        return SettingChange(variable: variable, value: recommendedValue, currentValue: currentValue,
                             currentIsDefault: currentIsDefault, scope: scope, restartRequired: restartRequired)
    }
}

public struct DoctorReport: Sendable, Hashable {
    public var findings: [DoctorFinding]
    public var inputs: DoctorInputs

    /// Active recommendations, most severe first.
    public var recommendations: [DoctorFinding] { findings.filter { $0.state == .recommendation && !$0.isIgnored } }
    public var needingInput: [DoctorFinding] { findings.filter { $0.state == .needsInput && !$0.isIgnored } }
    public var passing: [DoctorFinding] { findings.filter { $0.state == .ok } }
    public var ignored: [DoctorFinding] { findings.filter { $0.isIgnored && $0.state != .ok } }
}

public enum SettingDisplay {
    /// "4 GiB (4294967296)" for MySQL byte counts, the value itself otherwise; "(not set)" for nil.
    public static func pretty(variable: String, value: String?, kind: SettingValueKind, engineIsPostgres: Bool) -> String {
        guard let value else { return "Not set" }
        if value.isEmpty { return "(empty)" }
        if kind == .bytes, !engineIsPostgres, let n = Int64(value) { return "\(ByteSize.pretty(n)) (\(n))" }
        return value
    }
}

public struct DoctorEvaluator: Sendable {
    public var rules: [BaselineRule]

    public init(rules: [BaselineRule] = DoctorBaseline.rules) {
        self.rules = rules
    }

    public func evaluate(_ facts: ServerFacts, inputs: DoctorInputs = DoctorInputs(), ignoredRuleIDs: Set<String> = []) -> DoctorReport {
        var findings: [DoctorFinding] = []
        for rule in rules where rule.applies(facts) {
            let verdict = rule.evaluate(facts, inputs)
            if verdict == .notApplicable { continue }
            let readOnly = rule.readOnlyAtRuntime(facts)
            let restart = rule.restartRequired(facts)
            var variable = rule.variable
            var state = DoctorState.ok
            var recommended: String?
            var note: String?
            switch verdict {
            case .ok(let n): note = n
            case .recommend(let value, let override, let n):
                state = .recommendation
                recommended = value
                note = n
                if let override { variable = override }
            case .needsInput(let message):
                state = .needsInput
                note = message
            case .notApplicable: continue
            }
            let overriddenRule = DoctorBaseline.rules(forVariable: variable).first
            let current = facts.variable(variable)
            findings.append(DoctorFinding(
                ruleID: rule.id, variable: variable, title: rule.title, state: state, severity: rule.severity,
                currentValue: current, recommendedValue: recommended, kind: overriddenRule?.kind ?? rule.kind,
                rationale: rule.rationale, note: note, needsServerRAM: rule.needsServerRAM,
                restartRequired: restart || (overriddenRule.map { $0.restartRequired(facts) } ?? false),
                readOnlyAtRuntime: readOnly,
                scopes: SettingSQL.availableScopes(engine: facts.engine, major: facts.major, minor: facts.minor,
                                                   patch: facts.patch, readOnlyVariable: readOnly),
                isIgnored: ignoredRuleIDs.contains(rule.id),
                currentIsDefault: facts.sources[variable.lowercased()] == "default"))
        }
        findings.sort {
            if $0.state != $1.state { return Self.order($0.state) < Self.order($1.state) }
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.title < $1.title
        }
        return DoctorReport(findings: findings, inputs: inputs)
    }

    private static func order(_ s: DoctorState) -> Int {
        switch s {
        case .recommendation: 0
        case .needsInput: 1
        case .ok: 2
        }
    }
}
