import Foundation


/// 특정 타입의 값을 디스크에 저장하는 스토리지 개념을 표현합니다.
///
/// 이 타입은 디스크 스토리지 관련 타입들을 묶는 네임스페이스 역할을 합니다.
/// 특정 ``DiskStorage/Config``를 사용하는 ``DiskStorage/Backend``를 통해
/// 실제 스토리지가 정의됩니다.
///
/// 자세한 내용은 이 복합 타입들을 참고하세요.
public enum DiskStorage {

    /// ``DiskStorage``의 실제 저장 백엔드를 나타냅니다.
    ///
    /// 값은 바이너리 데이터로 직렬화되어,
    /// 지정된 위치의 파일 시스템에 파일 형태로 저장됩니다.
    ///
    /// ``DiskStorage/Backend``는 ``DiskStorage/Backend/init(config:)``에서
    /// ``DiskStorage/Config``를 전달해 생성할 수 있으며,
    /// 생성 이후에도 ``DiskStorage/Backend/config``를 수정해 설정을 변경할 수 있습니다.
    ///
    /// 이 백엔드는 파일의 속성(attribute)을 사용해
    /// 파일의 만료(expiration)나 용량 제한(size limit)을 추적합니다.
    public final class Backend<T: DataTransformable>: @unchecked Sendable where T: Sendable {
        
        private let propertyQueue = DispatchQueue(label: "com.onevcat.kingfisher.DiskStorage.Backend.propertyQueue")
        
        private var _config: Config
        /// 이 디스크 스토리지에서 사용하는 설정 값입니다.
        ///
        /// 필요에 따라 이 값을 변경해 스토리지 동작을 구성할 수 있습니다.
        public var config: Config {
            get { propertyQueue.sync { _config } }
            set { propertyQueue.sync { _config = newValue } }
        }

        /// ``DiskStorage/Config/name``과 ``DiskStorage/Config/cachePathBlock``을
        /// 고려하여 결정된 디스크 스토리지의 최종 URL입니다.
        public let directoryURL: URL

        let metaChangingQueue: DispatchQueue

        // 캐시 존재 여부를 빠르게 판단하기 위한 보조 자료구조입니다.
        // false-positive가 발생할 수 있습니다.
        var maybeCached: Set<String>?
        let maybeCachedCheckingQueue = DispatchQueue(label: "com.onevcat.Kingfisher.maybeCachedCheckingQueue")

        // 스토리지가 초기화 중 오류가 발생한 경우 false가 됩니다.
        // 기본 캐시 생성 시 예기치 않은 강제 크래시를 방지하기 위한 장치입니다.
        private var storageReady: Bool = true

        /// 주어진 ``DiskStorage/Config``를 사용해 디스크 스토리지를 생성합니다.
        ///
        /// - Parameter config: 디스크 스토리지에 사용할 설정 값
        /// - Throws: 스토리지 폴더를 가져오거나 생성할 수 없는 경우 오류를 던집니다.
        public convenience init(config: Config) throws {
            self.init(noThrowConfig: config, creatingDirectory: false)
            try prepareDirectory()
        }

        // creatingDirectory가 false이면 디렉터리 생성은 생략됩니다.
        // 이 경우 반환 이후 prepareDirectory를 직접 호출해야 합니다.
        init(noThrowConfig config: Config, creatingDirectory: Bool) {
            var config = config

            let creation = Creation(config)
            self.directoryURL = creation.directoryURL

            // 외부에서 설정된 retain cycle 가능성을 제거합니다.
            config.cachePathBlock = nil
            _config = config

            metaChangingQueue = DispatchQueue(label: creation.cacheName)
            setupCacheChecking()

            if creatingDirectory {
                try? prepareDirectory()
            }
        }

        private func setupCacheChecking() {
            DispatchQueue.global(qos: .default).async {
                do {
                    let allFiles = try self.config.fileManager.contentsOfDirectory(atPath: self.directoryURL.path)
                    let maybeCached = Set(allFiles)
                    self.maybeCachedCheckingQueue.async {
                        self.maybeCached = maybeCached
                    }
                } catch {
                    self.maybeCachedCheckingQueue.async {
                        // 초기화에 실패하면 해당 최적화 기능을 비활성화합니다.
                        // 이 경우 디스크에서 파일 존재 여부를 직접 확인하는 방식으로 동작합니다.
                        self.maybeCached = nil
                    }
                }
            }
        }

