import Foundation

/// 특정 시간 간격에 대한 상수
struct TimeConstants {
    // 하루에 해당하는 초(second) 수, 즉 대략 86,400초.
    static let secondsInOneDay = 86_400
}

/// 스토리지에서 사용되는 만료(expiration) 전략
public enum StorageExpiration: Sendable {
    
    /// 항목이 절대 만료되지 않음
    case never
    
    /// 현재 시점으로부터 지정된 초(seconds) 이후에 항목이 만료
    case seconds(TimeInterval)
    
    /// 현재 시점으로부터 지정된 일(days) 수 이후에 항목이 만료
    case days(Int)
    
    /// 지정된 날짜(Date)에 항목이 만료
    case date(Date)
    
    /// 항목이 이미 만료되었음을 나타냅니다.
    ///
    /// 캐시를 우회(bypass)하고 싶을 때 사용합니다.
    case expired

    /// 주어진 기준 날짜를 기준으로 예상 만료 시점을 계산
    func estimatedExpirationSince(_ date: Date) -> Date {
        switch self {
        case .never:
            // https://developer.apple.com/documentation/foundation/date/distantfuture
            return .distantFuture
        case .seconds(let seconds):
            return date.addingTimeInterval(seconds)
        case .days(let days):
            let duration: TimeInterval = TimeInterval(TimeConstants.secondsInOneDay * days)
            return date.addingTimeInterval(duration)
        case .date(let ref):
            return ref
        case .expired:
            return .distantPast
        }
    }
    
    /// 현재 시점을 기준으로 한 예상 만료 시점
    var estimatedExpirationSinceNow: Date {
        estimatedExpirationSince(Date())
    }
    
    /// 현재 시점에서 이미 만료되었는지
    var isExpired: Bool {
        timeInterval <= 0
    }

    /// 현재 시점 기준으로 남아 있는 만료까지의 시간 간격을 반환
    var timeInterval: TimeInterval {
        switch self {
        case .never: return .infinity
        case .seconds(let seconds): return seconds
        case .days(let days): return TimeInterval(TimeConstants.secondsInOneDay * days)
        case .date(let ref): return ref.timeIntervalSinceNow
        case .expired: return -(.infinity)
        }
    }
}

/// 스토리지에서 접근(access) 이후에 사용되는 만료 연장(expiration extending) 전략
public enum ExpirationExtending: Sendable {
    /// 접근 이후에도 만료 시간이 연장되지 않습니다.
    case none
    /// 매 접근 시마다 원래의 캐시 시간(cache time) 기준으로 만료 시간이 연장
    case cacheTime
    /// 매 접근 시마다 지정된 만료 시간만큼 만료 시간이 연장
    case expirationTime(_ expiration: StorageExpiration)
}

/// 메모리 비용(cost)을 계산할 수 있는 타입
public protocol CacheCostCalculable {
    var cacheCost: Int { get }
}

/// `Data` 타입으로 변환 가능하며, 다시 복원할 수 있는 타입
public protocol DataTransformable {
    
    /// 현재 값을 `Data` 형태로 변환합니다.
    /// - Returns: 해당 타입의 값을 표현할 수 있는 `Data` 객체
    /// - Throws: 변환 과정 중 오류가 발생한 경우
    func toData() throws -> Data
    
    /// `Data`를 해당 타입의 값으로 변환합니다.
    /// - Parameter data: 해당 타입의 값을 표현하는 `Data` 객체
    /// - Returns: 변환된 타입의 값
    /// - Throws: 변환 과정 중 오류가 발생한 경우
    static func fromData(_ data: Data) throws -> Self
    
    /// `Self` 타입의 빈(empty) 객체입니다.
    ///
    /// > 캐시에서 실제 데이터가 아직 로드되지 않은 경우,
    /// > 이 값이 플레이스홀더로 반환됩니다.
    /// > 이 프로퍼티는 무거운 연산 없이 매우 빠르게 반환되어야 합니다.
    static var empty: Self { get }
}
