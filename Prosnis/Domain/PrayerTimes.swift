import Foundation

/// Способ расчёта Фаджра: угол погружения солнца под горизонт.
enum PrayerMethod: String, Codable, CaseIterable, Identifiable {
    case dumRF, dumRT, mwl, isna, egypt, ummAlQura, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dumRF: return "ДУМ РФ (16°)"
        case .dumRT: return "ДУМ Татарстана (18°)"
        case .mwl: return "Всемирная исламская лига (18°)"
        case .isna: return "ISNA, Северная Америка (15°)"
        case .egypt: return "Египет (19,5°)"
        case .ummAlQura: return "Умм аль-Кура, Мекка (18,5°)"
        case .custom: return "Свой угол"
        }
    }

    var fajrAngle: Double? {
        switch self {
        case .dumRF: return 16
        case .dumRT, .mwl: return 18
        case .isna: return 15
        case .egypt: return 19.5
        case .ummAlQura: return 18.5
        case .custom: return nil
        }
    }
}

/// Что делать, когда летом солнце не опускается на нужный угол (Москва, Казань и севернее).
enum HighLatitudeRule: String, Codable, CaseIterable, Identifiable {
    case angleBased, oneSeventh, midNight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .angleBased: return "По доле угла (рекомендуется)"
        case .oneSeventh: return "Седьмая часть ночи"
        case .midNight: return "Середина ночи"
        }
    }
}

struct PrayerSettings: Codable, Equatable {
    var cityID = "moscow"
    var method: PrayerMethod = .dumRF
    var customAngle = 16.0
    var highLatitude: HighLatitudeRule = .angleBased
    /// Поправка в минутах, если местная мечеть публикует время с поправкой.
    var adjustmentMinutes = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cityID = try c.decodeIfPresent(String.self, forKey: .cityID) ?? "moscow"
        method = try c.decodeIfPresent(PrayerMethod.self, forKey: .method) ?? .dumRF
        customAngle = try c.decodeIfPresent(Double.self, forKey: .customAngle) ?? 16
        highLatitude = try c.decodeIfPresent(HighLatitudeRule.self, forKey: .highLatitude) ?? .angleBased
        adjustmentMinutes = try c.decodeIfPresent(Int.self, forKey: .adjustmentMinutes) ?? 0
    }

    var fajrAngle: Double { method.fajrAngle ?? min(max(customAngle, 10), 20) }
    var city: City { City.byID(cityID) ?? City.moscow }
}

struct PrayerDay: Equatable {
    var fajr: Date?
    var sunrise: Date?
    var sunset: Date?
    /// Фаджр посчитан по правилу высоких широт.
    var fajrAdjusted = false
}

/// Астрономический расчёт времени Фаджра, восхода и заката.
/// Формулы те же, что в известной методике PrayTimes; результат сверен с библиотекой astral (расхождение до минуты).
enum PrayerTimes {
    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    private static func fix(_ a: Double, _ b: Double) -> Double {
        let v = a - b * floor(a / b)
        return v < 0 ? v + b : v
    }

    private static func julian(year: Int, month: Int, day: Int) -> Double {
        var y = Double(year), m = Double(month)
        if m <= 2 {
            y -= 1
            m += 12
        }
        let a = floor(y / 100)
        let b = 2 - a + floor(a / 4)
        return floor(365.25 * (y + 4716)) + floor(30.6001 * (m + 1)) + Double(day) + b - 1524.5
    }

    /// Склонение солнца и уравнение времени.
    private static func sunPosition(_ jd: Double) -> (declination: Double, equation: Double) {
        let d = jd - 2451545.0
        let g = fix(357.529 + 0.98560028 * d, 360)
        let q = fix(280.459 + 0.98564736 * d, 360)
        let l = fix(q + 1.915 * sin(rad(g)) + 0.020 * sin(rad(2 * g)), 360)
        let e = 23.439 - 0.00000036 * d
        let ra = fix(deg(atan2(cos(rad(e)) * sin(rad(l)), cos(rad(l)))) / 15, 24)
        let equation = q / 15 - ra
        let declination = deg(asin(sin(rad(e)) * sin(rad(l))))
        return (declination, equation)
    }

