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
        var types: Set<HKObjectType> = [HKWorkoutType.workoutType()] // Read other apps' workouts
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

    // MARK: - Recent Activities (climbing, cardio, etc. from other apps)

    func fetchRecentActivities(days: Int = 7) async -> [(type: String, date: Date, duration: TimeInterval, calories: Double?, source: String)] {
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 50
        )

        do {
            let workouts = try await descriptor.result(for: healthStore)

            return workouts.compactMap { workout in
                // Skip our own strength training workouts
                if workout.workoutActivityType == .traditionalStrengthTraining {
                    // Check if it's from BenLift — skip those
                    if workout.sourceRevision.source.bundleIdentifier.contains("BenLift") ||
                       workout.sourceRevision.source.bundleIdentifier.contains("benlevy") {
                        return nil
                    }
                }

                let type = activityTypeName(workout.workoutActivityType)
                let calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                let source = workout.sourceRevision.source.name

                return (type: type, date: workout.startDate, duration: workout.duration, calories: calories, source: source)
            }
        } catch {
            print("[BenLift/HK] Fetch activities error: \(error)")
            return []
        }
    }

    private func activityTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .climbing: return "climbing"
        case .running: return "running"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .yoga: return "yoga"
        case .hiking: return "hiking"
        case .functionalStrengthTraining: return "functional_training"
        case .traditionalStrengthTraining: return "strength_training"
        case .highIntensityIntervalTraining: return "hiit"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .stairClimbing: return "stair_climbing"
        case .basketball: return "basketball"
        case .soccer: return "soccer"
        case .tennis: return "tennis"
        default: return "other"
        }
    }

    // MARK: - Health Averages (for Intelligence Refresh)

    struct HealthAverages {
        var avgSleep: (average: Double, trend: String)?
        var avgRHR: (average: Double, trend: String)?
        var avgHRV: (average: Double, trend: String)?
    }

    func fetchHealthAverages(days: Int = 30) async -> HealthAverages {
        guard HealthKitService.isAvailable else { return HealthAverages() }

        async let sleepAvg = fetchSleepAverage(days: days)
        async let rhrAvg = fetchQuantityAverage(.restingHeartRate, unit: HKUnit(from: "count/min"), days: days)
        async let hrvAvg = fetchQuantityAverage(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli), days: days)

        return await HealthAverages(avgSleep: sleepAvg, avgRHR: rhrAvg, avgHRV: hrvAvg)
    }

    private func fetchSleepAverage(days: Int) async -> (average: Double, trend: String)? {
        let calendar = Calendar.current
        var nightly: [Double] = []

        for dayOffset in 1...days {
            guard let nightStart = calendar.date(byAdding: .day, value: -dayOffset, to: Date()),
                  let pm9 = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: nightStart),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: nightStart),
                  let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: nextDay) else { continue }

            guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
            let predicate = HKQuery.predicateForSamples(withStart: pm9, end: noon, options: .strictStartDate)
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: sleepType, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )

            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            ]

            if let samples = try? await descriptor.result(for: healthStore) {
                let hours = samples
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 3600.0
                if hours > 0 { nightly.append(hours) }
            }
        }

        guard !nightly.isEmpty else { return nil }
        let avg = nightly.reduce(0, +) / Double(nightly.count)
        let trend = computeTrend(nightly)
        return (average: avg, trend: trend)
    }

    private func fetchQuantityAverage(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        days: Int
    ) async -> (average: Double, trend: String)? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: Date(), options: .strictStartDate)

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: quantityType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)],
            limit: 500
        )

        guard let results = try? await descriptor.result(for: healthStore), !results.isEmpty else { return nil }
        let values = results.map { $0.quantity.doubleValue(for: unit) }
        let avg = values.reduce(0, +) / Double(values.count)
        let trend = computeTrend(values)
        return (average: avg, trend: trend)
    }

    private func computeTrend(_ values: [Double]) -> String {
        guard values.count >= 4 else { return "stable" }
        let mid = values.count / 2
        let firstHalf = Array(values.prefix(mid))
        let secondHalf = Array(values.suffix(mid))
        let firstAvg = firstHalf.reduce(0, +) / Double(firstHalf.count)
        let secondAvg = secondHalf.reduce(0, +) / Double(secondHalf.count)
        guard firstAvg > 0 else { return "stable" }
        let change = (secondAvg - firstAvg) / firstAvg
        if change > 0.05 { return "rising" }
        if change < -0.05 { return "declining" }
        return "stable"
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
