import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("Threshold rules only fire when they have earned it")
struct ThresholdEvaluatorTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func rule(_ metric: ThresholdMetric, threshold: Double,
                      sustainedFor: TimeInterval = 30, cooldown: TimeInterval = 900) -> ThresholdRule {
        ThresholdRule(metric: metric, threshold: threshold, isEnabled: true,
                      sustainedFor: sustainedFor, cooldown: cooldown)
    }

    /// Feeds one reading per two-second sample for `seconds` and collects everything
    /// that fired, which is the cadence the engine actually publishes at.
    private func run(_ evaluator: inout ThresholdEvaluator, rule: ThresholdRule,
                     value: Double?, from offset: TimeInterval, seconds: TimeInterval) -> [ThresholdAlert] {
        var alerts: [ThresholdAlert] = []
        var t = offset
        while t < offset + seconds {
            let readings = value.map { [rule.metric: $0] } ?? [:]
            alerts += evaluator.alerts(for: [rule], readings: readings,
                                       now: start.addingTimeInterval(t))
            t += 2
        }
        return alerts
    }

    @Test("a spike shorter than the sustained duration never alerts")
    func transientSpikeIsIgnored() {
        var evaluator = ThresholdEvaluator()
        let cpu = rule(.cpuUsage, threshold: 90, sustainedFor: 30)

        let spiking = run(&evaluator, rule: cpu, value: 99, from: 0, seconds: 10)
        let recovered = run(&evaluator, rule: cpu, value: 4, from: 10, seconds: 10)
        // Back over the line, but the clock restarted, so 10 s of breach is still
        // 10 s short of the 30 s the user asked for.
        let spikingAgain = run(&evaluator, rule: cpu, value: 99, from: 20, seconds: 10)

        #expect(spiking.isEmpty)
        #expect(recovered.isEmpty)
        #expect(spikingAgain.isEmpty)
    }

    @Test("a breach held past the sustained duration alerts once")
    func sustainedBreachAlertsOnce() {
        var evaluator = ThresholdEvaluator()
        let cpu = rule(.cpuUsage, threshold: 90, sustainedFor: 30)

        let alerts = run(&evaluator, rule: cpu, value: 96, from: 0, seconds: 60)

        #expect(alerts.count == 1)
        #expect(alerts.first?.metric == .cpuUsage)
        #expect(alerts.first?.value == 96)
        #expect(alerts.first?.threshold == 90)
    }

    @Test("a zero sustained duration alerts on the first breaching sample")
    func zeroSustainedFiresImmediately() {
        var evaluator = ThresholdEvaluator()
        let cpu = rule(.cpuUsage, threshold: 90, sustainedFor: 0)

        let alerts = evaluator.alerts(for: [cpu], readings: [.cpuUsage: 91], now: start)

        #expect(alerts.count == 1)
    }

    @Test("cooldown holds the second alert back until it has elapsed")
    func cooldownSuppressesRepeats() {
        var evaluator = ThresholdEvaluator()
        let cpu = rule(.cpuUsage, threshold: 90, sustainedFor: 0, cooldown: 300)

        let first = evaluator.alerts(for: [cpu], readings: [.cpuUsage: 95], now: start)
        let duringCooldown = run(&evaluator, rule: cpu, value: 95, from: 2, seconds: 296)
        let afterCooldown = evaluator.alerts(for: [cpu], readings: [.cpuUsage: 95],
                                             now: start.addingTimeInterval(300))

        #expect(first.count == 1)
        #expect(duringCooldown.isEmpty)
        #expect(afterCooldown.count == 1)
    }

    @Test("a metric with no reading stops the clock rather than crediting the time")
    func missingReadingRestartsTheClock() {
        var evaluator = ThresholdEvaluator()
        let temperature = rule(.cpuTemperature, threshold: 95, sustainedFor: 30)

        let breaching = run(&evaluator, rule: temperature, value: 99, from: 0, seconds: 20)
        let unreadable = run(&evaluator, rule: temperature, value: nil, from: 20, seconds: 20)
        let breachingAgain = run(&evaluator, rule: temperature, value: 99, from: 40, seconds: 20)

        #expect(breaching.isEmpty)
        #expect(unreadable.isEmpty)
        #expect(breachingAgain.isEmpty)
    }

    @Test("falling metrics fire below the threshold, rising metrics above it")
    func directionIsPerMetric() {
        #expect(ThresholdMetric.batteryLow.isBreached(by: 15, threshold: 20))
        #expect(!ThresholdMetric.batteryLow.isBreached(by: 40, threshold: 20))
        #expect(ThresholdMetric.diskFree.isBreached(by: 4, threshold: 10))
        #expect(!ThresholdMetric.diskFree.isBreached(by: 60, threshold: 10))

        #expect(ThresholdMetric.cpuUsage.isBreached(by: 95, threshold: 90))
        #expect(!ThresholdMetric.cpuUsage.isBreached(by: 12, threshold: 90))
        #expect(ThresholdMetric.memoryPressure.isBreached(by: 85, threshold: 80))
        #expect(!ThresholdMetric.memoryPressure.isBreached(by: 30, threshold: 80))
        #expect(ThresholdMetric.cpuTemperature.isBreached(by: 101, threshold: 95))
        #expect(!ThresholdMetric.cpuTemperature.isBreached(by: 45, threshold: 95))
        #expect(ThresholdMetric.thermalPressure.isBreached(by: 3, threshold: 2))
        #expect(!ThresholdMetric.thermalPressure.isBreached(by: 0, threshold: 2))
        #expect(ThresholdMetric.batteryFull.isBreached(by: 100, threshold: 100))
        #expect(!ThresholdMetric.batteryFull.isBreached(by: 82, threshold: 100))
    }

    @Test("a full battery alerts once and not again until it leaves the threshold")
    func batteryFullDoesNotRepeat() {
        var evaluator = ThresholdEvaluator()
        let full = rule(.batteryFull, threshold: 100, sustainedFor: 0, cooldown: 60)

        let reachesFull = evaluator.alerts(for: [full], readings: [.batteryFull: 100], now: start)
        // Six hours on the charger at 100%, which is twenty-four cooldowns.
        let leftOnCharger = run(&evaluator, rule: full, value: 100, from: 2, seconds: 21_600)
        let drainsAndReturns = evaluator.alerts(for: [full], readings: [.batteryFull: 96],
                                                now: start.addingTimeInterval(21_700))
            + evaluator.alerts(for: [full], readings: [.batteryFull: 100],
                               now: start.addingTimeInterval(21_800))

        #expect(reachesFull.count == 1)
        #expect(leftOnCharger.isEmpty)
        #expect(drainsAndReturns.count == 1)
    }

    @Test("state for a rule the user switched off is dropped, not carried")
    func disabledRuleStateIsDropped() {
        var evaluator = ThresholdEvaluator()
        let cpu = rule(.cpuUsage, threshold: 90, sustainedFor: 30)

        _ = run(&evaluator, rule: cpu, value: 99, from: 0, seconds: 20)
        #expect(evaluator.trackedRuleCount == 1)

        // The monitor passes only the rules cleared for delivery, so a rule switched
        // off arrives as an absence.
        _ = evaluator.alerts(for: [], readings: [.cpuUsage: 99], now: start.addingTimeInterval(22))
        #expect(evaluator.trackedRuleCount == 0)

        // Switched back on, the 20 s already served does not count towards the 30 s.
        let resumed = run(&evaluator, rule: cpu, value: 99, from: 24, seconds: 20)
        #expect(resumed.isEmpty)
    }

    @Test("reset clears every rule's bookkeeping")
    func resetClearsState() {
        var evaluator = ThresholdEvaluator()
        _ = evaluator.alerts(for: [rule(.cpuUsage, threshold: 90)],
                             readings: [.cpuUsage: 99], now: start)
        #expect(evaluator.trackedRuleCount == 1)

        evaluator.reset()
        #expect(evaluator.trackedRuleCount == 0)
    }

    @Test("two breaching rules both fire in one pass")
    func independentRulesDoNotInterfere() {
        var evaluator = ThresholdEvaluator()
        let cpu = rule(.cpuUsage, threshold: 90, sustainedFor: 0)
        let memory = rule(.memoryPressure, threshold: 80, sustainedFor: 0)

        let alerts = evaluator.alerts(for: [cpu, memory],
                                      readings: [.cpuUsage: 92, .memoryPressure: 88],
                                      now: start)

        #expect(Set(alerts.map(\.metric)) == [.cpuUsage, .memoryPressure])
    }
}

