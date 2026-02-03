import Foundation

// DiskStorage는 “값을 디스크에 파일로 저장하는 캐시 기능”을 묶어 둔 이름이다.
// Kingfisher는 캐시를 메모리와 디스크 두 단계로 나누는데, 이 파일은 그중 ‘디스크 캐시’만 담당한다.
// enum을 네임스페이스로 사용해서, 디스크 캐시와 관련된 타입들을 하나의 범위 안에서 관리한다.
public enum DiskStorage {

    // Backend는 디스크 캐시의 “실제 동작”을 구현한다.
    // 이 타입은 저장(store), 조회(value), 삭제(remove), 정리(removeExpired/removeSizeExceeded) 같은 기능을 제공한다.
    // Config는 ‘정책(규칙)’이고, Backend는 그 정책을 적용해서 파일 시스템에 반영하는 실행 주체다.
    //
    // T는 디스크에 저장되려면 Data로 변환될 수 있어야 하므로 DataTransformable을 요구한다.
    public final class Backend<T: DataTransformable>: @unchecked Sendable where T: Sendable {

        // config는 만료 기간, 용량 제한, 파일명 규칙처럼 ‘캐시 정책’을 담는다.
        // 이 값은 여러 스레드에서 동시에 읽히거나 변경될 수 있다.
        // 동시에 접근될 때 일부 값만 바뀐 상태로 읽히는 상황(일관성 깨짐)을 피하려고 전용 큐로 접근을 통제한다.
        private let propertyQueue = DispatchQueue(label: "com.onevcat.kingfisher.DiskStorage.Backend.propertyQueue")

        private var _config: Config

        // 외부에서 config를 읽거나 바꿀 때는 항상 propertyQueue를 통해 처리한다.
        // 이렇게 하면 config를 읽는 시점에 항상 ‘하나의 완성된 상태’로 읽게 된다.
        public var config: Config {
            get { propertyQueue.sync { _config } }
            set { propertyQueue.sync { _config = newValue } }
        }

        // directoryURL은 이 DiskStorage가 파일을 저장하는 “캐시 폴더의 경로”다.
        // 캐시 파일은 모두 이 폴더 아래에 생성된다.
        // 생성 시점에 한 번 결정되며, 실행 중간에 바뀌면 기존 캐시 파일을 찾지 못하거나 충돌할 수 있으므로 상수로 둔다.
        public let directoryURL: URL

        // metaChangingQueue는 파일의 ‘속성(날짜 정보 등)’을 변경하는 작업을 순서대로 처리하기 위한 큐다.
        // 조회할 때마다 접근 시각이나 만료 시각을 갱신하는데, 여러 스레드가 동시에 같은 파일의 속성을 바꾸면 순서가 꼬일 수 있다.
        // 그래서 파일 속성 변경만큼은 한 줄로 세워서 실행되도록 별도 큐를 둔다.
        let metaChangingQueue: DispatchQueue

        // maybeCached는 “캐시 폴더에 존재하는 파일 이름 목록”을 메모리에 보관하는 자료구조다.
        // 파일 존재 여부를 확인하기 위해 매번 디스크에 접근하면 비용이 크기 때문에,
        // 먼저 이 목록을 확인해서 ‘애초에 없다고 판단 가능한 경우’를 빠르게 걸러낼 때 사용한다.
        //
        // 단, 이 목록은 항상 최신이라고 보장되지 않는다.
        // 예를 들어, 목록을 만든 뒤에 파일이 삭제되면 목록에는 남아 있어도 실제 디스크에는 없을 수 있다.
        // 따라서 이 목록은 ‘1차 판단’에만 사용하고, 최종 확인은 fileExists로 실제 디스크 상태를 다시 확인한다.
        // O(1) -> contains
        var maybeCached: Set<String>?
        let maybeCachedCheckingQueue = DispatchQueue(label: "com.onevcat.Kingfisher.maybeCachedCheckingQueue")

        // storageReady는 캐시 폴더 준비 과정에서 오류가 발생했는지 기록한다.
        // 폴더 생성에 실패한 상태에서 저장/조회가 계속되면 같은 오류가 반복될 수 있으므로,
        // 한 번 실패한 뒤에는 명확한 에러로 빠르게 실패시키기 위해 플래그로 상태를 보관한다.
        private var storageReady: Bool = true