        // 스토리지 디렉터리를 생성합니다.
        private func prepareDirectory() throws {
            let fileManager = config.fileManager
            let path = directoryURL.path

            guard !fileManager.fileExists(atPath: path) else { return }

            do {
                try fileManager.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: nil)
            } catch {
                self.storageReady = false
                throw KingfisherError.cacheError(reason: .cannotCreateDirectory(path: path, error: error))
            }
        }

        /// 지정된 키와 만료 정책을 사용해 값을 디스크에 저장합니다.
        ///
        /// - Parameters:
        ///   - value: 저장할 값
        ///   - key: 값을 저장할 키. 이미 값이 존재한다면 덮어씁니다.
        ///   - expiration: 이 저장 동작에 사용할 만료 정책
        ///   - writeOptions: 파일 작성 시 사용할 옵션
        ///   - forcedExtension: 파일 확장자 (있는 경우)
        /// - Throws: 데이터 변환 또는 디스크 기록 중 발생한 오류
        public func store(
            value: T,
            forKey key: String,
            expiration: StorageExpiration? = nil,
            writeOptions: Data.WritingOptions = [],
            forcedExtension: String? = nil
        ) throws
        {
            guard storageReady else {
                throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
            }

            let expiration = expiration ?? config.expiration
            // 이미 만료된 상태를 나타내는 만료 정책이라면 저장할 필요가 없습니다.
            guard !expiration.isExpired else { return }
            
            let data: Data
            do {
                data = try value.toData()
            } catch {
                throw KingfisherError.cacheError(reason: .cannotConvertToData(object: value, error: error))
            }

            let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
            do {
                try data.write(to: fileURL, options: writeOptions)
            } catch {
                if error.isFolderMissing {
                    // 캐시 폴더가 삭제된 경우, 다시 생성한 뒤 재시도합니다.
                    do {
                        try prepareDirectory()
                        try data.write(to: fileURL, options: writeOptions)
                    } catch {
                        throw KingfisherError.cacheError(
                            reason: .cannotCreateCacheFile(fileURL: fileURL, key: key, data: data, error: error)
                        )
                    }
                } else {
                    throw KingfisherError.cacheError(
                        reason: .cannotCreateCacheFile(fileURL: fileURL, key: key, data: data, error: error)
                    )
                }
            }

            let now = Date()
            let attributes: [FileAttributeKey : Any] = [
                // 마지막 접근 날짜
                .creationDate: now.fileAttributeDate,
                // 예상 만료 날짜
                .modificationDate: expiration.estimatedExpirationSinceNow.fileAttributeDate
            ]
            do {
                try config.fileManager.setAttributes(attributes, ofItemAtPath: fileURL.path)
            } catch {
                try? config.fileManager.removeItem(at: fileURL)
                throw KingfisherError.cacheError(
                    reason: .cannotSetCacheFileAttribute(
                        filePath: fileURL.path,
                        attributes: attributes,
                        error: error
                    )
                )
            }

            maybeCachedCheckingQueue.async {
                self.maybeCached?.insert(fileURL.lastPathComponent)
            }
        }

        /// 스토리지에서 값을 조회합니다.
        ///
        /// - Parameters:
        ///   - key: 조회할 값의 캐시 키
        ///   - forcedExtension: 파일 확장자 (있는 경우)
        ///   - extendingExpiration: 조회 시 적용할 만료 연장 정책
        /// - Throws: 디스크 파일 작업 또는 데이터 변환 중 발생한 오류
        /// - Returns: 유효한 값이 존재하면 반환하고, 그렇지 않으면 `nil`
        public func value(
            forKey key: String,
            forcedExtension: String? = nil,
            extendingExpiration: ExpirationExtending = .cacheTime
        ) throws -> T? {
            try value(
                forKey: key,
                referenceDate: Date(),
                actuallyLoad: true,
                extendingExpiration: extendingExpiration,
                forcedExtension: forcedExtension
            )
        }

