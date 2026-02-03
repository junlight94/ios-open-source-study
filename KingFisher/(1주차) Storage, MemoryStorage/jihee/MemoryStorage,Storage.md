## MemoryStorage.swift

- 메모리에 특정 유형의 값을 저장하는 네임스페이스 역할
- Backend / Config을 조합하여 실제 저장소 구성
    - Backend의 init에서 Config 설정하여 초기화

### Backend<T: CacheCostCalculable>

- 메모리에 값을 실제로 저장하는 클래스

**특징**

- 빠른 접근 속도, 하지만 제한된 저장 공간
- 저장되는 타입은 `CacheCostCalculable` 프로토콜을 준수
- `cacheCost`로 메모리 비용 계산
- 총 비용(cost)과 아이템 개수에 상한선이 있음
- 모든 아이템에 만료 시간이 있고, 만료된 아이템은 존재하지 않는 것으로 처리
- 주기적으로 만료된 아이템을 자동으로 제거하는 스케줄러 포함
- **Thread-safe** 보장

**주요 프로퍼티**

- storage
- keys
    - `storage` 안에서 물체를 한 번 추적
    - keys는 실제 `storage`(NSCache)와 **완벽하게 동기화되지 않는다 → 성능 최적화**
- config: 저장소 설정
    - totalCostLimit
    - countLimit
- cleanTimer: 만료된 아이템 정리 타이머

**주요 메서드**

- **store (storeNoThrow)**
    
    ```swift
    public func store(
        value: T,
        forKey key: String,
        expiration: StorageExpiration? = nil)
    ```
    
    - 지정된 키로 값을 저장
    - 만료 정책 지정 가능
    - 이미 만료된 경우 저장하지 않음
- **value(forKey:extendingExpiration:)**
    
    ```swift
    public func value(forKey key: String, extendingExpiration: ExpirationExtending = .cacheTime) -> T?
    ```
    
    - 키로 값을 조회
    - 만료된 경우 nil 반환
    - 접근 시 만료 시간 연장 가능
- **removeExpired**
    
    ```swift
    public func removeExpired()
    ```
    
    - 만료된 값들을 제거
    - 락을 사용해 thread-safe 보장
    - NSCache의 자동 제거로 인해 이미 없어진 키도 정리
- remove / removeAll : 특정 키 또는 전체 삭제
    
    ```swift
    public func remove(forKey key: String) 
    ```
    

### Config

메모리 저장소의 설정을 담는 구조체\

**주요 설정:**

- `totalCostLimit`: 총 비용 제한 (바이트 단위)
- `countLimit`: 최대 아이템 개수 (기본값: Int.max)
- `expiration`: 만료 정책 (기본값: 300초/5분)
- `cleanInterval`: 만료 아이템 정리 주기 (기본값: 120초)
- `keepWhenEnteringBackground`: 앱이 백그라운드로 갈 때 캐시 유지 여부 (기본값: false)
    - 메모리 사용량을 최소화하기 위해 앱이 백그라운드로 전환되는 즉시 메모리에 캐시된 항목이 삭제
    
    ```swift
            func storeNoThrow(
                value: T,
                forKey key: String,
                expiration: StorageExpiration? = nil)
            {
    						/// ...
                let object: StorageObject<T>
                if config.keepWhenEnteringBackground {
                    object = BackgroundKeepingStorageObject(value, expiration: expiration) // 저장 시 따로 저장됨
                } else {
                    object = StorageObject(value, expiration: expiration)
                }
            }
    ```
    

### StorageObject 클래스들

**StorageObject<T>**

- 캐시 값을 래핑하고 만료 시간을 관리하는 **기본 컨테이너**
- 단순히 값과 만료 정보를 저장
- 만료 시간 추적 및 연장 가능
- **앱이 백그라운드로 가면** iOS 시스템이 메모리 압박 시 NSCache를 자동으로 비움 → 즉, 백그라운드에서 지워질 수 있음

**BackgroundKeepingStorageObject<T>**