        // public init(config:)는 ‘캐시 폴더까지 준비된 상태’로 Backend를 만들기 위한 init다.
        // 폴더를 만들 수 없으면 오류를 던져서, 호출자가 초기화 실패를 명확히 알 수 있게 한다.
        public convenience init(config: Config) throws {
            self.init(noThrowConfig: config, creatingDirectory: false)
            try prepareDirectory()
        }

        // noThrowConfig 생성자는 내부에서 쓰는 초기화 프로퍼티다.
        // creatingDirectory가 true이면 폴더 생성까지 시도하고, false이면 폴더 생성은 나중에 하도록 미룬다.
        // 폴더 생성 시점/에러 처리를 호출 흐름에 맞게 선택할 수 있도록 분리되어 있다.
        init(noThrowConfig config: Config, creatingDirectory: Bool) {
            var config = config

            let creation = Creation(config)
            self.directoryURL = creation.directoryURL

            // cachePathBlock은 외부 객체를 캡처해서 강한 참조 순환을 만들 가능성이 있다.
            // directoryURL이 이미 계산된 뒤에는 더 이상 필요하지 않으므로 nil로 바꿔서 잠재적인 참조 문제를 줄인다.
            config.cachePathBlock = nil
            _config = config

            metaChangingQueue = DispatchQueue(label: creation.cacheName)
            setupCacheChecking()

            if creatingDirectory {
                try? prepareDirectory()
            }
        }

        // 캐시 폴더에 들어 있는 파일 이름 목록을 한 번 읽어서 maybeCached를 만든다.
        // 성공하면 이후 조회에서 ‘목록에 없는 파일’을 빠르게 제외할 수 있다.
        // 실패하면 maybeCached를 사용하지 않고, 이후에는 매번 디스크에 직접 파일 존재 여부를 확인하는 방식으로 동작한다.
        private func setupCacheChecking() {
            DispatchQueue.global(qos: .default).async {
                do {
                    let allFiles = try self.config.fileManager.contentsOfDirectory(atPath: self.directoryURL.path)
                    let fileNames = Set(allFiles)
                    self.maybeCachedCheckingQueue.async {
                        self.maybeCached = fileNames
                    }
                } catch {
                    self.maybeCachedCheckingQueue.async {
                        self.maybeCached = nil
                    }
                }
            }
        }

        // 캐시 폴더를 만든다.
        // 이미 폴더가 있으면 아무 작업도 하지 않는다.
        // 폴더 생성에 실패하면 storageReady를 false로 두고, 이후 작업은 ‘준비 실패’ 에러로 처리되게 한다.
        private func prepareDirectory() throws {
            let fileManager = config.fileManager
            let path = directoryURL.path

            guard !fileManager.fileExists(atPath: path) else { return }

            do {
                try fileManager.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                self.storageReady = false
                throw KingfisherError.cacheError(reason: .cannotCreateDirectory(path: path, error: error))
            }
        }