        /// 내부 구현용 조회 메서드입니다.
        ///
        /// - Parameters:
        ///   - key: 조회할 값의 캐시 키
        ///   - referenceDate: 만료 여부를 판단할 기준 날짜
        ///   - actuallyLoad: 실제로 디스크에서 데이터를 로드할지 여부
        ///   - extendingExpiration: 조회 후 적용할 만료 연장 정책
        ///   - forcedExtension: 파일 확장자 (있는 경우)
        ///
        /// - Returns: 유효한 값이 있으면 반환하고, 그렇지 않으면 `nil`
        func value(
            forKey key: String,
            referenceDate: Date,
            actuallyLoad: Bool,
            extendingExpiration: ExpirationExtending,
            forcedExtension: String?
        ) throws -> T? {
            try value(
                forKey: key,
                referenceDate: Date(),
                actuallyLoad: true,
                extendingExpiration: extendingExpiration,
                forcedExtension: forcedExtension
            )
        }

        /// 주어진 키에 대해 유효한 캐시 데이터가 존재하는지 여부를 판단합니다.
        ///
        /// - Parameters:
        ///   - key: 값의 캐시 키
        ///   - forcedExtension: 파일 확장자 (있는 경우)
        /// - Returns: 유효한 데이터가 존재하면 `true`, 그렇지 않으면 `false`
        ///
        /// > 이 메서드는 실제로 디스크에서 데이터를 로드하지 않기 때문에,
        /// > ``DiskStorage/Backend/value(forKey:forcedExtension:extendingExpiration:)``를
        /// > 호출해 `nil` 여부를 확인하는 것보다 더 빠릅니다.
        public func isCached(forKey key: String, forcedExtension: String? = nil) -> Bool {
            return isCached(forKey: key, referenceDate: Date(), forcedExtension: forcedExtension)
        }

        /// 주어진 키와 기준 날짜에 대해 유효한 캐시 데이터가 존재하는지 판단합니다.
        ///
        /// - Parameters:
        ///   - key: 값의 캐시 키
        ///   - referenceDate: 캐시 유효성을 판단할 기준 날짜
        ///   - forcedExtension: 파일 확장자 (있는 경우)
        ///
        /// - Returns: 유효한 데이터가 존재하면 `true`, 그렇지 않으면 `false`
        ///
        /// `referenceDate`에 `Date()`를 전달하면
        /// ``DiskStorage/Backend/isCached(forKey:forcedExtension:)``와 동일하게 동작합니다.
        ///
        /// 미래 시점을 기준으로 캐시 유효성을 판단하고 싶을 때
        /// `referenceDate`를 사용할 수 있습니다.
        public func isCached(forKey key: String, referenceDate: Date, forcedExtension: String? = nil) -> Bool {
            do {
                let result = try value(
                    forKey: key,
                    referenceDate: referenceDate,
                    actuallyLoad: false,
                    extendingExpiration: .none,
                    forcedExtension: forcedExtension
                )
                return result != nil
            } catch {
                return false
            }
        }

        /// 지정된 키에 해당하는 값을 제거합니다.
        ///
        /// - Parameters:
        ///   - key: 제거할 값의 캐시 키
        ///   - forcedExtension: 파일 확장자 (있는 경우)
        /// - Throws: 파일 제거 중 발생한 오류
        public func remove(forKey key: String, forcedExtension: String? = nil) throws {
            let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
            try removeFile(at: fileURL)
        }

        func removeFile(at url: URL) throws {
            try config.fileManager.removeItem(at: url)
        }

        /// 이 스토리지에 저장된 모든 값을 제거합니다.
        ///
        /// - Throws: 값 제거 중 발생한 오류
        public func removeAll() throws {
            try removeAll(skipCreatingDirectory: false)
        }

        func removeAll(skipCreatingDirectory: Bool) throws {
            try config.fileManager.removeItem(at: directoryURL)
            if !skipCreatingDirectory {
                try prepareDirectory()
            }
        }
        