- [`NSDiscardableContent`](https://developer.apple.com/documentation/foundation/nsdiscardablecontent) 프로토콜 구현
- 백그라운드에서도 값을 유지하기 위한 특수 객체. 삭제되어도 백그라운드 복귀 시 빠른 복원
- 메모리 압박 시 시스템이 자동으로 제거할 수 있도록 구현

```swift
    class BackgroundKeepingStorageObject<T>: StorageObject<T>, NSDiscardableContent {
        // 항상 사용 중에서 시작
        // accessing == true이면 NSCache가 절대 제거하지 않음
        // NSCache가 제거 고려 시 항상 사용중으로 보이기 때문에 자동으로 제거하지 않음
        // 결과적으로 앱이 백그라운드에서도 실제 값이 유지됨
        var accessing = true
        
        // MARK: Content 접근
        
        // 지금 사용 중인지?
        func beginContentAccess() -> Bool {
            if value != nil {
                accessing = true // 사용 가능
            } else {
                accessing = false // 사용 불가, 이미 삭제됨
            }
            return accessing
        }
        
        // 사용이 끝남
        /// 객체 사용이 끝남, 시스템이 필요 시 제거 가능 (메모리 압박 ..)
        /// 객체 사용 이후 자동 호출 X
        func endContentAccess() {
            accessing = false
        }
        
        
        // MARK: Content 제거
        
        // 값 제거
        /// 시스템 메모리가 부족할 때 호출
        func discardContentIfPossible() {
            value = nil
        }
        
        // 값이 제거됐는지?
        func isContentDiscarded() -> Bool {
            return value == nil
        }
    }
```

**동작 시나리오 비교**

1. 앱이 백그라운드로 이동
    - StorageObject 사용 시
        - 시스템에서 메모리 부족 시 NSCache 삭제 → 캐시된 이미지 사라짐, 포어그라운드로 돌아오며 다시 다운로드
    - BackgroundKeepingStorageObject 사용 시
        - 시스템이 메모리 부족 시 `beginContentAccess` 호출 → `discardContentIfPossible` 호출 → NSCache가 자동 제거를 **회피**함, 백그라운드에서도 값 유지

## 성능 최적화를 위한 키 삭제 정책

- [성능 최적화를 위해 즉시 동기화하지 않고 느슨한 일관성(relaxed consistency)을 허용](https://github.com/onevcat/Kingfisher/issues/1233)
    - 사용자가 직접 제거 : `storage`와 `keys` 둘 다 즉시 제거됨
    - 시스템이 자동으로 제거 :  `storage`에서는 사라졌지만, `keys`에는 **아직 남아있음. 타이머에 의해** `removeExpired()`가 호출될 때 정리.
        - NSCache 자체에 totalCountLimit나 countLimit을 걸어둔 경우 NSCache 내의 객체는 자동 삭제됨
- NSCache가 객체를 제거할 때마다 `keys`도 즉시 동기화하려면:
    - NSCache의 delegate 메서드 내에 매번 추가 락(lock)을 걸어야 함 → 재귀 락은 성능에 좋지 않음
    
    ```swift
                 storage.countLimit = config.countLimit
                 storage.delegate = cacheDelegate
                 cacheDelegate.onObjectRemoved.delegate(on: self) { (self, obj) in
    +                self.lock.lock()
    +                defer { self.lock.unlock() }
                     self.keys.remove(obj.key)
                 }
    ```
    
    - lock을 걸지 않는 이유
        - eviction 콜백은 예측 불가능한 타이밍/스레드
            - 시스템 메뢰 압박 상황이 더 자주 올 수 있고 앱에서 스크롤이나 렌더링이 겹치면 악영향
        - lock 경쟁 증가 가능
            - 캐시는 read/write가 잦음
            - eviction까지 락 경쟁에 들어오면 최악의 경우 성능 서하
        - 캐시 성격상 strict stnc가 필수가 아님
            - 캐시는 언제든 없어질 수 있음
            - keys는 정리 / 관리용 보조 인덱스
            - strict consistency보다 eventual consistency가 합리적
    - **느슨한 일관성을 허용**하므로써 **락 오버헤드가 줄어들어 캐시 성능 향상**

## NSDiscardableContent

https://aldo10012.medium.com/nsdiscardablecontent-protocol-in-swift-complete-guide-af012716fb6a

> NSDiscardableContent 객체의 생명 주기는 "카운터" 변수에 따라 결정됩니다. NSDiscardableContent은 다른 객체가 현재 사용하고 있는지 여부를 추적하는, 삭제 가능한 메모리 블록입니다.  메모리가 읽히고 있거나 여전히 필요할 때는 카운터 변수가 1보다 크거나 같습니다. 사용되지 않고 버릴 수 있을 때는 카운터 변수가 0이 됩니다.

기본적으로 객체는 메모리 관리 시스템에 의해 즉시 폐기되지 않도록 카운터가 1로 초기화됩니다. 따라서 이후에는 카운터 변수의 상태를 지속적으로 추적해야 합니다. `beginContentAccess` 메서드를 호출하면 카운터 변수가 1씩 증가하여 객체가 폐기되지 않도록 합니다. 객체가 더 이상 필요하지 않을 때는 `endContentAccess` 메서드를 호출하여 카운터를 1씩 감소시킵니다
> 
- 메모리 집약적인 콘텐츠를 버리고 필요할 때 해당 콘텐츠를 다시 생성할 수 있는 객체를 위한 프로토콜
- iOS 시스템이 메모리 압박 시 데이터 삭제 여부를 물어보는 역할
- 가장 큰 강점 : 메모리 최적화.
    - 용량이 큰 콘텐츠는 버리고 용량이 작은 래퍼는 유지 → 더 많은 항목을 캐시에 저장할 수 있음

### MemoryStorage에서 NSLock이 필요한 이유

- NSLock의 역할
    - Set 타입인 keys를 thread safe하게 사용하기 위해
        - NSCache는 thread-safe하지만, keys는 Set<String>으로 thread-safe하지 않음. 동시 접근 시 크래시 또는 데이터 손상 가능
    - 복합 연산의 원자성(Atomicity)
        - removeExpired() 실행 중에 다른 스레드에서 키를 제거할 경우 순회 중인 Set이 변경되면서 크래시나 예측 불가한 동작 발생 가능
        
        ```swift
        public func removeExpired() {
            lock.lock() // 다른 스레드에서 접근할 수 없도록 막는 역할
            defer { lock.unlock() }
            
            for key in keys {  // ① keys 읽기
                let nsKey = key as NSString
                guard let object = storage.object(forKey: nsKey) else {  // ② storage 읽기
                    keys.remove(key)  // ③ keys 수정
                    continue
                }
                if object.isExpired {
                    storage.removeObject(forKey: nsKey)  // ④ storage 수정
                    keys.remove(key)  // ⑤ keys 수정
                }
            }
        }
        ```
        
    - 데이터 정합성(Consistency)
        - 아래 연산이 원자적으로 실행되지 않는다면 데이터 정합성 문제 발생
        
        ```swift
        func storeNoThrow(value: T, forKey key: String, expiration: StorageExpiration? = nil) {
            lock.lock()
            defer { lock.unlock() }
            
            // ① 만료 체크
            guard !expiration.isExpired else { return }
            
            // ② 객체 생성
            let object = StorageObject(value, expiration: expiration)
            
            // ③ storage에 저장
            storage.setObject(object, forKey: key as NSString, cost: value.cacheCost)
            
            // ④ keys에 추가
            keys.insert(key)
            
            // ①~④가 원자적으로 실행되어야 함!
        }
        ```
        

- Actor를 사용해주지 않는 이유?

## Storage.swift

저장소에서 사용되는 만료 전략과 데이터 변환 관련된 타입들 정의

### StorageExpiration (Enum type)

저장소의 만료 전략

케이스

- **`.never`  :** 아이템이 절대 만료되지 않음
- **`.seconds(TimeInterval)` :** 현재 시점부터 제공된 초 단위 시간 후에 만료
- **`.days(Int)`  :** 현재 시점부터 제공된 일수 후에 만료
- **`.date(Date)`  :** 지정된 날짜 이후에 만료
- **`.expired`  :** 아이템이 이미 만료됨. **캐시를 우회(bypass)하기 위해 사용**

주요 메서드/프로퍼티

- **`estimatedExpirationSince(_ date: Date) -> Date`**
    - 특정 날짜를 기준으로 예상 만료 시점 계산
    - `.never` → 먼 미래(`.distantFuture`)
    - `.seconds` → 날짜 + 초
    - `.days` → 날짜 + (일수 × 86,400초)
    - `.date` → 지정된 날짜 그대로
    - `.expired` → 먼 과거(`.distantPast`)
- **`estimatedExpirationSinceNow`**
    - 현재 시점 기준 예상 만료 시점
- **`isExpired`**
    - 만료 여부 확인 (timeInterval <= 0)
- **`timeInterval`**
    - 남은 시간 간격 반환
    - `.never` → 무한대
    - `.expired` → 음수 무한대

### ExpirationExtending (Enum Type)

저장소에서 **접근 후 만료 시간 연장 전략**

- **`.none`**
    - 접근해도 만료 시간 연장하지 않음
    - 원래 시간에 만료됨
- **`.cacheTime`**
    - 각 접근마다 원래 캐시 시간만큼 만료 시간 연장
    - 예: 5분 캐시인데 3분 후 접근하면 → 그 시점부터 다시 5분 연장
- **`.expirationTime(_ expiration: StorageExpiration)`**
    - 각 접근마다 제공된 시간만큼 만료 시간 연장
    - 예: `.expirationTime(.seconds(300))` → 접근할 때마다 5분씩 연장

### CacheCostCalculable (protocol)

- 메모리 비용을 계산할 수 있는 타입
- MemoryStorage에서 `totalCostLimit` 계산에 사용
- 이미지 크기, 데이터 크기 등을 반환하도록 구현

### DataTransformable (protocol)

- 데이터로 변환 가능한 타입 / Disk 저장용

**필수 구현**

**`toData() throws -> Data`**

- 현재 값을 `Data` 표현으로 변환
- 변환 중 에러 발생 시 throw

**`static func fromData(_ data: Data) throws -> Self`**

- 데이터를 해당 타입의 값으로 변환
- 변환 중 에러 발생 시 throw

**`static var empty: Self { get }`**

- `Self`의 빈 객체
- **중요**: 캐시에서 데이터가 실제로 로드되지 않았을 때 **플레이스홀더**로 반환됨
- **빠르게 반환**되어야 하며, 무거운 작업이 포함되면 안 됨

---

❓ Enum 안에 Class를 감싸는 이유? (Namespace 패턴)

- “Caseless Enum 패턴”

장점

- Class 인스턴스화 불가

```swift
// ❌ 이렇게 할 수 없음
let storage = MemoryStorage()  // Error!

// ✅ 이렇게만 사용 가능
let backend = MemoryStorage.Backend<Image>(config: config)
let config = MemoryStorage.Config(totalCostLimit: 1000)
```

- private init을 만들지 않고도 인스턴스 생성
- Enum의 장점
    - case가 없으면 자동으로 인스턴스화 불가
    - private init() 필요없음
    - 의도가 명확함
- 네임 스페이스 역할
    - nameSpace 없다면 → 이름 충돌 가능성 존재
    
    ```swift
    // NameSpace가 없는 경우
    // 이름 충돌 가능성
    public class MemoryStorageBackend<T> { }
    public struct MemoryStorageConfig { }
    public class MemoryStorageObject<T> { }
    
    // 사용
    let backend = MemoryStorageBackend<Image>(config: config)
    
    // namespace
    // 깔끔한 계층 구조
    public enum MemoryStorage {
        public class Backend<T> { }
        public struct Config { }
        class StorageObject<T> { }  // internal
    }
    
    // 사용 - 소속이 명확
    let backend = MemoryStorage.Backend<Image>(config: config)
    let config = MemoryStorage.Config(totalCostLimit: 1000)
    ```
    
    - 코드의 소속감, 깔끔한 네이밍, 가독성

❓ Backend class가 Thread safe하다

- **NSLock은 key를 위한 것 !**
    
    ```swift
    public final class Backend<T>: @unchecked Sendable {
        let storage = NSCache<NSString, StorageObject<T>>()  // Thread-safe
        var keys = Set<String>()  // Thread-safe 아님!
        private let lock = NSLock()
    }
    ```
    
- 왜 Lock이 필요한가?
    - NSCache는 Thread-safe하지만 keys는 아님
    
    ```swift
    // Thread 1
    store(value: image1, forKey: "photo1")
    keys.insert("photo1")  // 삽입
    
    // Thread 2 (동시에)
    store(value: image2, forKey: "photo2")
    keys.insert("photo2")  // 충돌!
    
    // Set은 Thread-safe하지 않음!
    // 동시 접근 시 크래시 또는 데이터 손상 가능
    ```
    
    - Kingfisher 내에서 시간에 따라 삭제하기 위해 key가 필요
    - 복합 연산의 원자성(Atomicity)