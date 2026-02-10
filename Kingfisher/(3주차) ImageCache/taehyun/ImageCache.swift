//
//  ImageCache.swift
//  Kingfisher
//
//  Created by Wei Wang on 15/4/6.
//
//  Copyright (c) 2019 Wei Wang <onevcat@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Notification 확장

extension Notification.Name {

    /// 디스크 캐시가 자동으로 정리될 때 발송되는 Notification.
    ///
    /// 만료된 캐시 파일이 삭제되거나, 전체 디스크 캐시 크기가 최대 허용 크기를 초과하여 정리가 수행될 때 발송된다.
    ///
    /// - `object`는 해당 Notification을 보낸 `ImageCache` 인스턴스이다.
    /// - `KFCrossPlatformImage`의 `KingfisherDiskCacheCleanedHashKey` 키를 통해 삭제된 파일들의 해시(파일명) 배열에 접근할 수 있다.
    ///
    /// **주의**: `clearDiskCache()` 메서드를 수동으로 호출할 경우에는 이 Notification이 발송되지 않는다.
    /// 오직 자동 정리(만료 기반, 사이즈 초과 기반)에서만 발송된다.
    public static let KingfisherDidCleanDiskCache =
        Notification.Name("com.onevcat.Kingfisher.KingfisherDidCleanDiskCache")
}

/// `KingfisherDidCleanDiskCache` Notification의 `userInfo`에서 삭제된 파일 해시 배열에 접근하기 위한 키.
///
/// 이 키로 `userInfo` 딕셔너리에서 `[String]` 타입의 배열을 꺼낼 수 있으며,
/// 배열의 각 요소는 삭제된 캐시 파일의 파일명(lastPathComponent)이다.
public let KingfisherDiskCacheCleanedHashKey = "com.onevcat.Kingfisher.cleanedHash"

// MARK: - CacheType (캐시 유형 열거형)

/// 캐시된 이미지의 캐시 유형을 나타내는 열거형.
///
/// 이미지가 어디서 가져왔는지(메모리, 디스크, 또는 캐시되지 않음)를 구분한다.
/// 이미지 로딩 파이프라인에서 캐시 히트 여부와 캐시 레이어를 판별하는 데 사용된다.
public enum CacheType: Sendable {
    /// 이미지가 아직 캐시되지 않은 상태.
    ///
    /// 이미지가 최근에 다운로드되거나 새로 생성되었음을 의미하며,
    /// 메모리 캐시나 디스크 캐시 어디에서도 가져오지 않았다는 것을 나타낸다.
    case none

    /// 이미지가 메모리 캐시에 존재하며, 메모리에서 가져왔음을 나타낸다.
    ///
    /// 메모리 캐시는 디스크 캐시보다 훨씬 빠르므로, 이 경우가 가장 성능이 좋다.
    case memory

    /// 이미지가 디스크 캐시에 존재하며, 디스크에서 가져왔음을 나타낸다.
    ///
    /// 디스크에서 데이터를 읽어 이미지로 디코딩하는 과정이 필요하므로 메모리 캐시보다 느리다.
    /// 디스크에서 가져온 이미지는 다음 접근을 위해 메모리 캐시에도 자동으로 저장된다.
    case disk

    /// 현재 캐시 타입이 이미 캐시된 상태인지를 나타내는 Bool 값.
    ///
    /// `.memory`와 `.disk`는 `true`를 반환하고, `.none`은 `false`를 반환한다.
    public var cached: Bool {
        switch self {
        case .memory, .disk: return true
        case .none: return false
        }
    }
}

// MARK: - CacheStoreResult (캐시 저장 결과)

/// 캐시 저장 작업의 결과를 나타내는 구조체.
///
/// 메모리 캐시와 디스크 캐시 각각의 저장 결과를 별도로 담고 있다.
/// 메모리 캐시 저장은 실패하지 않지만(Result<(), Never>), 디스크 캐시 저장은 실패할 수 있다.
public struct CacheStoreResult: Sendable {

    /// 메모리 캐시의 저장 결과.
    ///
    /// 메모리 캐시에 이미지를 저장하는 것은 절대 실패하지 않는다 (타입이 `Result<(), Never>`).
    /// NSCache가 내부적으로 메모리 관리를 수행하므로, 저장 자체는 항상 성공한다.
    public let memoryCacheResult: Result<(), Never>

    /// 디스크 캐시의 저장 결과.
    ///
    /// 디스크 I/O 관련 에러가 발생할 수 있으므로 `KingfisherError`를 에러 타입으로 사용한다.
    /// 직렬화 실패, 파일 쓰기 실패, 디렉토리 생성 실패 등의 이유로 `.failure`가 될 수 있다.
    public let diskCacheResult: Result<(), KingfisherError>
}

// MARK: - KFCrossPlatformImage의 CacheCostCalculable 준수

extension KFCrossPlatformImage: CacheCostCalculable {
    /// 이미지의 캐시 비용(cost).
    ///
    /// 비트맵 기반으로 추정된 크기(바이트 단위)를 나타낸다.
    /// 더 큰 cost는 메모리 캐시에 저장될 때 더 많은 메모리를 차지함을 의미한다.
    /// 이 값은 `MemoryStorage.Config.totalCostLimit`에 기여하며,
    /// NSCache가 내부적으로 이 비용을 기반으로 메모리 제한 초과 시 자동 퇴출(eviction)을 수행한다.
    public var cacheCost: Int { return kf.cost }
}

// MARK: - Data의 DataTransformable 준수

extension Data: DataTransformable {
    /// Data를 그대로 Data로 변환한다 (항등 변환).
    ///
    /// DiskStorage에 저장하기 위해 `DataTransformable` 프로토콜을 준수해야 하는데,
    /// Data 자체는 이미 바이너리 데이터이므로 변환 없이 자기 자신을 반환한다.
    public func toData() throws -> Data {
        self
    }

    /// Data를 그대로 Data로 역변환한다 (항등 변환).
    ///
    /// 디스크에서 읽어온 Data를 다시 Data 타입으로 변환하는 과정으로,
    /// 역시 변환 없이 입력값을 그대로 반환한다.
    public static func fromData(_ data: Data) throws -> Data {
        data
    }

    /// 빈 Data 인스턴스.
    ///
    /// `DataTransformable` 프로토콜의 요구사항으로,
    /// isCached 확인 시 실제 데이터를 로드하지 않고도 "존재한다"를 표현하기 위한 더미 값이다.
    public static let empty = Data()
}


// MARK: - ImageCacheResult (이미지 캐시 조회 결과)

/// 캐시에서 이미지를 조회한 결과를 나타내는 열거형.
///
/// 이미지가 어느 캐시 레이어에서 발견되었는지, 또는 캐시에 없는지를 구분한다.
/// `CacheType`과 유사하지만, 이미지를 연관 값(associated value)으로 직접 포함한다는 차이가 있다.
public enum ImageCacheResult: Sendable {

    /// 이미지가 디스크 캐시에서 발견되어 가져온 경우.
    /// 연관 값으로 디코딩된 이미지를 포함한다.
    case disk(KFCrossPlatformImage)

    /// 이미지가 메모리 캐시에서 발견되어 가져온 경우.
    /// 연관 값으로 메모리에 이미 로드되어 있는 이미지를 포함한다.
    case memory(KFCrossPlatformImage)

    /// 이미지가 캐시에 존재하지 않는 경우.
    case none

    /// 캐시 결과에서 이미지를 추출한다.
    ///
    /// `.disk` 또는 `.memory` 케이스의 경우 연관된 이미지를 반환하고,
    /// `.none`의 경우 `nil`을 반환한다.
    public var image: KFCrossPlatformImage? {
        switch self {
        case .disk(let image): return image
        case .memory(let image): return image
        case .none: return nil
        }
    }

    /// 결과 타입에 대응하는 `CacheType` 값을 반환한다.
    ///
    /// `.disk` → `.disk`, `.memory` → `.memory`, `.none` → `.none`으로 변환된다.
    public var cacheType: CacheType {
        switch self {
        case .disk: return .disk
        case .memory: return .memory
        case .none: return .none
        }
    }
}