        /// 주어진 계산된 `key`에 해당하는 캐시 파일의 디스크 상 URL을 반환합니다.
        ///
        /// - Parameters:
        ///   - key: 캐시 항목을 저장할 때 사용되는 최종 계산된 키
        ///     (일반적으로 ``Source/cacheKey``와 동일하지 않으며,
        ///      프로세서 식별자가 반영된 키입니다.)
        ///   - forcedExtension: 파일 확장자 (있는 경우)
        ///
        /// - Returns: 디스크 상에서 해당 캐시 파일이 위치해야 할 URL
        ///
        /// 이 메서드는 실제로 파일이 디스크에 존재함을 보장하지 않습니다.
        /// 단지, 존재한다면 위치해야 할 URL을 계산해 반환할 뿐입니다.
        public func cacheFileURL(forKey key: String, forcedExtension: String? = nil) -> URL {
            let fileName = cacheFileName(forKey: key, forcedExtension: forcedExtension)
            return directoryURL.appendingPathComponent(fileName, isDirectory: false)
        }
        
        func cacheFileName(forKey key: String, forcedExtension: String? = nil) -> String {
            let baseName = config.usesHashedFileName ? key.kf.sha256 : key
            
            if let ext = fileExtension(key: key, forcedExtension: forcedExtension) {
                return "\(baseName).\(ext)"
            }
            
            return baseName
        }
        
        func fileExtension(key: String, forcedExtension: String?) -> String? {
            if let ext = forcedExtension ?? config.pathExtension {
                return ext
            }
        
            if config.usesHashedFileName && config.autoExtAfterHashedFileName {
                return key.kf.ext
            }
        
            return nil
        }

        func allFileURLs(for propertyKeys: [URLResourceKey]) throws -> [URL] {
            let fileManager = config.fileManager

            guard let directoryEnumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: propertyKeys,
                options: .skipsHiddenFiles
            ) else {
                throw KingfisherError.cacheError(reason: .fileEnumeratorCreationFailed(url: directoryURL))
            }

            guard let urls = directoryEnumerator.allObjects as? [URL] else {
                throw KingfisherError.cacheError(reason: .invalidFileEnumeratorContent(url: directoryURL))
            }
            return urls
        }

        /// 이 스토리지에서 만료된 모든 값을 제거합니다.
        ///
        /// - Throws: 파일 제거 중 발생한 오류
        /// - Returns: 제거된 파일들의 URL 목록
        public func removeExpiredValues() throws -> [URL] {
            return try removeExpiredValues(referenceDate: Date())
        }

        func removeExpiredValues(referenceDate: Date) throws -> [URL] {
            let propertyKeys: [URLResourceKey] = [
                .isDirectoryKey,
                .contentModificationDateKey
            ]

            let urls = try allFileURLs(for: propertyKeys)
            let keys = Set(propertyKeys)
            let expiredFiles = urls.filter { fileURL in
                do {
                    let meta = try FileMeta(fileURL: fileURL, resourceKeys: keys)
                    if meta.isDirectory {
                        return false
                    }
                    return meta.expired(referenceDate: referenceDate)
                } catch {
                    return true
                }
            }
            try expiredFiles.forEach { url in
                try removeFile(at: url)
            }
            return expiredFiles
        }

        /// 이 스토리지에서 용량 제한을 초과한 값을 제거합니다.
        ///
        /// - Throws: 파일 제거 중 발생한 오류
        /// - Returns: 제거된 파일들의 URL 목록
        ///
        /// 이 메서드는 ``DiskStorage/Config/sizeLimit``을 기준으로,
        /// LRU(Least Recently Used, 가장 오래 사용되지 않은 순) 방식으로
        /// 캐시 파일을 제거합니다.
        public func removeSizeExceededValues() throws -> [URL] {

            if config.sizeLimit == 0 { return [] } // 하위 호환성 유지: 0은 제한 없음

            var size = try totalSize()
            if size < config.sizeLimit { return [] }

            let propertyKeys: [URLResourceKey] = [
                .isDirectoryKey,
                .creationDateKey,
                .fileSizeKey
            ]
            let keys = Set(propertyKeys)

            let urls = try allFileURLs(for: propertyKeys)
            var pendings: [FileMeta] = urls.compactMap { fileURL in
                guard let meta = try? FileMeta(fileURL: fileURL, resourceKeys: keys) else {
                    return nil
                }
                return meta
            }
            // 마지막 접근 날짜 기준으로 정렬 (가장 최근 접근된 파일이 앞)
            pendings.sort(by: FileMeta.lastAccessDate)

            var removed: [URL] = []
            let target = config.sizeLimit / 2
            while size > target, let meta = pendings.popLast() {
                size -= UInt(meta.fileSize)
                try removeFile(at: meta.url)
                removed.append(meta.url)
            }
            return removed
        }

        /// 캐시 폴더에 존재하는 모든 파일의 총 크기를 바이트 단위로 반환합니다.
        ///
        /// - Throws: 파일 메타데이터 조회 중 발생한 오류
        public func totalSize() throws -> UInt {
            let propertyKeys: [URLResourceKey] = [.fileSizeKey]
            let urls = try allFileURLs(for: propertyKeys)
            let keys = Set(propertyKeys)
            let totalSize: UInt = urls.reduce(0) { size, fileURL in
                do {
                    let meta = try FileMeta(fileURL: fileURL, resourceKeys: keys)
                    return size + UInt(meta.fileSize)
                } catch {
                    return size
                }
            }
            return totalSize
        }
    }
}

