import Foundation
import HealthKit

@Observable
class HealthKitService {
    static let shared = HealthKitService()

    let healthStore = HKHealthStore()
    var isAuthorized = false
    var authorizationError: String?

    static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Read Types

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.insert(rhr) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
        if let hr = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let activeE = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(activeE) }
        if let weight = HKObjectType.quantityType(forIdentifier: .bodyMass) { types.insert(weight) }
        if let vo2 = HKObjectType.quantityType(forIdentifier: .vo2Max) { types.insert(vo2) }
        return types
    }

    // MARK: - Write Types

    private var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKWorkoutType.workoutType()]
        if let activeE = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(activeE) }
        return types
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HealthKitService.isAvailable else {
            authorizationError = "HealthKit not available on this device"
            print("[BenLift/HK] HealthKit not available")
            return
        }

        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            isAuthorized = true
            print("[BenLift/HK] Authorization granted")
        } catch {
            authorizationError = error.localizedDescription
            print("[BenLift/HK] Authorization error: \(error)")
        }
    }

    // MARK: - Fetch All Health Context

    func fetchHealthContext() async -> HealthContext {
        guard HealthKitService.isAvailable else { return HealthContext() }

        async let sleep = fetchLastNightSleep()
        async let rhr = fetchRestingHeartRate()
        async let hrv = fetchHRV()
        async let weight = fetchBodyWeight()
        async let vo2 = fetchVO2Max()

        let context = await HealthContext(
            sleepHours: sleep,
            restingHR: rhr,
            hrv: hrv,
            bodyWeight: weight,
            vo2Max: vo2
        )

        print("[BenLift/HK] Health context: sleep=\(context.sleepHours.map { String(format: "%.1f", $0) } ?? "nil")h, rhr=\(context.restingHR.map { "\(Int($0))" } ?? "nil")bpm, hrv=\(context.hrv.map { "\(Int($0))" } ?? "nil")ms, weight=\(context.bodyWeight.map { "\(Int($0))" } ?? "nil")lbs")

        return context
    }

    // MARK: - Sleep

    func fetchLastNightSleep() async -> Double? {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }

        let calendar = Calendar.current
        // 9pm yesterday to now
        let now = Date()
        guard let yesterday9pm = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: -1, to: now)!) else { return nil }

        let predicate = HKQuery.predicateForSamples(withStart: yesterday9pm, end: now, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )

        do {
            let samples = try await descriptor.result(for: healthStore)
            // Sum all asleep states (core, deep, REM, unspecified)
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            ]

            let totalSeconds = samples
                .filter { asleepValues.contains($0.value) }
                .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }

            let hours = totalSeconds / 3600.0
            return hours > 0 ? hours : nil
        } catch {
            print("[BenLift/HK] Sleep fetch error: \(error)")
            return nil
        }
    }

    // MARK: - Resting Heart Rate

    func fetchRestingHeartRate() async -> Double? {
        await fetchMostRecentQuantity(.restingHeartRate, unit: HKUnit(from: "count/min"))
    }

    // MARK: - HRV

    func fetchHRV() async -> Double? {
        await fetchMostRecentQuantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli))
    }

    // MARK: - Body Weight

    func fetchBodyWeight() async -> Double? {
        await fetchMostRecentQuantity(.bodyMass, unit: HKUnit.pound(), dayLimit: nil)
    }

    // MARK: - VO2 Max

    func fetchVO2Max() async -> Double? {
        await fetchMostRecentQuantity(.vo2Max, unit: HKUnit(from: "mL/min·kg"), dayLimit: nil)
    }

    // MARK: - Generic Quantity Fetch

    private func fetchMostRecentQuantity(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        dayLimit: Int? = 1
    ) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }

        var predicate: NSPredicate? = nil
        if let days = dayLimit {
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)
        }

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: quantityType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 1
        )

        do {
            let results = try await descriptor.result(for: healthStore)
            return results.first?.quantity.doubleValue(for: unit)
        } catch {
            print("[BenLift/HK] Fetch \(identifier.rawValue) error: \(error)")
            return nil
        }
    }
}