        // store는 값을 디스크에 파일로 저장한다.
        // 과정:
        // 1) 디스크 스토리지가 준비된 상태인지 확인한다.
        // 2) 만료 정책을 결정한다(호출 인자 우선, 없으면 config 기본값).
        // 3) 값을 Data로 변환한다.
        // 4) 키로부터 파일 경로를 계산한다.
        // 5) Data를 파일로 기록한다.
        // 6) 파일의 속성에 ‘접근 시각’과 ‘만료 시각’을 기록한다(이 정보로 만료/정리 판단을 한다).
        // 7) maybeCached가 있다면 파일 이름을 목록에 추가한다.
        public func store(
            value: T,
            forKey key: String,
            expiration: StorageExpiration? = nil,
            writeOptions: Data.WritingOptions = [],
            forcedExtension: String? = nil
        ) throws {
            guard storageReady else {
                throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
            }

            let expiration = expiration ?? config.expiration
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
                    // 저장 시점에 캐시 폴더가 삭제된 경우에는 폴더를 다시 만든 다음 한 번 더 시도한다.
                    // 이 경우는 ‘복구 가능한 실패’이므로 재시도가 의미가 있다.
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

            // DiskStorage는 별도의 DB를 두지 않고, 파일 속성에 ‘접근 시각’과 ‘만료 시각’을 기록한다.
            // 이렇게 하면 폴더를 스캔하는 것만으로 만료/정리 판단이 가능하고, 메타데이터 동기화 비용도 줄어든다.
            let now = Date()
            let attributes: [FileAttributeKey: Any] = [
                // 접근 시각(이 구현에서는 마지막 접근 시각으로 활용한다)
                .creationDate: now.fileAttributeDate,
                // 만료 시각(예상 만료 날짜를 기록한다)
                .modificationDate: expiration.estimatedExpirationSinceNow.fileAttributeDate
            ]

            do {
                try config.fileManager.setAttributes(attributes, ofItemAtPath: fileURL.path)
            } catch {
                // 메타 기록에 실패하면 파일이 ‘불완전한 상태’로 남을 수 있으니, 저장한 파일 자체를 제거한다.
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

        // value는 주어진 키에 해당하는 값을 디스크에서 읽어온다.
        // 과정:
        // 1) 디스크 스토리지가 준비된 상태인지 확인한다.
        // 2) maybeCached가 있으면 목록에서 먼저 확인한다(목록에 없으면 실제로 없을 가능성이 높다).
        // 3) 최종적으로 fileExists로 실제 디스크에 파일이 있는지 확인한다.
        // 4) 파일 속성을 읽어서 만료 여부를 판단한다.
        // 5) 만료되지 않았고 실제 로드가 필요하면 Data를 읽고 T로 변환한다.
        // 6) 조회 후에는 정책에 따라 만료 시각을 갱신한다(파일 속성 변경은 metaChangingQueue에서 순서대로 처리한다).
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

        func value(
            forKey key: String,
            referenceDate: Date,
            actuallyLoad: Bool,
            extendingExpiration: ExpirationExtending,
            forcedExtension: String?
        ) throws -> T? {
            guard storageReady else {
                throw KingfisherError.cacheError(reason: .diskStorageIsNotReady(cacheURL: directoryURL))
            }

            let fileManager = config.fileManager
            let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
            let filePath = fileURL.path

            // maybeCached가 존재하면, 파일 이름 목록으로 1차 판단을 한다.
            // 목록에 없으면 ‘없을 가능성이 높다’고 보고 바로 nil을 반환한다.
            // 다만 목록은 항상 최신이 아니므로, 목록에서 통과한 경우에도 실제 파일 존재는 fileExists로 다시 확인한다.
            let fileMaybeCached = maybeCachedCheckingQueue.sync {
                return maybeCached?.contains(fileURL.lastPathComponent) ?? true // O(1)
            }
            guard fileMaybeCached else { return nil }
            guard fileManager.fileExists(atPath: filePath) else { return nil }

            let meta: FileMeta
            do {
                let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
                meta = try FileMeta(fileURL: fileURL, resourceKeys: resourceKeys)
            } catch {
                throw KingfisherError.cacheError(
                    reason: .invalidURLResource(error: error, key: key, url: fileURL)
                )
            }

            if meta.expired(referenceDate: referenceDate) { return nil }
            if !actuallyLoad { return T.empty }

            do {
                let data = try Data(contentsOf: fileURL)
                let obj = try T.fromData(data)

                // 조회 후 ‘접근 시각/만료 시각 갱신’은 부가 작업이다.
                // 호출자는 값을 빠르게 받고 싶기 때문에, 이 작업은 비동기로 보내서 응답을 지연시키지 않는다.
                metaChangingQueue.async {
                    meta.extendExpiration(with: self.config.fileManager, extendingExpiration: extendingExpiration)
                }
                return obj
            } catch {
                throw KingfisherError.cacheError(reason: .cannotLoadDataFromDisk(url: fileURL, error: error))
            }
        }

        // isCached는 실제 데이터를 읽지 않고, “파일이 존재하며 만료되지 않았는지”만 확인한다.
        // Data를 디스크에서 읽는 작업은 비용이 크기 때문에, 존재/만료 여부만 확인하면 더 빠르게 판단할 수 있다.
        public func isCached(forKey key: String, forcedExtension: String? = nil) -> Bool {
            return isCached(forKey: key, referenceDate: Date(), forcedExtension: forcedExtension)
        }

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

        // remove는 특정 키에 해당하는 파일을 삭제한다.
        public func remove(forKey key: String, forcedExtension: String? = nil) throws {
            let fileURL = cacheFileURL(forKey: key, forcedExtension: forcedExtension)
            try removeFile(at: fileURL)
        }

        // removeFile은 지정된 URL의 파일을 삭제한다.
        func removeFile(at url: URL) throws {
            try config.fileManager.removeItem(at: url)
        }

        // removeAll은 캐시 폴더 자체를 삭제한다.
        // 필요하면 삭제 후 다시 폴더를 생성해서, 이후 저장이 정상 동작하도록 한다.
        public func removeAll() throws {
            try removeAll(skipCreatingDirectory: false)
        }

        func removeAll(skipCreatingDirectory: Bool) throws {
            try config.fileManager.removeItem(at: directoryURL)
            if !skipCreatingDirectory {
                try prepareDirectory()
            }
        }

        // cacheFileURL은 “키가 저장될 파일의 위치”를 계산한다.
        // 실제로 파일이 존재하는지까지 보장하는 메서드는 아니며, 존재한다면 이 위치여야 한다는 의미다.
        public func cacheFileURL(forKey key: String, forcedExtension: String? = nil) -> URL {
            let fileName = cacheFileName(forKey: key, forcedExtension: forcedExtension)
            return directoryURL.appendingPathComponent(fileName, isDirectory: false)
        }

        // cacheFileName은 키로부터 파일 이름을 만든다.
        // usesHashedFileName이 true이면 키를 해시해서 파일명으로 사용한다.
        // 이렇게 하면 원본 URL 같은 민감한 정보가 파일명에 노출되는 것을 줄이고, 파일명으로 쓰기 안전해진다.
        func cacheFileName(forKey key: String, forcedExtension: String? = nil) -> String {
            let baseName = config.usesHashedFileName ? key.kf.sha256 : key

            if let ext = fileExtension(key: key, forcedExtension: forcedExtension) {
                return "\(baseName).\(ext)"
            }

            return baseName
        }

        // fileExtension은 파일 확장자를 결정한다.
        // forcedExtension이 있으면 그 값을 우선 사용한다.
        // 없으면 config.pathExtension을 사용한다.
        // 해시 파일명을 쓰고(autoExtAfterHashedFileName이 true) 원본 키에서 확장자를 추출하도록 설정된 경우,
        // 키에서 확장자를 뽑아 사용한다.
        func fileExtension(key: String, forcedExtension: String?) -> String? {
            if let ext = forcedExtension ?? config.pathExtension {
                return ext
            }

            if config.usesHashedFileName && config.autoExtAfterHashedFileName {
                return key.kf.ext
            }

            return nil
        }

        // allFileURLs는 캐시 폴더 안의 모든 파일 URL을 나열한다.
        // 만료 정리나 용량 정리는 전체 파일을 살펴봐야 판단할 수 있으므로, 이 메서드가 기반이 된다.
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

        // removeExpiredValues는 만료된 파일을 찾아 삭제한다.
        // 파일 속성에 기록된 만료 시각을 기준으로 판단한다.
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
                    if meta.isDirectory { return false }
                    return meta.expired(referenceDate: referenceDate)
                } catch {
                    // 메타 정보를 읽을 수 없으면 파일이 깨졌거나 상태가 비정상일 수 있다.
                    // 이 구현은 그런 파일을 남겨 두기보다 정리 대상으로 간주한다.
                    return true
                }
            }