extension DiskStorage {
    
    /// ``DiskStorage/Backend``에서 사용하는 설정을 표현합니다.
    public struct Config: @unchecked Sendable {

        /// 디스크 스토리지의 최대 파일 크기 제한 (바이트 단위)
        ///
        /// `0`은 제한이 없음을 의미합니다.
        public var sizeLimit: UInt

        /// 디스크 스토리지에서 사용하는 만료 정책
        ///
        /// 기본값은 `.days(7)`이며,
        /// 이는 디스크 캐시에 접근이 없을 경우 1주일 후 만료됨을 의미합니다.
        public var expiration: StorageExpiration = .days(7)

        /// 캐시 파일에 사용할 기본 확장자
        ///
        /// 기본값은 `nil`이며, 이 경우 파일 확장자를 사용하지 않습니다.
        public var pathExtension: String? = nil

        /// 캐시 파일 이름을 해시하여 저장할지 여부
        ///
        /// 기본값은 `true`이며,
        /// 원본 다운로드 URL 등 사용자 정보를 보호하기 위해 사용됩니다.
        public var usesHashedFileName = true

        /// 해시된 파일 이름 뒤에 원본 파일의 확장자를 자동으로 붙일지 여부
        ///
        /// 기본값은 `false`입니다.
        public var autoExtAfterHashedFileName = false
        
        /// 초기 디렉터리 경로와 캐시 이름을 받아
        /// 최종 디스크 캐시 경로를 생성하는 클로저
        ///
        /// 캐시 경로를 완전히 커스터마이징하고 싶을 때 사용할 수 있습니다.
        public var cachePathBlock: (@Sendable (_ directory: URL, _ cacheName: String) -> URL)! = {
            (directory, cacheName) in
            return directory.appendingPathComponent(cacheName, isDirectory: true)
        }

        /// 디스크 캐시의 이름
        ///
        /// 기본적으로 캐시 폴더 이름의 일부로 사용됩니다.
        ///
        /// 동일한 `name`을 가진 두 스토리지는
        /// 동일한 디스크 폴더를 공유하게 되므로,
        /// 이를 피해야 합니다.
        public let name: String
        
        let fileManager: FileManager
        let directory: URL?

        /// 주어진 파라미터로 설정 값을 생성합니다.
        ///
        /// - Parameters:
        ///   - name: 캐시의 이름. 디스크 스토리지 식별자로 사용됩니다.
        ///   - sizeLimit: 디스크 스토리지의 최대 크기 (바이트 단위)
        ///   - fileManager: 디스크 파일 조작에 사용할 `FileManager`
        ///   - directory: 디스크 스토리지가 위치할 루트 디렉터리 URL
        public init(
            name: String,
            sizeLimit: UInt,
            fileManager: FileManager = .default,
            directory: URL? = nil
        ) {
            self.name = name
            self.fileManager = fileManager
            self.directory = directory
            self.sizeLimit = sizeLimit
        }
    }
}

