import Foundation

/// Город для расчёта Фаджра. Координаты центра, часовой пояс по IANA.
struct City: Identifiable, Hashable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let timeZoneID: String

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    static let moscow = City(id: "moscow", name: "Москва", latitude: 55.7558, longitude: 37.6173, timeZoneID: "Europe/Moscow")

    static let all: [City] = [
        moscow,
        City(id: "spb", name: "Санкт-Петербург", latitude: 59.9343, longitude: 30.3351, timeZoneID: "Europe/Moscow"),
        City(id: "kazan", name: "Казань", latitude: 55.7963, longitude: 49.1088, timeZoneID: "Europe/Moscow"),
        City(id: "chelny", name: "Набережные Челны", latitude: 55.7436, longitude: 52.3958, timeZoneID: "Europe/Moscow"),
        City(id: "almetyevsk", name: "Альметьевск", latitude: 54.9014, longitude: 52.2971, timeZoneID: "Europe/Moscow"),
        City(id: "ufa", name: "Уфа", latitude: 54.7388, longitude: 55.9721, timeZoneID: "Asia/Yekaterinburg"),
        City(id: "grozny", name: "Грозный", latitude: 43.3178, longitude: 45.6949, timeZoneID: "Europe/Moscow"),
        City(id: "makhachkala", name: "Махачкала", latitude: 42.9849, longitude: 47.5047, timeZoneID: "Europe/Moscow"),
        City(id: "derbent", name: "Дербент", latitude: 42.0678, longitude: 48.2899, timeZoneID: "Europe/Moscow"),
        City(id: "khasavyurt", name: "Хасавюрт", latitude: 43.2500, longitude: 46.5833, timeZoneID: "Europe/Moscow"),
        City(id: "nalchik", name: "Нальчик", latitude: 43.4853, longitude: 43.6071, timeZoneID: "Europe/Moscow"),
        City(id: "vladikavkaz", name: "Владикавказ", latitude: 43.0205, longitude: 44.6819, timeZoneID: "Europe/Moscow"),
        City(id: "magas", name: "Магас", latitude: 43.1667, longitude: 44.8000, timeZoneID: "Europe/Moscow"),
        City(id: "cherkessk", name: "Черкесск", latitude: 44.2269, longitude: 42.0468, timeZoneID: "Europe/Moscow"),
        City(id: "maykop", name: "Майкоп", latitude: 44.6098, longitude: 40.1006, timeZoneID: "Europe/Moscow"),
        City(id: "stavropol", name: "Ставрополь", latitude: 45.0448, longitude: 41.9690, timeZoneID: "Europe/Moscow"),
        City(id: "krasnodar", name: "Краснодар", latitude: 45.0355, longitude: 38.9753, timeZoneID: "Europe/Moscow"),
        City(id: "rostov", name: "Ростов-на-Дону", latitude: 47.2357, longitude: 39.7015, timeZoneID: "Europe/Moscow"),
        City(id: "volgograd", name: "Волгоград", latitude: 48.7080, longitude: 44.5133, timeZoneID: "Europe/Volgograd"),
        City(id: "astrakhan", name: "Астрахань", latitude: 46.3497, longitude: 48.0408, timeZoneID: "Europe/Astrakhan"),
        City(id: "saratov", name: "Саратов", latitude: 51.5331, longitude: 46.0342, timeZoneID: "Europe/Saratov"),
        City(id: "samara", name: "Самара", latitude: 53.1959, longitude: 50.1002, timeZoneID: "Europe/Samara"),
        City(id: "ulyanovsk", name: "Ульяновск", latitude: 54.3142, longitude: 48.4031, timeZoneID: "Europe/Ulyanovsk"),
        City(id: "izhevsk", name: "Ижевск", latitude: 56.8526, longitude: 53.2045, timeZoneID: "Europe/Samara"),
        City(id: "penza", name: "Пенза", latitude: 53.1959, longitude: 45.0183, timeZoneID: "Europe/Moscow"),
        City(id: "nnovgorod", name: "Нижний Новгород", latitude: 56.2965, longitude: 43.9361, timeZoneID: "Europe/Moscow"),
        City(id: "voronezh", name: "Воронеж", latitude: 51.6608, longitude: 39.2003, timeZoneID: "Europe/Moscow"),
        City(id: "orenburg", name: "Оренбург", latitude: 51.7682, longitude: 55.0969, timeZoneID: "Asia/Yekaterinburg"),
        City(id: "perm", name: "Пермь", latitude: 58.0105, longitude: 56.2502, timeZoneID: "Asia/Yekaterinburg"),
        City(id: "yekaterinburg", name: "Екатеринбург", latitude: 56.8389, longitude: 60.6057, timeZoneID: "Asia/Yekaterinburg"),
        City(id: "chelyabinsk", name: "Челябинск", latitude: 55.1644, longitude: 61.4368, timeZoneID: "Asia/Yekaterinburg"),
        City(id: "tyumen", name: "Тюмень", latitude: 57.1522, longitude: 65.5272, timeZoneID: "Asia/Yekaterinburg"),
        City(id: "surgut", name: "Сургут", latitude: 61.2540, longitude: 73.3962, timeZoneID: "Asia/Yekaterinburg"),
        City(id: "omsk", name: "Омск", latitude: 54.9885, longitude: 73.3242, timeZoneID: "Asia/Omsk"),
        City(id: "novosibirsk", name: "Новосибирск", latitude: 55.0084, longitude: 82.9357, timeZoneID: "Asia/Novosibirsk"),
        City(id: "krasnoyarsk", name: "Красноярск", latitude: 56.0153, longitude: 92.8932, timeZoneID: "Asia/Krasnoyarsk"),
        City(id: "irkutsk", name: "Иркутск", latitude: 52.2869, longitude: 104.3050, timeZoneID: "Asia/Irkutsk"),
        City(id: "yakutsk", name: "Якутск", latitude: 62.0355, longitude: 129.6755, timeZoneID: "Asia/Yakutsk"),
        City(id: "khabarovsk", name: "Хабаровск", latitude: 48.4802, longitude: 135.0719, timeZoneID: "Asia/Vladivostok"),
        City(id: "vladivostok", name: "Владивосток", latitude: 43.1155, longitude: 131.8855, timeZoneID: "Asia/Vladivostok"),
        City(id: "kaliningrad", name: "Калининград", latitude: 54.7104, longitude: 20.4522, timeZoneID: "Europe/Kaliningrad"),
        City(id: "murmansk", name: "Мурманск", latitude: 68.9585, longitude: 33.0827, timeZoneID: "Europe/Moscow"),
    ].sorted { $0.name < $1.name }

    static func byID(_ id: String) -> City? { all.first { $0.id == id } }
}
