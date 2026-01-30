## StorageExpiration

> 캐시/스토리지 항목의 만료 정책을 명확하게 표현하기 위한 enum
> 

메모리, 디스크 Storage에서 만료 정책을 표현하기 위해서 사용됩니다.

또한 `extendingExpiration` 로직에서 현재 만료 정책을 검사한 뒤, 해당 기간만큼 만료 시점을 다시 연장하는 데 사용됩니다.

```swift
public enum StorageExpiration: Sendable {
    /// 영구 캐시
    /// 명시적으로 삭제, 메모리에서 자동으로 내리지 않는 한 만료되지 않음
    case never
    
    /// 현재 시점 기준 N초 후 만료
    /// 가장 정밀한 TTL이며 짧은 생명주기의 데이터에 적합
    case seconds(TimeInterval)
    
    /// 현재 시점 기준 N일 후 만료
    case days(Int)
    
    /// 특정 시점에 정확히 만료
    case date(Date)
    
    /// 이미 만료된 상태
    ///
    /// 캐시를 사용하지 않고 항상 우회(bypass)하도록 하기 위해 사용합니다.
    case expired
}

```

<br>

### estimatedExpirationSince

> 특정 일자 기준으로 예상 만료일을 확인하는 메서드
> 

`estimatedExpirationSinceNow` 를 일반적으로 사용해서 현재 시간 기준으로 데이터가 언제 만료되는지 체크하기 위해서 사용

```swift
  func estimatedExpirationSince(_ date: Date) -> Date {
      switch self {
      case .never: 
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
```

<br>

### estimatedExpirationSinceNow

> 현재 Date 기준으로 예상 만료일을 확인하는 메서드
> 

```swift
var estimatedExpirationSinceNow: Date {
    estimatedExpirationSince(Date())
}
```

### isExpired

> 값이 저장될때 음수(과거)이면 저장하지 않기 위해서 만들어진 플래그
> 

값이 저장되는 순간에 정책이 있고, 그게 사용자가 의도적으로 캐싱하지 않기 위해서 과거 값으로 세팅했다면 store 부분에서 값을 저장하지 않고 early return 시키기 위한 용도로 파악됨.

- 미래 → 양수
- 지금/과거 → 0 또는 음수

```swift
var isExpired: Bool {
    timeInterval <= 0
}
```

<br>

### timeInterval

```swift
var timeInterval: TimeInterval {
    switch self {
    case .never: return .infinity
    case .seconds(let seconds): return seconds
    case .days(let days): return TimeInterval(TimeConstants.secondsInOneDay * days)
    case .date(let ref): return ref.timeIntervalSinceNow
    case .expired: return -(.infinity)
    }
}
```

<br>

## ExpirationExtending

> 스토리지 항목에 접근할 때 만료 시간을 어떻게 연장할지 정의하는 정책
> 

```swift
/// 스토리지에서 접근(access) 이후에 사용되는 만료 연장(expiration extending) 전략
public enum ExpirationExtending: Sendable {
    /// 접근 이후에도 만료 시간이 연장되지 않습니다.
    case none
    /// 매 접근 시마다 원래의 캐시 시간(cache time) 기준으로 만료 시간이 연장
    case cacheTime
    /// 매 접근 시마다 지정된 만료 시간만큼 만료 시간이 연장
    case expirationTime(_ expiration: StorageExpiration)
}
```

<br>

## CacheCostCalculable

> 메모리 캐시에서 객체의 비용을 계산해 eviction 판단에 활용하기 위한 타입
> 

`setObject`에서 cacheCost를 함께 저장하고 `NSCache`가 메모리 압박을 받을때 우선순위에 따라 자동으로 정리하기 위해서.

```swift
/// 메모리 비용(cost)을 계산할 수 있는 타입
public protocol CacheCostCalculable {
    var cacheCost: Int { get }
}
```

<br>

## DataTransformable

> 디스크 스토리지에 저장·복원할 수 있도록 `Data`로 직렬화 가능한 타입을 정의하는 프로토콜
> 

`empty`는 **디스크에 유효한 캐시가 존재하지만** 

**실제 데이터 로딩은 생략할 때 반환되는 가벼운 플레이스홀더**입니다.

DiskStorage(line: 276)

```swift
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
```