@Suite("Snapshot readings arrive in the units the rules are written in")
struct ThresholdReadingTests {

    private func volume(availableBytes: UInt64) -> VolumeInfo {
        VolumeInfo(id: "root", name: "Macintosh HD", path: "/", totalBytes: 494_384_795_648,
                   freeBytes: availableBytes, availableBytes: availableBytes, isRoot: true)
    }

    @Test("percentages come through as percentages, not fractions")
    func fractionsBecomePercentages() {
        let snapshot = SystemSnapshot(
            cpu: .value(CPUSnapshot(total: CPULoad(user: 0.5, system: 0.24, idle: 0.26))),
            memory: .value(MemorySnapshot(pressureFraction: 0.62)))
        let readings = ThresholdEvaluator.readings(from: snapshot)

        #expect(readings[.cpuUsage].map { Int($0.rounded()) } == 74)
        #expect(readings[.memoryPressure].map { Int($0.rounded()) } == 62)
    }

    @Test("free disk space is reported in the GB the rule asks for")
    func diskFreeIsGigabytes() {
        let snapshot = SystemSnapshot(disk: .value(DiskSnapshot(volumes: [volume(availableBytes: 8_500_000_000)])))
        let readings = ThresholdEvaluator.readings(from: snapshot)

        #expect(readings[.diskFree].map { Int($0.rounded()) } == 9)
    }

