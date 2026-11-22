import Foundation
import XCTest
@testable import MacSyncCore

final class AdaptiveResourcePolicyTests: XCTestCase {
    func testProgressRateDecreasesOnlyAsPresentationLoadIncreases() {
        let nominal=AdaptiveResourceProfile(thermal:.nominal,lowPower:false)
        let fair=AdaptiveResourceProfile(thermal:.fair,lowPower:false)
        let serious=AdaptiveResourceProfile(thermal:.serious,lowPower:false)
        let critical=AdaptiveResourceProfile(thermal:.critical,lowPower:false)
        let battery=AdaptiveResourceProfile(thermal:.nominal,lowPower:true)
        XCTAssertEqual(nominal.progressInterval,0.2)
        XCTAssertLessThan(nominal.progressInterval,fair.progressInterval)
        XCTAssertLessThan(fair.progressInterval,serious.progressInterval)
        XCTAssertLessThan(serious.progressInterval,critical.progressInterval)
        XCTAssertGreaterThan(battery.progressInterval,nominal.progressInterval)
        XCTAssertGreaterThanOrEqual(critical.nameStatusInterval,serious.nameStatusInterval)
        XCTAssertEqual(AdaptiveResourceProfile.sample().progressInterval.isFinite,true)
    }

    func testUIQueueDelaySlowsAndThenRecoversPresentationRate() {
        let cadence=AdaptiveProgressCadence()
        let nominal=AdaptiveResourceProfile(thermal:.nominal,lowPower:false)
        let serious=AdaptiveResourceProfile(thermal:.serious,lowPower:true)
        XCTAssertEqual(cadence.interval(profile:nominal),0.2)
        for _ in 0..<10 { cadence.observeDeliveryDelay(0.5) }
        XCTAssertEqual(cadence.interval(profile:nominal),1.0)
        XCTAssertEqual(cadence.maximumDeliveryDelay,0.5)
        for _ in 0..<30 { cadence.observeDeliveryDelay(0.02) }
        XCTAssertEqual(cadence.interval(profile:nominal),0.2,accuracy:0.00001)
        XCTAssertGreaterThanOrEqual(cadence.interval(profile:serious),0.6)
        cadence.observeDeliveryDelay(-1)
        cadence.observeDeliveryDelay(Double.infinity)
        XCTAssertEqual(cadence.maximumDeliveryDelay,0.5)
    }

    func testProgressCadenceUnderConcurrentDiagnosticSampling() {
        let cadence=AdaptiveProgressCadence()
        let nominal=AdaptiveResourceProfile(thermal:.nominal,lowPower:false)
        let group=DispatchGroup()
        let began=ProcessInfo.processInfo.systemUptime
        for worker in 0..<4 {
            group.enter()
            DispatchQueue.global(qos:.userInitiated).async {
                for i in 0..<50_000 {
                    cadence.observeDeliveryDelay((i+worker)%5 == 0 ? 0.3 : 0.01)
                    _ = cadence.interval(profile:nominal)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+20),.success)
        print(String(format:"Adaptive cadence 200k concurrent samples: %.3fs",
            ProcessInfo.processInfo.systemUptime-began))
        XCTAssertLessThanOrEqual(cadence.interval(profile:nominal),1.0)
    }
}