    static func day(for date: Date, settings: PrayerSettings) -> PrayerDay {
        let city = settings.city
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var result = compute(
            year: parts.year!, month: parts.month!, day: parts.day!,
            latitude: city.latitude, longitude: city.longitude, timeZone: city.timeZone,
            fajrAngle: settings.fajrAngle, highLatitude: settings.highLatitude
        )
        if let fajr = result.fajr, settings.adjustmentMinutes != 0 {
            result.fajr = fajr.addingTimeInterval(Double(settings.adjustmentMinutes) * 60)
        }
        return result
    }

    static func compute(
        year: Int, month: Int, day: Int,
        latitude: Double, longitude: Double, timeZone: TimeZone,
        fajrAngle: Double, highLatitude: HighLatitudeRule
    ) -> PrayerDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return PrayerDay()
        }
        let noonDate = dayStart.addingTimeInterval(12 * 3600)
        let zoneHours = Double(timeZone.secondsFromGMT(for: noonDate)) / 3600
        let jd = julian(year: year, month: month, day: day) - longitude / (15 * 24)

        func midDay(_ t: Double) -> Double { fix(12 - sunPosition(jd + t).equation, 24) }

        func sunAngleTime(_ angle: Double, _ t: Double, counterClockwise: Bool) -> Double? {
            let declination = sunPosition(jd + t).declination
            let noon = midDay(t)
            let cosT = (-sin(rad(angle)) - sin(rad(declination)) * sin(rad(latitude)))
                / (cos(rad(declination)) * cos(rad(latitude)))
            guard abs(cosT) <= 1 else { return nil }
            let hours = deg(acos(cosT)) / 15
            return counterClockwise ? noon - hours : noon + hours
        }

        // Два приближения: положение солнца берётся на момент искомого события.
        var fajrGuess = 5.0, sunriseGuess = 6.0, sunsetGuess = 18.0
        var fajr: Double?
        var sunrise: Double?
        var sunset: Double?
        for _ in 0..<2 {
            fajr = sunAngleTime(fajrAngle, fajrGuess / 24, counterClockwise: true)
            sunrise = sunAngleTime(0.833, sunriseGuess / 24, counterClockwise: true)
            sunset = sunAngleTime(0.833, sunsetGuess / 24, counterClockwise: false)
            fajrGuess = fajr ?? fajrGuess
            sunriseGuess = sunrise ?? sunriseGuess
            sunsetGuess = sunset ?? sunsetGuess
        }

        func local(_ value: Double?) -> Double? { value.map { $0 + zoneHours - longitude / 15 } }
        var fajrLocal = local(fajr)
        let sunriseLocal = local(sunrise)
        let sunsetLocal = local(sunset)

        // Полярный день или ночь: восхода нет, считать Фаджр не от чего.
        guard let rise = sunriseLocal, let set = sunsetLocal else {
            return PrayerDay(fajr: nil, sunrise: nil, sunset: nil, fajrAdjusted: false)
        }

        var adjusted = false
        let night = 24 - (set - rise)
        let portion: Double
        switch highLatitude {
        case .angleBased: portion = fajrAngle / 60 * night
        case .oneSeventh: portion = night / 7
        case .midNight: portion = night / 2
        }
        if let value = fajrLocal, rise - value <= portion {
            // Обычный случай: солнце опускается на нужный угол, поправка не нужна.
        } else {
            fajrLocal = rise - portion
            adjusted = true
        }

        func toDate(_ hours: Double) -> Date { dayStart.addingTimeInterval(hours * 3600) }
        return PrayerDay(
            fajr: fajrLocal.map(toDate),
            sunrise: toDate(rise),
            sunset: toDate(set),
            fajrAdjusted: adjusted
        )
    }
}