            try expiredFiles.forEach { url in
                try removeFile(at: url)
            }
            return expiredFiles
        }

        // removeSizeExceededValues는 캐시 폴더의 전체 크기가 sizeLimit를 넘었을 때 파일을 지워서 크기를 줄인다.
        // 어떤 파일부터 지울지는 ‘최근 사용 여부’를 기준으로 한다.
        // 최근 사용한 파일은 남기고, 오래 사용하지 않은 파일부터 삭제한다.
        // 한 번 정리할 때 sizeLimit/2까지 줄여서, 정리가 너무 자주 반복되지 않도록 여유를 둔다.
        public func removeSizeExceededValues() throws -> [URL] {
            if config.sizeLimit == 0 { return [] }

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

            // 최근에 접근한 파일이 앞쪽에 오도록 정렬한다.
            pendings.sort(by: FileMeta.lastAccessDate)

            var removed: [URL] = []
            let target = config.sizeLimit / 2

            // 가장 오래 사용하지 않은 파일부터 하나씩 제거하면서 목표 크기까지 줄인다.
            while size > target, let meta = pendings.popLast() {
                size -= UInt(meta.fileSize)
                try removeFile(at: meta.url)
                removed.append(meta.url)
            }
            return removed
        }

        // totalSize는 캐시 폴더 전체 파일 크기의 합을 계산한다.
        // 용량 제한 정책을 적용하려면 현재 전체 크기를 알아야 하므로 별도 메서드로 제공한다.
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

    // Config는 DiskStorage의 동작 규칙을 담는 설정 값이다.
    // 디스크 캐시는 앱마다 요구가 달라질 수 있으므로(용량, 만료, 확장자, 경로 등) 설정을 분리해 둔다.
    public struct Config: @unchecked Sendable {

