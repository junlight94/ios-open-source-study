import Foundation

/// 특정 타입의 값을 메모리에 저장하는 스토리지와 관련된 개념들을 나타냅니다.
///
/// 이는 메모리 스토리지 타입들을 위한 네임스페이스 역할을 합니다.
/// 특정 ``MemoryStorage/Config`` 를 가진 ``MemoryStorage/Backend`` 조합을 통해
/// 실제 스토리지가 정의됩니다.
public enum MemoryStorage {

    /// 특정 타입의 값을 메모리에 저장하는 스토리지를 나타냅니다.
    ///
    /// 빠른 접근 속도를 제공하지만, 저장 용량에는 제한이 있습니다.
    /// 저장되는 값의 타입은 ``CacheCostCalculable`` 프로토콜을 준수해야 하며,
    /// ``CacheCostCalculable/cacheCost`` 값이 메모리에서 해당 캐시 항목의 크기(cost)를
    /// 판단하는 데 사용됩니다.
    ///
    /// ``MemoryStorage/Backend`` 는 생성 시 ``MemoryStorage/Config`` 값을 전달하거나,
    /// 생성 이후 ``MemoryStorage/Backend/config`` 프로퍼티를 수정하여 설정할 수 있습니다.
    ///
    /// ``MemoryStorage`` 백엔드는 메모리에서의 총 cost 크기와 아이템 개수에 대한
    /// 상한선을 가지고 있습니다. 모든 항목은 만료 시간을 가지며,
    /// 조회 시점에 이미 만료된 항목은 스토리지에 존재하지 않는 것처럼 처리됩니다.
    ///
    /// 또한 ``MemoryStorage`` 는 만료된 항목을 메모리에서 제거하기 위한
    /// 주기적인 자체 정리(self-cleaning) 작업을 포함합니다.
    ///
    /// > 이 클래스는 스레드 세이프(thread-safe)합니다.
    public final class Backend<T: CacheCostCalculable>: @unchecked Sendable where T: Sendable {
        
        let storage = NSCache<NSString, StorageObject<T>>()

        // 스토리지에 들어간 객체들의 키를 추적합니다.
        //
        // 사용자가 직접 제거한 객체의 경우, 해당 키도 함께 제거됩니다.
        // 하지만 시스템의 캐시 규칙/정책(totalCostLimit 또는 countLimit)에 의해
        // 제거된 객체의 경우, 다음 `removeExpired` 가 호출되기 전까지 키는 남아 있습니다.
        //
        // 엄격한 키 추적을 일부 포기함으로써 추가적인 락(lock) 사용을 줄이고,
        // 캐시 성능을 개선할 수 있습니다.
        // 참고: https://github.com/onevcat/Kingfisher/issues/1233
        var keys = Set<String>()

        private var cleanTimer: Timer? = nil
        private let lock = NSLock()

        /// 스토리지에서 사용되는 설정 값입니다.
        ///
        /// 스토리지의 동작을 필요에 따라 설정하기 위해 사용하는 값입니다.
        public var config: Config {
            didSet {
                storage.totalCostLimit = config.totalCostLimit
                storage.countLimit = config.countLimit
                cleanTimer?.invalidate()
                cleanTimer = .scheduledTimer(withTimeInterval: config.cleanInterval, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.removeExpired()
                }
            }
        }

        /// 주어진 ``MemoryStorage/Config`` 를 사용하여 ``MemoryStorage/Backend`` 를 생성합니다.
        ///
        /// - Parameter config: 스토리지를 생성하는 데 사용되는 설정 값입니다.
        ///   최대 크기 제한, 기본 만료 설정 등 다양한 동작을 결정합니다.
        public init(config: Config) {
            self.config = config
            storage.totalCostLimit = config.totalCostLimit
            storage.countLimit = config.countLimit

            cleanTimer = .scheduledTimer(withTimeInterval: config.cleanInterval, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.removeExpired()
            }
        }

        /// 스토리지에서 만료된 값들을 제거합니다.
        public func removeExpired() {
            lock.lock()
            defer { lock.unlock() }
            for key in keys {
                let nsKey = key as NSString
                guard let object = storage.object(forKey: nsKey) else {
                    // totalCostLimit 또는 countLimit 규칙에 의해
                    // 객체가 이미 제거된 경우 발생할 수 있습니다.
                    // 추가적인 락 사용을 피하기 위해, 지금까지 키를 제거하지 않았습니다.
                    // 참고: https://github.com/onevcat/Kingfisher/issues/1233
                    keys.remove(key)
                    continue
                }
                if object.isExpired {
                    storage.removeObject(forKey: nsKey)
                    keys.remove(key)
                }
            }
        }
        