// MARK: - ImageCache (이미지 캐시 메인 클래스)

/// 메모리 스토리지(MemoryStorage)와 디스크 스토리지(DiskStorage)로 구성된 하이브리드 캐싱 시스템.
///
/// `ImageCache`는 이미지와 이미지 데이터를 메모리와 디스크에 저장하고 조회하는 고수준 추상화를 제공한다.
/// 메모리 캐시 백엔드와 디스크 캐시 백엔드의 설정을 각각 정의할 수 있으며,
/// 통합된 메서드를 통해 이미지를 저장하거나 메모리/디스크 캐시에서 이미지를 조회할 수 있다.
///
/// `@unchecked Sendable`로 표시되어 있으며, 내부적으로 직렬 큐(ioQueue)와 NSLock을 통해
/// 스레드 안전성을 수동으로 보장한다.
///
/// **주요 설계 포인트:**
/// - 메모리 캐시는 동기적으로 즉시 접근 가능 (NSCache 기반, NSLock으로 보호)
/// - 디스크 캐시는 비동기적으로 ioQueue를 통해 직렬화하여 접근
/// - 디스크에서 읽어온 이미지는 자동으로 메모리 캐시에도 저장 (캐시 워밍)
open class ImageCache: @unchecked Sendable {

    // MARK: Singleton

    public static let `default` = ImageCache(name: "default")

    // MARK: Public Properties

    /// 이 캐시에서 사용하는 메모리 캐시 백엔드 (`MemoryStorage.Backend<KFCrossPlatformImage>`).
    ///
    /// NSCache를 내부적으로 사용하여, 메모리에 로드된 이미지를 적절한 만료 기간과
    /// 최대 메모리 사용량 제한 내에서 저장한다.
    ///
    /// 설정을 변경하려면 `memoryStorage.config`의 프로퍼티를 수정하면 된다.
    /// 예를 들어, `memoryStorage.config.totalCostLimit`으로 최대 메모리 크기를 조정할 수 있다.
    public let memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>

    /// 이 캐시에서 사용하는 디스크 캐시 백엔드 (`DiskStorage.Backend<Data>`).
    ///
    /// 파일 시스템에 이미지 데이터를 바이너리 형태로 저장하며,
    /// 적절한 만료 기간과 최대 디스크 사용량 제한을 적용한다.
    ///
    /// 설정을 변경하려면 `diskStorage.config`의 프로퍼티를 수정하면 된다.
    /// 예를 들어, `diskStorage.config.sizeLimit`으로 최대 디스크 캐시 크기를 조정할 수 있다.
    public let diskStorage: DiskStorage.Backend<Data>

    /// 디스크 I/O 작업을 직렬화하기 위한 전용 DispatchQueue.
    ///
    /// 디스크 캐시에 대한 모든 읽기/쓰기 작업이 이 큐를 통해 순차적으로 실행된다.
    /// 이렇게 함으로써 여러 스레드에서 동시에 디스크에 접근하는 것을 방지하고,
    /// 파일 시스템 레벨의 경쟁 조건(race condition)을 예방한다.
    ///
    /// **왜 NSLock 대신 직렬 큐를 사용하는가:**
    /// - 디스크 I/O는 느린 작업이므로, Lock으로 보호하면 Lock을 잡고 있는 동안
    ///   다른 스레드가 블로킹된다. 직렬 큐를 사용하면 호출자가 즉시 반환되고,
    ///   작업은 큐에 enqueue되어 순차 실행된다.
    /// - 디스크 작업을 백그라운드에서 비동기적으로 실행하여
    ///   메인 스레드의 부하를 줄인다.
    private let ioQueue: DispatchQueue

    /// 디스크 캐시 경로를 커스터마이즈하기 위한 클로저 타입.
    ///
    /// 기본 디렉토리 URL과 캐시 이름을 받아, 최종 디스크 캐시 경로 URL을 반환한다.
    public typealias DiskCachePathClosure = @Sendable (URL, String) -> URL

    // MARK: Initializers