extension DiskStorage {
    struct FileMeta {
    
        let url: URL
        
        let lastAccessDate: Date?
        let estimatedExpirationDate: Date?
        let isDirectory: Bool
        let fileSize: Int
        
        /// 마지막 접근 날짜를 기준으로 두 파일 메타데이터를 비교합니다.
        ///
        /// 최근에 접근된 파일이 먼저 오도록 정렬할 때 사용됩니다.
        static func lastAccessDate(lhs: FileMeta, rhs: FileMeta) -> Bool {
            return lhs.lastAccessDate ?? .distantPast > rhs.lastAccessDate ?? .distantPast
        }
        
        init(fileURL: URL, resourceKeys: Set<URLResourceKey>) throws {
            let meta = try fileURL.resourceValues(forKeys: resourceKeys)
            self.init(
                fileURL: fileURL,
                lastAccessDate: meta.creationDate,
                estimatedExpirationDate: meta.contentModificationDate,
                isDirectory: meta.isDirectory ?? false,
                fileSize: meta.fileSize ?? 0
            )
        }
        
        init(
            fileURL: URL,
            lastAccessDate: Date?,
            estimatedExpirationDate: Date?,
            isDirectory: Bool,
            fileSize: Int
        ) {
            self.url = fileURL
            self.lastAccessDate = lastAccessDate
            self.estimatedExpirationDate = estimatedExpirationDate
            self.isDirectory = isDirectory
            self.fileSize = fileSize
        }

        /// 기준 날짜를 기준으로 파일이 만료되었는지 여부를 반환합니다.
        ///
        /// 예상 만료 날짜가 기준 날짜보다 과거라면
        /// 해당 파일은 만료된 것으로 판단합니다.
        func expired(referenceDate: Date) -> Bool {
            return estimatedExpirationDate?.isPast(referenceDate: referenceDate) ?? true
        }
        
        /// 접근 이후 만료 연장 정책에 따라
        /// 파일의 만료 시점을 연장합니다.
        ///
        /// 파일의 속성(attribute)을 수정하여
        /// 마지막 접근 시점과 만료 시점을 갱신합니다.
        func extendExpiration(
            with fileManager: FileManager,
            extendingExpiration: ExpirationExtending
        ) {
            guard let lastAccessDate = lastAccessDate,
                  let lastEstimatedExpiration = estimatedExpirationDate
            else {
                return
            }

            let attributes: [FileAttributeKey : Any]

            switch extendingExpiration {
            case .none:
                // 여기서는 만료 시간을 연장하지 않습니다.
                return

            case .cacheTime:
                let originalExpiration: StorageExpiration =
                    .seconds(lastEstimatedExpiration.timeIntervalSince(lastAccessDate))
                attributes = [
                    .creationDate: Date().fileAttributeDate,
                    .modificationDate: originalExpiration.estimatedExpirationSinceNow.fileAttributeDate
                ]

            case .expirationTime(let expirationTime):
                attributes = [
                    .creationDate: Date().fileAttributeDate,
                    .modificationDate: expirationTime.estimatedExpirationSinceNow.fileAttributeDate
                ]
            }

            try? fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}

extension DiskStorage {
    struct Creation {
        let directoryURL: URL
        let cacheName: String

        init(_ config: Config) {
            let url: URL
            if let directory = config.directory {
                url = directory
            } else {
                url = config.fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            }

            cacheName = "com.onevcat.Kingfisher.ImageCache.\(config.name)"
            directoryURL = config.cachePathBlock(url, cacheName)
        }
    }
}

fileprivate extension Error {

    /// 이 에러가 "폴더가 존재하지 않음" 상황인지 여부를 판단합니다.
    ///
    /// 디스크 캐시 디렉터리가 삭제된 경우를 감지하는 데 사용됩니다.
    var isFolderMissing: Bool {
        let nsError = self as NSError
        guard nsError.domain == NSCocoaErrorDomain, nsError.code == 4 else {
            return false
        }
        guard let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        guard underlyingError.domain == NSPOSIXErrorDomain, underlyingError.code == 2 else {
            return false
        }
        return true
    }
}