        /// 지정된 키와 만료 정책으로 값을 스토리지에 저장합니다.
        ///
        /// - Parameters:
        ///   - value: 저장할 값
        ///   - key: `value` 가 저장될 캐시 키
        ///   - expiration: 이 저장 작업에 사용될 만료 정책
        public func store(
            value: T,
            forKey key: String,
            expiration: StorageExpiration? = nil)
        {
            storeNoThrow(value: value, forKey: key, expiration: expiration)
        }

        // 캐시에 값을 저장하는 throws 없는 버전입니다.
        // Kingfisher는 내부 구현을 알고 있으므로, 내부적으로 더 간단한 문법을 위해 이 버전을 사용합니다.
        // throw 하는 버전이 추후 추가될 가능성 있음.
        func storeNoThrow(
            value: T,
            forKey key: String,
            expiration: StorageExpiration? = nil)
        {
            lock.lock()
            defer { lock.unlock() }
            let expiration = expiration ?? config.expiration
            // 이미 만료된 상태를 의미한다면, 저장할 필요가 없습니다.
            guard !expiration.isExpired else { return }
            
            let object: StorageObject<T>
            if config.keepWhenEnteringBackground {
                object = BackgroundKeepingStorageObject(value, expiration: expiration)
            } else {
                object = StorageObject(value, expiration: expiration)
            }
            storage.setObject(object, forKey: key as NSString, cost: value.cacheCost)
            keys.insert(key)
        }
        
        /// 스토리지에서 값을 가져옵니다.
        ///
        /// - Parameters:
        ///   - key: 값에 대한 캐시 키
        ///   - extendingExpiration: 조회 시 적용할 만료 연장 정책
        /// - Returns: 유효하며 존재하는 경우 해당 값, 그렇지 않으면 `nil`
        public func value(forKey key: String, extendingExpiration: ExpirationExtending = .cacheTime) -> T? {
            guard let object = storage.object(forKey: key as NSString) else {
                return nil
            }
            if object.isExpired {
                return nil
            }
            object.extendExpiration(extendingExpiration)
            return object.value
        }

        /// 지정된 키에 대해 유효한 캐시 데이터가 존재하는지 확인합니다.
        ///
        /// - Parameter key: 값에 대한 캐시 키
        /// - Returns: 유효한 데이터가 있으면 `true`, 그렇지 않으면 `false`
        public func isCached(forKey key: String) -> Bool {
            guard let _ = value(forKey: key, extendingExpiration: .none) else {
                return false
            }
            return true
        }

        /// 지정된 키에 해당하는 값을 제거합니다.
        ///
        /// - Parameter key: 제거할 값의 캐시 키
        public func remove(forKey key: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.removeObject(forKey: key as NSString)
            keys.remove(key)
        }

        /// 스토리지에 저장된 모든 값을 제거합니다.
        public func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAllObjects()
            keys.removeAll()
        }
    }
}

extension MemoryStorage {
    /// ``MemoryStorage/Backend`` 에서 사용되는 설정을 나타냅니다.
    public struct Config {

        /// 스토리지의 총 cost 제한 값입니다.
        ///
        /// ``CacheCostCalculable/cacheCost`` 값들을 누적하여 계산합니다.
        /// 새 객체를 추가함으로써 총 cost 가 totalCostLimit 을 초과하면,
        /// 캐시는 자동으로 객체를 제거하여 총 cost 를 제한 이하로 유지할 수 있습니다.
        public var totalCostLimit: Int

        /// 메모리 스토리지의 아이템 개수 제한입니다.
        ///
        /// 기본값은 `Int.max` 이며, 이는 아이템 개수에 대한 제한이 없음을 의미합니다.
        public var countLimit: Int = .max

        /// 이 메모리 스토리지에서 사용되는 ``StorageExpiration`` 값입니다.
        ///
        /// 기본값은 `.seconds(300)` 으로,
        /// 접근되지 않을 경우 메모리 캐시가 5분 후 만료됨을 의미합니다.
        public var expiration: StorageExpiration = .seconds(300)

        /// 만료된 항목을 정리하기 위한 정리 작업 간의 시간 간격입니다.
        public var cleanInterval: TimeInterval
        
        /// 앱이 백그라운드로 진입할 때, 새로 추가된 메모리 캐시 항목을
        /// 제거할지 여부를 결정합니다.
        ///
        /// 기본적으로 메모리 캐시 항목은 앱이 백그라운드로 들어가면
        /// 메모리 사용량을 최소화하기 위해 즉시 제거됩니다.
        /// 이 값을 `true` 로 설정하면, 앱이 포그라운드에 있지 않더라도
        /// 캐시 항목을 유지합니다.
        ///
        /// 기본값은 `false` 입니다.
        /// `true` 로 설정한 이후에 추가된 항목만 영향을 받으며,
        /// 이전에 이미 캐시에 있던 항목들은 여전히 백그라운드 진입 시 제거됩니다.
        public var keepWhenEnteringBackground: Bool = false