    @Test("battery rules split on whether the machine is on the charger")
    func batteryReadingsSplitByChargeState() {
        let discharging = ThresholdEvaluator.readings(
            from: SystemSnapshot(power: .value(PowerSnapshot(hasBattery: true, percentage: 14,
                                                            isPluggedIn: false))))
        #expect(discharging[.batteryLow] == 14)
        #expect(discharging[.batteryFull] == nil)

        let charging = ThresholdEvaluator.readings(
            from: SystemSnapshot(power: .value(PowerSnapshot(hasBattery: true, percentage: 100,
                                                            isCharging: false, isPluggedIn: true,
                                                            isFullyCharged: true))))
        #expect(charging[.batteryFull] == 100)
        #expect(charging[.batteryLow] == nil)
    }

    @Test("a Mac with no battery produces no battery readings")
    func missingBatteryProducesNoReading() {
        let readings = ThresholdEvaluator.readings(
            from: SystemSnapshot(power: .value(PowerSnapshot(hasBattery: false, percentage: nil))))

        #expect(readings[.batteryLow] == nil)
        #expect(readings[.batteryFull] == nil)
    }

    @Test("thermal pressure reads as its level, and an unreadable sensor reads as nothing")
    func thermalReadings() {
        let readings = ThresholdEvaluator.readings(
            from: SystemSnapshot(thermal: .value(ThermalSnapshot(pressure: .serious, cpuCelsius: nil,
                                                                 sensorsUnavailableReason: "No readable sensors."))))

        #expect(readings[.thermalPressure] == 2)
        #expect(readings[.cpuTemperature] == nil)
    }

    @Test("a pending snapshot yields no readings at all")
    func pendingSnapshotIsSilent() {
        #expect(ThresholdEvaluator.readings(from: .empty).isEmpty)
    }
}