        // sizeLimit는 캐시 폴더의 전체 크기 제한이다.
        // 0이면 제한을 두지 않는다.
        public var sizeLimit: UInt

        // expiration은 파일의 만료 정책이다.
        // 기본값은 7일이며, 접근이 없으면 만료로 판단되도록 설계되어 있다.
        public var expiration: StorageExpiration = .days(7)

        // pathExtension은 캐시 파일에 붙일 기본 확장자다.
        public var pathExtension: String? = nil

        // usesHashedFileName이 true이면 키를 해시해서 파일명을 만든다.
        // 파일명에 원본 URL 같은 값이 노출되는 것을 줄이고, 파일명으로 쓰기 어려운 문자를 피할 수 있다.
        public var usesHashedFileName = true

        // autoExtAfterHashedFileName이 true이면 해시 파일명 뒤에 원본 키에서 확장자를 추출해 붙일 수 있다.
        public var autoExtAfterHashedFileName = false

        // cachePathBlock은 캐시 폴더 경로를 커스터마이징하기 위한 클로저다.
        // 예를 들어, 앱 그룹 컨테이너 등 특정 위치에 캐시를 두고 싶을 때 사용할 수 있다.
        public var cachePathBlock: (@Sendable (_ directory: URL, _ cacheName: String) -> URL)! = {
            (directory, cacheName) in
            return directory.appendingPathComponent(cacheName, isDirectory: true)
        }

        // name은 캐시 폴더를 구분하는 식별자다.
        // 같은 name을 쓰면 같은 폴더를 공유하게 된다.
        // 서로 다른 설정을 가진 캐시가 같은 폴더를 쓰면 파일을 잘못 지우거나 잘못 인식할 수 있으므로,
        // 일반적으로는 name이 겹치지 않게 구성해야 한다.
        public let name: String

        let fileManager: FileManager
        let directory: URL?

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

    // FileMeta는 파일의 속성에서 필요한 정보만 읽어 “캐시 판단에 필요한 메타데이터”로 만든 구조체다.
    // DiskStorage는 별도의 DB를 두지 않고 파일 속성을 기준으로 만료/정리 판단을 하므로,
    // 그 판단에 필요한 값들을 이 타입이 모아서 제공한다.
    struct FileMeta {

        let url: URL

        // lastAccessDate는 이 구현에서 ‘마지막 접근 시각’처럼 활용한다.
        // (조회 시 creationDate를 갱신하는 방식으로 최근 사용 여부를 기록한다.)
        let lastAccessDate: Date?

        // estimatedExpirationDate는 파일 속성에 기록된 ‘예상 만료 시각’이다.
        let estimatedExpirationDate: Date?

        let isDirectory: Bool
        let fileSize: Int

        // lastAccessDate가 더 최근인 파일이 앞으로 오도록 정렬할 때 사용한다.
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

        // 기준 날짜(referenceDate)를 기준으로 만료 여부를 판단한다.
        // 만료 시각이 기준 날짜보다 과거이면 만료로 본다.
        func expired(referenceDate: Date) -> Bool {
            return estimatedExpirationDate?.isPast(referenceDate: referenceDate) ?? true
        }

        // extendExpiration은 조회 이후 만료 시각을 갱신한다.
        // extendingExpiration 정책에 따라, “원래 만료 간격을 유지”하거나 “새 만료 정책으로 재설정”한다.
        // 이 구현은 파일 속성(creationDate/modificationDate)을 수정해서 접근/만료 정보를 저장한다.
        // creationDate - 마지막 접근 시각
        // modificationDate -  만료 시각
        func extendExpiration(with fileManager: FileManager, extendingExpiration: ExpirationExtending) {
            guard let lastAccessDate = lastAccessDate,
                  let lastEstimatedExpiration = estimatedExpirationDate
            else {
                return
            }

            let attributes: [FileAttributeKey: Any]

            switch extendingExpiration {
            case .none:
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

    // Creation은 “캐시 폴더의 최종 경로”를 계산하는 역할만 담당한다.
    // Backend 초기화에서 경로 계산 로직을 분리해서, 책임을 명확히 하고 코드를 읽기 쉽게 만든다.
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

    // isFolderMissing는 “파일 쓰기가 실패한 이유가 캐시 폴더 자체가 없기 때문인지”를 판별한다.
    // 폴더가 삭제된 경우는 폴더를 다시 만든 뒤 재시도하면 복구가 가능하다.
    // 반면 권한 문제나 디스크 용량 부족 같은 경우는 재시도로 해결되지 않으므로, 이 구분이 필요하다.
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