        /// 주어진 ``MemoryStorage/Config/totalCostLimit`` 과
        /// ``MemoryStorage/Config/cleanInterval`` 로 설정을 생성합니다.
        ///
        /// - Parameters:
        ///   - totalCostLimit: 바이트 단위의 스토리지 총 cost 제한
        ///   - cleanInterval: 만료된 항목을 정리하는 작업 간의 시간 간격 (기본값은 120초로, 2분마다 자동 정리가 수행됩니다.)
        ///
        /// > 나머지 ``MemoryStorage/Config`` 속성들은 기본값을 사용합니다.
        public init(totalCostLimit: Int, cleanInterval: TimeInterval = 120) {
            self.totalCostLimit = totalCostLimit
            self.cleanInterval = cleanInterval
        }
    }
}

extension MemoryStorage {
    /// 앱이 백그라운드로 진입해도 메모리에 유지되도록 설계된 StorageObject.
    ///
    /// `NSDiscardableContent` 를 구현하여, 시스템이 메모리가 부족하다고 판단하면
    /// 객체의 내용을 안전하게 비울 수 있도록 합니다.
    ///
    /// `NSCache` 는 `NSDiscardableContent` 를 채택한 객체에 대해
    /// 필요 시 `discardContentIfPossible()` 를 호출할 수 있습니다.
    /// https://developer.apple.com/documentation/foundation/nsdiscardablecontent
    class BackgroundKeepingStorageObject<T>: StorageObject<T>, NSDiscardableContent {
        
        /// 현재 콘텐츠에 접근 중인지 여부를 나타냅니다.
        /// 시스템이 객체를 discard 할 수 있는지 판단하는 데 사용됩니다.
        var accessing = true
        
        /// 콘텐츠 접근을 시작할 때 호출됩니다.
        /// 콘텐츠가 아직 존재하면 접근 가능 상태로 표시합니다.
        func beginContentAccess() -> Bool {
            if value != nil {
                accessing = true
            } else {
                accessing = false
            }
            return accessing
        }
        
        /// 콘텐츠 접근이 끝났음을 시스템에 알립니다.
        func endContentAccess() {
            accessing = false
        }
        
        /// 시스템이 메모리 회수를 시도할 때 호출됩니다.
        /// 실제 값(`value`)을 nil 로 만들어 메모리를 해제합니다.
        func discardContentIfPossible() {
            value = nil
        }
        
        /// 콘텐츠가 이미 discard 되었는지 여부를 반환합니다.
        func isContentDiscarded() -> Bool {
            return value == nil
        }
    }
    
    /// 메모리 캐시에 저장되는 실제 객체를 감싸는 래퍼(wrapper) 타입입니다.
    ///
    /// 값 자체와 함께 만료 정책 및 계산된 만료 시점을 보관합니다.
    class StorageObject<T> {
        /// 실제로 캐시되는 값입니다.
        /// `NSDiscardableContent` 에 의해 nil 이 될 수 있습니다.
        var value: T?
        
        /// 이 객체에 적용되는 만료 정책입니다.
        let expiration: StorageExpiration
        
        /// 계산된 만료 시점입니다.
        /// 접근 시 만료 연장 정책에 따라 갱신될 수 있습니다.
        private(set) var estimatedExpiration: Date
        
        /// 새로운 StorageObject 를 생성하고,
        /// 현재 시점을 기준으로 만료 시점을 계산합니다.
        init(_ value: T, expiration: StorageExpiration) {
            self.value = value
            self.expiration = expiration
            
            self.estimatedExpiration = expiration.estimatedExpirationSinceNow
        }

        /// 접근 이후 적용할 만료 연장 정책에 따라
        /// 만료 시점을 갱신합니다.
        func extendExpiration(_ extendingExpiration: ExpirationExtending = .cacheTime) {
            switch extendingExpiration {
            case .none:
                return
            case .cacheTime:
                self.estimatedExpiration = expiration.estimatedExpirationSinceNow
            case .expirationTime(let expirationTime):
                self.estimatedExpiration = expirationTime.estimatedExpirationSinceNow
            }
        }
        
        /// 현재 객체가 만료되었는지를 나타냅니다.
        var isExpired: Bool {
            return estimatedExpiration.isPast
        }
    }
}