    /// 커스텀 `MemoryStorage`와 `DiskStorage`를 사용하여 `ImageCache`를 생성한다.
    ///
    /// 이 이니셜라이저는 가장 유연한 설정을 제공하는 지정(Designated) 이니셜라이저이다.
    /// 모든 다른 이니셜라이저는 궁극적으로 이 이니셜라이저를 호출한다.
    ///
    /// - Parameters:
    ///   - memoryStorage: 이미지 메모리 캐시에 사용될 `MemoryStorage.Backend` 객체.
    ///   - diskStorage: 이미지 디스크 캐시에 사용될 `DiskStorage.Backend` 객체.
    ///
    /// **내부 동작:**
    /// 1. memoryStorage와 diskStorage를 저장
    /// 2. 고유한 이름을 가진 직렬 DispatchQueue(ioQueue)를 생성
    /// 3. 시스템 알림(Notification) 옵저버를 등록:
    ///    - iOS: 메모리 경고 → 메모리 캐시 전체 삭제
    ///    - iOS: 앱 종료 → 만료된 디스크 캐시 정리
    ///    - iOS: 백그라운드 진입 → 백그라운드 태스크로 만료 디스크 캐시 정리
    ///    - macOS: 앱 비활성화 → 만료된 디스크 캐시 정리
    public init(
        memoryStorage: MemoryStorage.Backend<KFCrossPlatformImage>,
        diskStorage: DiskStorage.Backend<Data>)
    {
        self.memoryStorage = memoryStorage
        self.diskStorage = diskStorage
        // UUID를 포함하여 각 ImageCache 인스턴스마다 고유한 큐 이름을 생성한다.
        // 이렇게 하면 여러 ImageCache 인스턴스가 존재하더라도 각각 독립적인 I/O 큐를 가진다.
        let ioQueueName = "com.onevcat.Kingfisher.ImageCache.ioQueue.\(UUID().uuidString)"
        ioQueue = DispatchQueue(label: ioQueueName)

        // 시스템 알림 옵저버를 메인 스레드에서 등록한다.
        // Task { @MainActor in ... }을 사용하여 메인 액터에서 실행을 보장한다.
        // NotificationCenter의 옵저버 등록은 스레드 안전하지만,
        // UIApplication 관련 알림은 메인 스레드에서 등록하는 것이 관례이다.
        Task { @MainActor in
            let notifications: [(Notification.Name, Selector)]
            #if !os(macOS) && !os(watchOS)
            notifications = [
                // 메모리 경고를 받으면 메모리 캐시를 모두 비운다.
                // 시스템이 메모리 부족 상황일 때 이미지 캐시를 해제하여 메모리 회수에 기여한다.
                (UIApplication.didReceiveMemoryWarningNotification, #selector(clearMemoryCache)),
                // 앱이 종료될 때 만료된 디스크 캐시를 정리한다.
                (UIApplication.willTerminateNotification, #selector(cleanExpiredDiskCache)),
                // 앱이 백그라운드로 진입할 때 백그라운드 태스크를 활용하여
                // 만료된 디스크 캐시를 정리한다 (backgroundCleanExpiredDiskCache 메서드).
                (UIApplication.didEnterBackgroundNotification, #selector(backgroundCleanExpiredDiskCache))
            ]
            #elseif os(macOS)
            notifications = [
                // macOS에서는 앱이 비활성화(resign active)될 때 만료된 디스크 캐시를 정리한다.
                (NSApplication.willResignActiveNotification, #selector(cleanExpiredDiskCache)),
            ]
            #else
            // watchOS 등의 플랫폼에서는 별도의 알림 등록을 하지 않는다.
            notifications = []
            #endif
            notifications.forEach {
                NotificationCenter.default.addObserver(self, selector: $0.1, name: $0.0, object: nil)
            }
        }
    }

    /// 주어진 `name`으로 `ImageCache`를 생성한다.
    ///
    /// `name`을 기반으로 기본 설정의 `MemoryStorage`와 `DiskStorage`가 자동으로 생성된다.
    ///
    /// - Parameter name: 캐시 객체의 이름. 디스크 캐시 디렉토리 구성과 I/O 큐 식별에 사용된다.
    ///   같은 `name`을 가진 서로 다른 캐시를 만들면 디스크 스토리지가 충돌한다.
    ///   빈 문자열은 허용되지 않는다.
    ///
    public convenience init(name: String) {
        self.init(noThrowName: name, cacheDirectoryURL: nil, diskCachePathClosure: nil)
    }

    /// 주어진 `name`, 캐시 디렉토리 경로, 경로 커스터마이즈 클로저를 사용하여 `ImageCache`를 생성한다.
    ///
    /// - Parameters:
    ///   - name: 캐시 객체의 이름. 디스크 캐시 디렉토리 구성과 I/O 큐 식별에 사용된다.
    ///   - cacheDirectoryURL: 디스크 캐시 디렉토리의 위치. `nil`이면 기본 캐시 디렉토리가 사용된다.
    ///   - diskCachePathClosure: 초기 경로를 받아 최종 디스크 캐시 경로를 생성하는 클로저.
    ///     완전히 커스텀한 캐시 경로를 사용하고 싶을 때 활용한다.
    /// - Throws: 디스크 캐시 디렉토리 생성 실패 시 에러를 던진다.
    public convenience init(
        name: String,
        cacheDirectoryURL: URL?,
        diskCachePathClosure: DiskCachePathClosure? = nil
    ) throws
    {
        if name.isEmpty {
            fatalError("[Kingfisher] You should specify a name for the cache. A cache with empty name is not permitted.")
        }

        let memoryStorage = ImageCache.createMemoryStorage()

        let config = ImageCache.createConfig(
            name: name, cacheDirectoryURL: cacheDirectoryURL, diskCachePathClosure: diskCachePathClosure
        )
        let diskStorage = try DiskStorage.Backend<Data>(config: config)
        self.init(memoryStorage: memoryStorage, diskStorage: diskStorage)
    }

    /// 에러를 던지지 않는 내부 이니셜라이저.
    ///
    /// `DiskStorage.Backend`의 `noThrowConfig` 이니셜라이저를 사용하여,
    /// 디렉토리 생성 실패 시에도 크래시하지 않고 graceful하게 처리한다.
    /// 주로 `ImageCache.default` 싱글턴 생성이나 `init(name:)` 편의 이니셜라이저에서 사용된다.
    convenience init(
        noThrowName name: String,
        cacheDirectoryURL: URL?,
        diskCachePathClosure: DiskCachePathClosure?
    )
    {
        if name.isEmpty {
            fatalError("[Kingfisher] You should specify a name for the cache. A cache with empty name is not permitted.")
        }

        let memoryStorage = ImageCache.createMemoryStorage()

        let config = ImageCache.createConfig(
            name: name, cacheDirectoryURL: cacheDirectoryURL, diskCachePathClosure: diskCachePathClosure
        )
        // creatingDirectory: true로 설정하여, try?로 디렉토리 생성을 시도한다.
        // 실패하더라도 크래시하지 않으며, 이후 실제 파일 쓰기 시 다시 시도한다.
        let diskStorage = DiskStorage.Backend<Data>(noThrowConfig: config, creatingDirectory: true)
        self.init(memoryStorage: memoryStorage, diskStorage: diskStorage)
    }

    /// 메모리 스토리지를 생성하는 정적 팩토리 메서드.
    ///
    /// 디바이스의 물리적 메모리의 1/4을 메모리 캐시의 최대 비용 제한(costLimit)으로 설정한다.
    /// 예를 들어, 4GB RAM 디바이스에서는 1GB가 최대 제한이 된다.
    ///
    /// `Int.max`를 초과하는 경우를 방어하기 위한 안전 검사도 포함되어 있다.
    /// (64비트 시스템에서는 실질적으로 해당되지 않지만, 32비트 호환성을 위해 존재)
    private static func createMemoryStorage() -> MemoryStorage.Backend<KFCrossPlatformImage> {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let costLimit = totalMemory / 4
        let memoryStorage = MemoryStorage.Backend<KFCrossPlatformImage>(config:
            .init(totalCostLimit: (costLimit > Int.max) ? Int.max : Int(costLimit)))
        return memoryStorage
    }

    /// 디스크 스토리지 설정(Config)을 생성하는 정적 팩토리 메서드.
    ///
    /// - Parameters:
    ///   - name: 캐시 이름
    ///   - cacheDirectoryURL: 캐시 디렉토리 URL (nil이면 기본 위치 사용)
    ///   - diskCachePathClosure: 디스크 캐시 경로 커스터마이즈 클로저
    /// - Returns: 구성된 `DiskStorage.Config`
    ///
    /// `sizeLimit: 0`으로 설정되어 있어 기본적으로 디스크 캐시 크기 제한이 없다.
    /// 필요하면 나중에 `diskStorage.config.sizeLimit`을 변경할 수 있다.
    private static func createConfig(
        name: String,
        cacheDirectoryURL: URL?,
        diskCachePathClosure: DiskCachePathClosure? = nil
    ) -> DiskStorage.Config
    {
        var diskConfig = DiskStorage.Config(
            name: name,
            sizeLimit: 0,
            directory: cacheDirectoryURL
        )
        if let closure = diskCachePathClosure {
            diskConfig.cachePathBlock = closure
        }
        return diskConfig
    }

    /// ImageCache가 메모리에서 해제될 때 NotificationCenter 옵저버를 해제한다.
    ///
    /// 이니셜라이저에서 등록한 시스템 알림 옵저버(메모리 경고, 앱 종료, 백그라운드 진입 등)를
    /// 모두 제거하여 메모리 누수를 방지한다.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Storing Images (이미지 저장)

    /// 이미지를 캐시에 저장한다 (KingfisherParsedOptionsInfo 기반).
    ///
    /// 이 메서드는 Kingfisher 내부에서 주로 호출되는 핵심 저장 메서드이다.
    ///
    /// **동작 흐름:**
    /// 1. 프로세서 식별자를 결합하여 계산된 캐시 키(computedKey)를 생성한다.
    /// 2. 메모리 캐시에 동기적으로 즉시 저장한다 (`storeNoThrow`).
    /// 3. `toDisk`가 `false`면 여기서 완료하고 콜백을 호출한다.
    /// 4. `toDisk`가 `true`면, ioQueue에서 비동기적으로:
    ///    - 이미지를 `CacheSerializer`로 직렬화(data로 변환)
    ///    - 직렬화된 데이터를 디스크에 저장
    ///    - 완료 콜백 호출
    ///
    /// - Parameters:
    ///   - image: 저장할 이미지.
    ///   - original: 원본 이미지 데이터. 직렬화 시 이미지 포맷을 결정하는 데 사용된다.
    ///   - key: 캐싱에 사용되는 키 (보통 URL 문자열).
    ///   - options: 캐싱 설정을 포함하는 옵션 정보.
    ///   - toDisk: 디스크에도 저장할지 여부. 기본값은 `true`.
    ///   - completionHandler: 캐시 저장 완료 시 호출되는 클로저.
    open func store(
        _ image: KFCrossPlatformImage,
        original: Data? = nil,
        forKey key: String,
        options: KingfisherParsedOptionsInfo,
        toDisk: Bool = true,
        completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil
    )
    {
        let identifier = options.processor.identifier
        let callbackQueue = options.callbackQueue

        // 프로세서 식별자를 키에 결합하여 최종 캐시 키를 생성한다.
        // 예: "https://example.com/image.png" + "@ResizingProcessor" → "https://example.com/image.png@ResizingProcessor"
        // 같은 이미지라도 다른 프로세서로 처리하면 다른 캐시 키를 가진다.
        let computedKey = key.computedKey(with: identifier)

        // 메모리 캐시에 저장 (동기적, NSLock으로 보호됨, 절대 실패하지 않음).
        // 메모리 캐시는 접근이 빈번하고 빨라야 하므로 즉시 동기적으로 처리한다.
        memoryStorage.storeNoThrow(value: image, forKey: computedKey, expiration: options.memoryCacheExpiration)

        // 디스크 저장이 필요 없으면 즉시 성공 결과를 반환한다.
        guard toDisk else {
            if let completionHandler = completionHandler {
                let result = CacheStoreResult(memoryCacheResult: .success(()), diskCacheResult: .success(()))
                callbackQueue.execute { completionHandler(result) }
            }
            return
        }

        // 디스크 저장은 ioQueue에서 비동기적으로 수행한다.
        // ioQueue는 직렬(serial) 큐이므로, 디스크 I/O 작업들이 순차적으로 실행된다.
        // 이렇게 하면:
        // 1. 호출자(보통 메인 스레드)가 블로킹되지 않는다.
        // 2. 동시에 여러 디스크 쓰기가 발생해도 파일 충돌이 없다.
        ioQueue.async {
            let serializer = options.cacheSerializer
            // 이미지를 바이너리 데이터로 직렬화한다.
            // CacheSerializer가 이미지 포맷(PNG, JPEG 등)을 결정하여 Data로 변환한다.
            if let data = serializer.data(with: image, original: original) {
                self.syncStoreToDisk(
                    data,
                    forKey: key,
                    forcedExtension: options.forcedExtension,
                    processorIdentifier: identifier,
                    callbackQueue: callbackQueue,
                    expiration: options.diskCacheExpiration,
                    writeOptions: options.diskStoreWriteOptions,
                    completionHandler: completionHandler)
            } else {
                // 직렬화 실패: 이미지를 Data로 변환할 수 없는 경우
                guard let completionHandler = completionHandler else { return }

                let diskError = KingfisherError.cacheError(
                    reason: .cannotSerializeImage(image: image, original: original, serializer: serializer))
                let result = CacheStoreResult(
                    memoryCacheResult: .success(()),
                    diskCacheResult: .failure(diskError))
                callbackQueue.execute { completionHandler(result) }
            }
        }
    }

    /// 이미지를 캐시에 저장한다 (공개 API, 외부에서 직접 호출하기 편한 버전).
    ///
    /// 위의 `store(_:original:forKey:options:toDisk:completionHandler:)` 메서드의 래퍼이다.
    /// 개별 파라미터를 받아 내부적으로 `KingfisherParsedOptionsInfo`를 구성한 뒤 핵심 메서드를 호출한다.
    ///
    /// 이 메서드 내부에서 임시(TempProcessor) 구조체를 생성하여 프로세서 식별자만 전달하는 것이 특징적이다.
    /// 실제로 이미지 처리를 수행하지는 않고(process()가 nil을 반환), 단순히 캐시 키 생성을 위한 식별자 역할만 한다.
    ///
    /// - Parameters:
    ///   - image: 저장할 이미지.
    ///   - original: 원본 이미지 데이터.
    ///   - key: 캐싱에 사용되는 키.
    ///   - identifier: 프로세서 식별자. 기본값은 빈 문자열.
    ///   - forcedExtension: 캐시 파일의 확장자. `nil`이면 디스크 스토리지 설정에 따른다.
    ///   - serializer: 이미지를 데이터로 변환하는 직렬화기. 기본값은 `DefaultCacheSerializer.default`.
    ///   - toDisk: 디스크에도 저장할지 여부. 기본값은 `true`.
    ///   - callbackQueue: 완료 콜백이 실행될 큐. 기본값은 `.untouch` (호출자 큐에서 실행).
    ///   - completionHandler: 캐시 저장 완료 시 호출되는 클로저.
    open func store(
        _ image: KFCrossPlatformImage,
        original: Data? = nil,
        forKey key: String,
        processorIdentifier identifier: String = "",
        forcedExtension: String? = nil,
        cacheSerializer serializer: any CacheSerializer = DefaultCacheSerializer.default,
        toDisk: Bool = true,
        callbackQueue: CallbackQueue = .untouch,
        completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil
    )
    {
        // 캐시 키 생성만을 위한 임시 프로세서.
        // ImageProcessor 프로토콜을 준수하지만 실제 처리 로직은 없다 (process()가 nil 반환).
        // 오직 identifier 프로퍼티만 사용되며, 이를 통해 캐시 키에 프로세서 정보를 포함시킨다.
        struct TempProcessor: ImageProcessor {
            let identifier: String
            func process(item: ImageProcessItem, options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage? {
                return nil
            }
        }

        let options = KingfisherParsedOptionsInfo([
            .processor(TempProcessor(identifier: identifier)),
            .cacheSerializer(serializer),
            .callbackQueue(callbackQueue),
            .forcedCacheFileExtension(forcedExtension)
        ])
        store(
            image,
            original: original,
            forKey: key,
            options: options,
            toDisk: toDisk,
            completionHandler: completionHandler
        )
    }

    /// 데이터를 디스크에 직접 저장한다 (이미지 변환 없이).
    ///
    /// 이미 직렬화된 데이터(Data)를 디스크 캐시에 저장할 때 사용한다.
    /// 메모리 캐시에는 저장하지 않으며, 오직 디스크 캐시만 대상으로 한다.
    /// ioQueue를 통해 비동기적으로 실행된다.
    ///
    /// - Parameters:
    ///   - data: 저장할 데이터.
    ///   - key: 캐싱에 사용되는 키.
    ///   - identifier: 프로세서 식별자.
    ///   - forcedExtension: 캐시 파일 확장자.
    ///   - expiration: 만료 정책.
    ///   - callbackQueue: 완료 콜백이 실행될 큐.
    ///   - completionHandler: 저장 완료 시 호출되는 클로저.
    open func storeToDisk(
        _ data: Data,
        forKey key: String,
        processorIdentifier identifier: String = "",
        forcedExtension: String? = nil,
        expiration: StorageExpiration? = nil,
        callbackQueue: CallbackQueue = .untouch,
        completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil)
    {
        ioQueue.async {
            self.syncStoreToDisk(
                data,
                forKey: key,
                forcedExtension: forcedExtension,
                processorIdentifier: identifier,
                callbackQueue: callbackQueue,
                expiration: expiration,
                completionHandler: completionHandler
            )
        }
    }

    /// 디스크에 동기적으로 데이터를 저장하는 내부 메서드.
    ///
    /// 이 메서드는 반드시 ioQueue 내에서 호출되어야 한다 (직렬 큐에 의한 동기화 보장).
    /// `store()`와 `storeToDisk()` 모두 이 메서드를 최종적으로 호출한다.
    ///
    /// **동작:**
    /// 1. key와 processorIdentifier를 결합하여 computedKey를 생성한다.
    /// 2. `diskStorage.store()`를 호출하여 파일 시스템에 데이터를 기록한다.
    /// 3. 성공/실패 결과를 CacheStoreResult로 감싸 콜백을 호출한다.
    private func syncStoreToDisk(
        _ data: Data,
        forKey key: String,
        forcedExtension: String?,
        processorIdentifier identifier: String = "",
        callbackQueue: CallbackQueue = .untouch,
        expiration: StorageExpiration? = nil,
        writeOptions: Data.WritingOptions = [],
        completionHandler: (@Sendable (CacheStoreResult) -> Void)? = nil)
    {
        let computedKey = key.computedKey(with: identifier)
        let result: CacheStoreResult
        do {
            try self.diskStorage.store(
                value: data,
                forKey: computedKey,
                expiration: expiration,
                writeOptions: writeOptions,
                forcedExtension: forcedExtension
            )
            result = CacheStoreResult(memoryCacheResult: .success(()), diskCacheResult: .success(()))
        } catch {
            let diskError: KingfisherError
            if let error = error as? KingfisherError {
                diskError = error
            } else {
                diskError = .cacheError(reason: .cannotConvertToData(object: data, error: error))
            }

            result = CacheStoreResult(
                memoryCacheResult: .success(()),
                diskCacheResult: .failure(diskError)
            )
        }
        if let completionHandler = completionHandler {
            callbackQueue.execute { completionHandler(result) }
        }
    }

    // MARK: - Removing Images (이미지 삭제)

    /// 주어진 키에 해당하는 이미지를 캐시에서 삭제한다 (공개 API).
    ///
    /// 메모리 캐시와 디스크 캐시 중 선택적으로 삭제할 수 있다.
    /// 에러 정보가 필요 없는 경우를 위한 간략한 버전이다.
    ///
    /// - Parameters:
    ///   - key: 캐싱에 사용된 키.
    ///   - identifier: 프로세서 식별자.
    ///   - forcedExtension: 캐시 파일 확장자.
    ///   - fromMemory: 메모리 캐시에서 삭제할지 여부. 기본값 `true`.
    ///   - fromDisk: 디스크 캐시에서 삭제할지 여부. 기본값 `true`.
    ///   - callbackQueue: 완료 콜백 실행 큐. 기본값 `.untouch`.
    ///   - completionHandler: 삭제 완료 시 호출되는 클로저.
    open func removeImage(
        forKey key: String,
        processorIdentifier identifier: String = "",
        forcedExtension: String? = nil,
        fromMemory: Bool = true,
        fromDisk: Bool = true,
        callbackQueue: CallbackQueue = .untouch,
        completionHandler: (@Sendable () -> Void)? = nil
    )
    {
        removeImage(
            forKey: key,
            processorIdentifier: identifier,
            forcedExtension: forcedExtension,
            fromMemory: fromMemory,
            fromDisk: fromDisk,
            callbackQueue: callbackQueue,
            completionHandler: { _ in completionHandler?() } // 에러를 무시하는 래퍼 버전.
        )
    }

    /// 주어진 키에 해당하는 이미지를 캐시에서 삭제한다 (내부 구현).
    ///
    /// **동작 흐름:**
    /// 1. key와 identifier로 computedKey를 계산한다.
    /// 2. `fromMemory`가 true면 메모리 캐시에서 동기적으로 삭제한다.
    /// 3. `fromDisk`가 true면 ioQueue에서 비동기적으로 디스크 캐시에서 삭제한다.
    /// 4. 완료 콜백을 호출한다.
    ///
    /// 메모리 캐시 삭제는 동기적이고, 디스크 캐시 삭제는 비동기적이다.
    /// 이는 store 메서드와 같은 패턴으로, 디스크 I/O가 느리기 때문이다.
    func removeImage(
        forKey key: String,
        processorIdentifier identifier: String = "",
        forcedExtension: String?,
        fromMemory: Bool = true,
        fromDisk: Bool = true,
        callbackQueue: CallbackQueue = .untouch,
        completionHandler: (@Sendable ((any Error)?) -> Void)? = nil)
    {
        let computedKey = key.computedKey(with: identifier)

        if fromMemory {
            // 메모리 캐시에서 동기적으로 삭제 (NSLock으로 보호됨)
            memoryStorage.remove(forKey: computedKey)
        }

        // 콜백 헬퍼 함수 (코드 중복 방지)
        @Sendable func callHandler(_ error: (any Error)?) {
            if let completionHandler = completionHandler {
                callbackQueue.execute { completionHandler(error) }
            }
        }

        if fromDisk {
            // 디스크 캐시에서 비동기적으로 삭제 (ioQueue 직렬 큐에서 실행)
            ioQueue.async{
                do {
                    try self.diskStorage.remove(forKey: computedKey, forcedExtension: forcedExtension)
                    callHandler(nil)
                } catch {
                    callHandler(error)
                }
            }
        } else {
            callHandler(nil)
        }
    }

    // MARK: - Getting Images (이미지 조회)

    /// 캐시에서 이미지를 조회한다 (메모리 → 디스크 순서로 탐색).
    ///
    /// 이 메서드는 Kingfisher의 이미지 조회 파이프라인의 핵심이다.
    ///
    /// **탐색 순서:**
    /// 1. **메모리 캐시 확인** (동기적, 즉시):
    ///    - 메모리에 있으면 → `.success(.memory(image))` 반환
    /// 2. **fromMemoryCacheOrRefresh 옵션 확인**:
    ///    - 이 옵션이 true면 메모리에 없을 경우 디스크 탐색 없이 → `.success(.none)` 반환
    ///    - 네트워크에서 새로 다운로드하도록 유도하는 옵션이다.
    /// 3. **디스크 캐시 확인** (비동기적, ioQueue):
    ///    - 디스크에 있으면 → 이미지를 메모리 캐시에도 저장(캐시 워밍) → `.success(.disk(image))` 반환
    ///    - 디스크에도 없으면 → `.success(.none)` 반환
    ///
    /// **캐시 워밍 (Cache Warming)**: 디스크에서 조회된 이미지는 자동으로 메모리 캐시에도 저장된다.
    /// 다음 번 같은 이미지 접근 시 더 빠른 메모리 캐시에서 즉시 가져올 수 있게 하기 위함이다.
    ///
    /// - Parameters:
    ///   - key: 캐시에 사용된 키.
    ///   - options: 캐싱 옵션 정보.
    ///   - callbackQueue: 콜백이 실행될 큐. 기본값은 `.mainCurrentOrAsync`.
    ///   - completionHandler: 조회 완료 시 호출되는 클로저.
    open func retrieveImage(
        forKey key: String,
        options: KingfisherParsedOptionsInfo,
        callbackQueue: CallbackQueue = .mainCurrentOrAsync,
        completionHandler: (@Sendable (Result<ImageCacheResult, KingfisherError>) -> Void)?)
    {
        // 완료 핸들러가 없으면 작업을 수행할 필요가 없으므로 즉시 반환한다.
        guard let completionHandler = completionHandler else { return }

        // 1단계: 메모리 캐시에서 먼저 확인 (동기적, 가장 빠름)
        if let image = retrieveImageInMemoryCache(forKey: key, options: options) {
            callbackQueue.execute { completionHandler(.success(.memory(image))) }
        } else if options.fromMemoryCacheOrRefresh {
            // 메모리 캐시에 없고, "메모리 캐시 또는 새로고침" 옵션이 켜져 있으면
            // 디스크 탐색을 건너뛰고 .none을 반환한다.
            // 이렇게 하면 KingfisherManager가 네트워크에서 새로 다운로드하게 된다.
            callbackQueue.execute { completionHandler(.success(.none)) }
        } else {

            // 2단계: 디스크 캐시에서 검색 (비동기적)
            self.retrieveImageInDiskCache(forKey: key, options: options, callbackQueue: callbackQueue) {
                result in
                switch result {
                case .success(let image):

                    guard let image = image else {
                        // 디스크에도 이미지가 없는 경우
                        callbackQueue.execute { completionHandler(.success(.none)) }
                        return
                    }

                    // 3단계: 디스크에서 찾은 이미지를 메모리 캐시에도 저장 (캐시 워밍)
                    // `toDisk: false`로 설정하여 디스크에는 다시 쓰지 않는다.
                    // callbackQueue를 .untouch로 변경하여 추가적인 디스패치 없이
                    // 현재 큐에서 바로 콜백이 실행되도록 한다.
                    var cacheOptions = options
                    cacheOptions.callbackQueue = .untouch
                    self.store(
                        image,
                        forKey: key,
                        options: cacheOptions,
                        toDisk: false)
                    {
                        _ in
                        callbackQueue.execute { completionHandler(.success(.disk(image))) }
                    }
                case .failure(let error):
                    callbackQueue.execute { completionHandler(.failure(error)) }
                }
            }
        }
    }

    /// 캐시에서 이미지를 조회한다 (KingfisherOptionsInfo 기반 공개 API).
    ///
    /// 위의 `retrieveImage(forKey:options:callbackQueue:completionHandler:)` 의 래퍼이다.
    /// `KingfisherOptionsInfo?`를 받아 내부적으로 `KingfisherParsedOptionsInfo`로 변환한다.
    open func retrieveImage(
        forKey key: String,
        options: KingfisherOptionsInfo? = nil,
        callbackQueue: CallbackQueue = .mainCurrentOrAsync,
        completionHandler: (@Sendable (Result<ImageCacheResult, KingfisherError>) -> Void)?
    )
    {
        retrieveImage(
            forKey: key,
            options: KingfisherParsedOptionsInfo(options),
            callbackQueue: callbackQueue,
            completionHandler: completionHandler)
    }

    /// 메모리 캐시에서만 이미지를 조회한다.
    ///
    /// 동기적으로 즉시 결과를 반환하므로, 메모리 캐시 히트/미스를 빠르게 판단할 때 사용한다.
    /// 만료된 이미지는 `nil`을 반환한다.
    ///
    /// - Parameters:
    ///   - key: 캐시에 사용된 키.
    ///   - options: 옵션 정보. 프로세서 식별자와 만료 정책 연장 설정을 포함한다.
    /// - Returns: 유효한 이미지가 있으면 해당 이미지, 없거나 만료되었으면 `nil`.
    open func retrieveImageInMemoryCache(
        forKey key: String,
        options: KingfisherParsedOptionsInfo) -> KFCrossPlatformImage?
    {
        let computedKey = key.computedKey(with: options.processor.identifier)
        // MemoryStorage의 value(forKey:)는 내부적으로 만료 여부를 확인하고,
        // 접근 시 만료 시간을 연장하는 기능을 포함한다.
        return memoryStorage.value(
            forKey: computedKey,
            extendingExpiration: options.memoryCacheAccessExtendingExpiration
        )
    }

    /// 메모리 캐시에서만 이미지를 조회한다 (KingfisherOptionsInfo 기반 공개 API).
    open func retrieveImageInMemoryCache(
        forKey key: String,
        options: KingfisherOptionsInfo? = nil) -> KFCrossPlatformImage?
    {
        return retrieveImageInMemoryCache(forKey: key, options: KingfisherParsedOptionsInfo(options))
    }

    /// 디스크 캐시에서 이미지를 조회한다 (내부 구현).
    ///
    /// **동작 흐름:**
    /// 1. `loadDiskFileSynchronously` 옵션에 따라 동기/비동기 로딩을 결정한다.
    ///    - `true`: 현재 큐에서 동기적으로 로딩 (호출자 스레드를 블로킹)
    ///    - `false` (기본): ioQueue에서 비동기적으로 로딩
    /// 2. 디스크에서 바이너리 데이터를 읽는다.
    /// 3. `CacheSerializer`를 사용하여 데이터를 이미지로 역직렬화한다.
    /// 4. `backgroundDecode` 옵션이 켜져 있으면 이미지를 디코딩한다.
    /// 5. 결과를 callbackQueue에서 콜백으로 전달한다.
    func retrieveImageInDiskCache(
        forKey key: String,
        options: KingfisherParsedOptionsInfo,
        callbackQueue: CallbackQueue = .untouch,
        completionHandler: @escaping @Sendable (Result<KFCrossPlatformImage?, KingfisherError>) -> Void)
    {
        let computedKey = key.computedKey(with: options.processor.identifier)
        // 동기 로딩 옵션에 따라 실행할 큐를 결정한다.
        // - .untouch: 현재 스레드에서 그대로 실행 (동기)
        // - .dispatch(ioQueue): ioQueue에서 비동기 실행
        let loadingQueue: CallbackQueue = options.loadDiskFileSynchronously ? .untouch : .dispatch(ioQueue)
        loadingQueue.execute {
            do {
                var image: KFCrossPlatformImage? = nil
                if let data = try self.diskStorage.value(
                    forKey: computedKey,
                    forcedExtension: options.forcedExtension,
                    extendingExpiration: options.diskCacheAccessExtendingExpiration
                ) {
                    // CacheSerializer를 사용하여 Data → Image 변환
                    image = options.cacheSerializer.image(with: data, options: options)
                }
                // backgroundDecode 옵션: 이미지 디코딩을 백그라운드에서 수행.
                // UIImage는 처음 화면에 표시될 때 lazy decoding이 발생하는데,
                // 이를 미리 수행하면 메인 스레드에서의 디코딩 지연을 방지할 수 있다.
                if options.backgroundDecode {
                    image = image?.kf.decoded(scale: options.scaleFactor)
                }
                callbackQueue.execute { [image] in completionHandler(.success(image)) }
            } catch let error as KingfisherError {
                callbackQueue.execute { completionHandler(.failure(error)) }
            } catch {
                assertionFailure("The internal thrown error should be a `KingfisherError`.")
            }
        }
    }

    /// 디스크 캐시에서 이미지를 조회한다 (공개 API).
    open func retrieveImageInDiskCache(
        forKey key: String,
        options: KingfisherOptionsInfo? = nil,
        callbackQueue: CallbackQueue = .untouch,
        completionHandler: @escaping @Sendable (Result<KFCrossPlatformImage?, KingfisherError>) -> Void)
    {
        retrieveImageInDiskCache(
            forKey: key,
            options: KingfisherParsedOptionsInfo(options),
            callbackQueue: callbackQueue,
            completionHandler: completionHandler)
    }

    // MARK: - Cleaning (캐시 정리)

    /// 메모리 캐시와 디스크 캐시를 모두 비운다.
    ///
    /// 비동기 작업이며, 디스크 정리가 완료되면 `handler`가 메인 큐에서 호출된다.
    /// 메모리 캐시는 즉시 비워지고, 디스크 캐시는 ioQueue에서 비동기적으로 비워진다.
    public func clearCache(completion handler: (@Sendable () -> Void)? = nil) {
        clearMemoryCache()
        clearDiskCache(completion: handler)
    }

    /// 메모리 캐시를 모두 비운다.
    ///
    /// `@objc`로 표시되어 Notification 셀렉터로 사용될 수 있다.
    /// `UIApplication.didReceiveMemoryWarningNotification`을 받으면 이 메서드가 호출되어
    /// 모든 메모리 캐시를 즉시 해제한다.
    @objc public func clearMemoryCache() {
        memoryStorage.removeAll()
    }

    /// 디스크 캐시를 모두 비운다.
    ///
    /// ioQueue에서 비동기적으로 실행되어, 디스크의 모든 캐시 파일을 삭제한다.
    /// 완료 시 `handler`가 **메인 큐**에서 호출된다.
    ///
    /// **주의**: 이 메서드는 `KingfisherDidCleanDiskCache` Notification을 발송하지 않는다.
    /// 이 알림은 오직 자동 정리(만료/크기 초과)에서만 발송된다.
    open func clearDiskCache(completion handler: (@Sendable () -> Void)? = nil) {
        ioQueue.async {
            do {
                try self.diskStorage.removeAll()
            } catch _ { }
            if let handler = handler {
                DispatchQueue.main.async { handler() }
            }
        }
    }

    /// 만료된 이미지를 메모리와 디스크 캐시에서 정리한다.
    ///
    /// 메모리 캐시의 만료 항목은 즉시 제거하고,
    /// 디스크 캐시의 만료 항목은 ioQueue에서 비동기적으로 제거한다.
    open func cleanExpiredCache(completion handler: (@Sendable () -> Void)? = nil) {
        cleanExpiredMemoryCache()
        cleanExpiredDiskCache(completion: handler)
    }

    /// 메모리 캐시에서 만료된 이미지를 정리한다.
    open func cleanExpiredMemoryCache() {
        memoryStorage.removeExpired()
    }

    /// 디스크 캐시에서 만료된 이미지를 정리한다 (Notification 셀렉터용).
    ///
    /// `@objc`로 표시되어 `UIApplication.willTerminateNotification` 등의
    /// 시스템 알림 셀렉터로 사용된다.
    @objc func cleanExpiredDiskCache() {
        cleanExpiredDiskCache(completion: nil)
    }

    /// 디스크 캐시에서 만료된 이미지를 정리하고, 크기 초과 파일도 제거한다.
    ///
    /// **동작 흐름 (ioQueue에서 비동기 실행):**
    /// 1. 만료된 캐시 파일을 제거한다 (`removeExpiredValues()`).
    /// 2. 전체 캐시 크기가 제한을 초과하는 경우, LRU(Least Recently Used) 방식으로
    ///    오래된 파일부터 삭제하여 크기 제한의 절반까지 줄인다 (`removeSizeExceededValues()`).
    /// 3. 삭제된 파일이 있으면 `KingfisherDidCleanDiskCache` Notification을 메인 큐에서 발송한다.
    /// 4. 완료 핸들러를 메인 큐에서 호출한다.
    open func cleanExpiredDiskCache(completion handler: (@Sendable () -> Void)? = nil) {
        ioQueue.async {
            do {
                var removed: [URL] = []
                // 만료된 파일 제거
                let removedExpired = try self.diskStorage.removeExpiredValues()
                removed.append(contentsOf: removedExpired)

                // 사이즈 제한 초과 파일 제거 (LRU 방식)
                let removedSizeExceeded = try self.diskStorage.removeSizeExceededValues()
                removed.append(contentsOf: removedSizeExceeded)

                // 삭제된 파일이 있으면 Notification 발송
                if !removed.isEmpty {
                    DispatchQueue.main.async { [removed] in
                        let cleanedHashes = removed.map { $0.lastPathComponent }
                        NotificationCenter.default.post(
                            name: .KingfisherDidCleanDiskCache,
                            object: self,
                            userInfo: [KingfisherDiskCacheCleanedHashKey: cleanedHashes])
                    }
                }

                if let handler = handler {
                    DispatchQueue.main.async { handler() }
                }
            } catch {}
        }
    }

#if !os(macOS) && !os(watchOS)
    /// 앱이 백그라운드에 있을 때 만료된 디스크 캐시를 정리한다.
    ///
    /// iOS 백그라운드 태스크(UIBackgroundTask)를 활용하여,
    /// 앱이 백그라운드 상태에서도 캐시 정리가 완료될 수 있도록 시간을 확보한다.
    ///
    /// **동작 흐름:**
    /// 1. `UIApplication.shared`를 가져온다 (앱 확장에서는 nil일 수 있으므로 옵셔널 체크).
    /// 2. `beginBackgroundTask`를 호출하여 백그라운드 실행 시간을 요청한다.
    /// 3. `cleanExpiredDiskCache()`를 비동기적으로 실행한다.
    /// 4. 정리가 완료되면 `endBackgroundTask`를 호출하여 시스템에 작업 완료를 알린다.
    ///
    /// `BackgroundTaskState` actor를 사용하여 백그라운드 태스크 식별자의
    /// 동시 접근을 안전하게 관리한다.
    ///
    /// 보통 직접 호출할 필요 없이, `UIApplication.didEnterBackgroundNotification`에
    /// 의해 자동으로 트리거된다.
    @MainActor
    @objc public func backgroundCleanExpiredDiskCache() {
        guard let sharedApplication = KingfisherWrapper<UIApplication>.shared else { return }

        // 백그라운드 태스크 식별자를 thread-safe하게 관리하기 위한 actor.
        // actor는 Swift의 동시성 모델에서 데이터 경쟁을 방지하는 참조 타입이다.
        actor BackgroundTaskState {
            private var value: UIBackgroundTaskIdentifier? = nil

            func setValue(_ newValue: UIBackgroundTaskIdentifier) {
                value = newValue
            }

            // 유효한 식별자를 꺼내고 동시에 무효화한다.
            // 중복 호출을 방지하는 take-and-invalidate 패턴이다.
            func takeValidValueAndInvalidate() -> UIBackgroundTaskIdentifier? {
                guard let task = value, task != .invalid else { return nil }
                value = .invalid
                return task
            }
        }

        let taskState = BackgroundTaskState()

        // 백그라운드 태스크 종료 클로저.
        // 정리 완료 시 또는 시스템이 만료 시 호출된다.
        let endBackgroundTaskIfNeeded: @Sendable () -> Void = {
            Task { @MainActor in
                guard let bgTask = await taskState.takeValidValueAndInvalidate() else { return }
                guard let sharedApplication = KingfisherWrapper<UIApplication>.shared else { return }
                #if compiler(>=6)
                sharedApplication.endBackgroundTask(bgTask)
                #else
                await sharedApplication.endBackgroundTask(bgTask)
                #endif
            }
        }

        // 백그라운드 태스크 시작. 시스템에 "아직 작업 중"임을 알린다.
        let createdTask = sharedApplication.beginBackgroundTask(
            withName: "Kingfisher:backgroundCleanExpiredDiskCache",
            expirationHandler: endBackgroundTaskIfNeeded
        )

        Task { await taskState.setValue(createdTask) }

        // 만료된 디스크 캐시를 정리하고, 완료 시 백그라운드 태스크를 종료한다.
        cleanExpiredDiskCache {
            Task { @MainActor in
                endBackgroundTaskIfNeeded()
            }
        }
    }
#endif

    // MARK: - Image Cache State (캐시 상태 확인)

    /// 주어진 키와 프로세서 식별자 조합에 대한 캐시 타입을 반환한다.
    ///
    /// 메모리 캐시를 먼저 확인하고, 없으면 디스크 캐시를 확인한다.
    /// 둘 다 없으면 `.none`을 반환한다.
    ///
    /// **주의**: 이 메서드는 동기적으로 동작한다. 디스크 캐시 확인 시
    /// `DiskStorage.isCached()`를 호출하는데, 이는 파일 시스템 메타데이터만 확인하므로
    /// 실제 파일 내용을 로드하지 않아 상대적으로 빠르다.
    ///
    /// - Parameters:
    ///   - key: 캐싱에 사용된 키.
    ///   - identifier: 프로세서 식별자.
    ///   - forcedExtension: 캐시 파일 확장자.
    /// - Returns: 캐시 상태를 나타내는 `CacheType`.
    open func imageCachedType(
        forKey key: String,
        processorIdentifier identifier: String = DefaultImageProcessor.default.identifier,
        forcedExtension: String? = nil
    ) -> CacheType
    {
        let computedKey = key.computedKey(with: identifier)
        if memoryStorage.isCached(forKey: computedKey) { return .memory }
        if diskStorage.isCached(forKey: computedKey, forcedExtension: forcedExtension) { return .disk }
        return .none
    }

    /// 주어진 키와 프로세서 식별자 조합에 대해 캐시가 존재하는지 여부를 반환한다.
    ///
    /// `imageCachedType()`의 결과를 기반으로 단순히 캐시 존재 여부만 Bool로 반환한다.
    /// 어느 레이어(메모리/디스크)에 있는지는 이 메서드로 알 수 없다.
    public func isCached(
        forKey key: String,
        processorIdentifier identifier: String = DefaultImageProcessor.default.identifier,
        forcedExtension: String? = nil
    ) -> Bool
    {
        return imageCachedType(forKey: key, processorIdentifier: identifier, forcedExtension: forcedExtension).cached
    }

    /// 주어진 키에 대한 캐시 파일명(해시)을 반환한다.
    ///
    /// DiskStorage가 실제로 사용하는 파일명을 반환한다.
    /// 기본적으로 키의 SHA256 해시를 파일명으로 사용한다.
    open func hash(
        forKey key: String,
        processorIdentifier identifier: String = DefaultImageProcessor.default.identifier,
        forcedExtension: String? = nil
    ) -> String
    {
        let computedKey = key.computedKey(with: identifier)
        return diskStorage.cacheFileName(forKey: computedKey, forcedExtension: forcedExtension)
    }

    /// 디스크 캐시가 차지하는 전체 크기를 계산한다 (바이트 단위).
    ///
    /// ioQueue에서 비동기적으로 실행되며, 결과는 **메인 큐**에서 콜백으로 전달된다.
    /// 디스크의 모든 캐시 파일 크기를 합산하여 반환한다.
    open func calculateDiskStorageSize(
        completion handler: @escaping (@Sendable (Result<UInt, KingfisherError>) -> Void)
    ) {
        ioQueue.async {
            do {
                let size = try self.diskStorage.totalSize()
                DispatchQueue.main.async { handler(.success(size)) }
            } catch let error as KingfisherError {
                DispatchQueue.main.async { handler(.failure(error)) }
            } catch {
                assertionFailure("The internal thrown error should be a `KingfisherError`.")
            }
        }
    }

    /// 주어진 키에 대한 디스크 캐시 파일 경로를 반환한다.
    ///
    /// 웹뷰나 로컬 파일 경로가 필요한 경우에 유용하다.
    /// 예를 들어, HTML의 `<img src='...'>`에 로컬 캐시 경로를 넣을 수 있다.
    ///
    /// **주의**: 이 메서드는 해당 경로에 이미지가 실제로 존재하는지는 보장하지 않는다.
    /// 해당 키로 캐시된 이미지가 있을 경우의 "예상 경로"만 반환한다.
    /// 실제 존재 여부는 `isCached(forKey:)` 메서드로 확인해야 한다.
    open func cachePath(
        forKey key: String,
        processorIdentifier identifier: String = DefaultImageProcessor.default.identifier,
        forcedExtension: String? = nil
    ) -> String
    {
        let computedKey = key.computedKey(with: identifier)
        return diskStorage.cacheFileURL(forKey: computedKey, forcedExtension: forcedExtension).path
    }

    /// 디스크 캐시 파일이 실제로 존재하면 해당 파일의 URL을 반환한다. 없으면 `nil`.
    ///
    /// `cachePath(forKey:)`와 달리, 실제로 파일이 존재하는 경우에만 URL을 반환한다.
    /// 내부적으로 `diskStorage.isCached()`를 호출하여 존재 여부를 먼저 확인한다.
    open func cacheFileURLIfOnDisk(
        forKey key: String,
        processorIdentifier identifier: String = DefaultImageProcessor.default.identifier,
        forcedExtension: String? = nil
    ) -> URL?
    {
        let computedKey = key.computedKey(with: identifier)
        return diskStorage.isCached(
            forKey: computedKey,
            forcedExtension: forcedExtension
        ) ? diskStorage.cacheFileURL(forKey: computedKey, forcedExtension: forcedExtension) : nil
    }

    // MARK: - Concurrency (Swift Concurrency - async/await 지원)

    // 아래의 async/await 메서드들은 기존 콜백 기반 메서드를 Swift Concurrency로 래핑한 것이다.
    // `withCheckedThrowingContinuation`을 사용하여 콜백 패턴을 async/await으로 브릿징한다.
    // 이를 통해 Task { } 내에서 `await cache.store(image, forKey: key)`처럼 사용할 수 있다.

    /// 이미지를 캐시에 저장한다 (async/await 버전, KingfisherParsedOptionsInfo).
    open func store(
        _ image: KFCrossPlatformImage,
        original: Data? = nil,
        forKey key: String,
        options: KingfisherParsedOptionsInfo,
        toDisk: Bool = true
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            store(image, original: original, forKey: key, options: options, toDisk: toDisk) {
                // diskCacheResult만 실패할 수 있으므로, 이것으로 continuation을 재개한다.
                continuation.resume(with: $0.diskCacheResult)
            }
        }
    }

    /// 이미지를 캐시에 저장한다 (async/await 버전, 공개 API).
    open func store(
        _ image: KFCrossPlatformImage,
        original: Data? = nil,
        forKey key: String,
        processorIdentifier identifier: String = "",
        forcedExtension: String? = nil,
        cacheSerializer serializer: any CacheSerializer = DefaultCacheSerializer.default,
        toDisk: Bool = true
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            store(
                image,
                original: original,
                forKey: key,
                processorIdentifier: identifier,
                forcedExtension: forcedExtension,
                cacheSerializer: serializer,
                toDisk: toDisk) {
                    continuation.resume(with: $0.diskCacheResult)
                }
        }
    }

    /// 데이터를 디스크에 저장한다 (async/await 버전).
    open func storeToDisk(
        _ data: Data,
        forKey key: String,
        processorIdentifier identifier: String = "",
        forcedExtension: String? = nil,
        expiration: StorageExpiration? = nil
    ) async throws
    {
        try await withCheckedThrowingContinuation { continuation in
            storeToDisk(
                data,
                forKey: key,
                processorIdentifier: identifier,
                forcedExtension: forcedExtension,
                expiration: expiration) {
                    continuation.resume(with: $0.diskCacheResult)
                }
        }
    }

    /// 이미지를 캐시에서 삭제한다 (async/await 버전).
    open func removeImage(
        forKey key: String,
        processorIdentifier identifier: String = "",
        forcedExtension: String? = nil,
        fromMemory: Bool = true,
        fromDisk: Bool = true
    ) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            removeImage(
                forKey: key,
                processorIdentifier: identifier,
                forcedExtension: forcedExtension,
                fromMemory: fromMemory,
                fromDisk: fromDisk,
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// 캐시에서 이미지를 조회한다 (async/await 버전, KingfisherParsedOptionsInfo).
    open func retrieveImage(
        forKey key: String,
        options: KingfisherParsedOptionsInfo
    ) async throws -> ImageCacheResult {
        try await withCheckedThrowingContinuation { continuation in
            retrieveImage(forKey: key, options: options) { continuation.resume(with: $0) }
        }
    }

    /// 캐시에서 이미지를 조회한다 (async/await 버전, 공개 API).
    open func retrieveImage(
        forKey key: String,
        options: KingfisherOptionsInfo? = nil
    ) async throws -> ImageCacheResult {
        try await withCheckedThrowingContinuation { continuation in
            retrieveImage(forKey: key, options: options) { continuation.resume(with: $0) }
        }
    }

    /// 디스크 캐시에서 이미지를 조회한다 (async/await 버전).
    open func retrieveImageInDiskCache(
        forKey key: String,
        options: KingfisherOptionsInfo? = nil
    ) async throws -> KFCrossPlatformImage? {
        try await withCheckedThrowingContinuation { continuation in
            retrieveImageInDiskCache(forKey: key, options: options) {
                continuation.resume(with: $0)
            }
        }
    }

    /// 메모리와 디스크 캐시를 모두 비운다 (async/await 버전).
    open func clearCache() async {
        await withCheckedContinuation { continuation in
            clearCache { continuation.resume() }
        }
    }

    /// 디스크 캐시를 비운다 (async/await 버전).
    open func clearDiskCache() async {
        await withCheckedContinuation { continuation in
            clearDiskCache { continuation.resume() }
        }
    }

    /// 만료된 캐시를 정리한다 (async/await 버전).
    open func cleanExpiredCache() async {
        await withCheckedContinuation { continuation in
            cleanExpiredCache { continuation.resume() }
        }
    }

    /// 만료된 디스크 캐시를 정리한다 (async/await 버전).
    open func cleanExpiredDiskCache() async {
        await withCheckedContinuation { continuation in
            cleanExpiredDiskCache { continuation.resume() }
        }
    }

    /// 디스크 캐시가 차지하는 전체 크기 (바이트 단위, async computed property).
    ///
    /// `calculateDiskStorageSize()`의 async/await 래퍼이다.
    open var diskStorageSize: UInt {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                calculateDiskStorageSize { continuation.resume(with: $0) }
            }
        }
    }

}


// MARK: - UIApplication 앱 확장(App Extension) 호환 처리

#if !os(macOS) && !os(watchOS)
extension UIApplication: KingfisherCompatible { }
extension KingfisherWrapper where Base: UIApplication {
    /// 앱 확장에서 안전하게 UIApplication.shared에 접근하기 위한 프로퍼티.
    ///
    /// 앱 확장(App Extension)에서는 `UIApplication.shared`에 직접 접근할 수 없다.
    /// 이를 우회하기 위해 `NSSelectorFromString`과 `perform(_:)`을 사용하여
    /// 런타임에 동적으로 `sharedApplication`을 호출한다.
    ///
    /// 앱 확장 환경에서는 이 셀렉터에 응답하지 않으므로 `nil`을 반환하고,
    /// 정상적인 앱 환경에서는 `UIApplication` 인스턴스를 반환한다.
    public static var shared: UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        guard Base.responds(to: selector) else { return nil }
        guard let unmanaged = Base.perform(selector) else { return nil }
        return unmanaged.takeUnretainedValue() as? UIApplication
    }
}
#endif

// MARK: - String 확장 (캐시 키 계산)

extension String {
    /// 프로세서 식별자를 결합하여 최종 캐시 키를 계산한다.
    ///
    /// - Parameter identifier: 프로세서 식별자.
    /// - Returns: 식별자가 비어있으면 원본 키를 그대로 반환하고,
    ///   비어있지 않으면 "원본키@식별자" 형식으로 반환한다.
    ///
    /// **예시:**
    /// - key: "https://example.com/image.png", identifier: "" → "https://example.com/image.png"
    /// - key: "https://example.com/image.png", identifier: "ResizingProcessor(100x100)"
    ///   → "https://example.com/image.png@ResizingProcessor(100x100)"
    func computedKey(with identifier: String) -> String {
        if identifier.isEmpty {
            return self
        } else {
            return appending("@\(identifier)")
        }
    }
}
