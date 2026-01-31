> 💡
> 
> 디스크 캐시의 동작 정책과 환경을 정의하는 설정 값

```swift
    public struct Config: @unchecked Sendable {
        public var sizeLimit: UInt
        public var expiration: StorageExpiration = .days(7)
        public var pathExtension: String? = nil
        public var usesHashedFileName = true
        public var autoExtAfterHashedFileName = false
        public var cachePathBlock: (@Sendable (_ directory: URL, _ cacheName: String) -> URL)! = {
            (directory, cacheName) in
            return directory.appendingPathComponent(cacheName, isDirectory: true)
        }
        public let name: String
        let fileManager: FileManager
        let directory: URL?

        public init(
            name: String,
            sizeLimit: UInt,
            fileManager: FileManager = .default,
            directory: URL? = nil)
        {
            self.name = name
            self.fileManager = fileManager
            self.directory = directory
            self.sizeLimit = sizeLimit
        }
    }
```

### name

디스크 캐시를 식별하는 고유 이름

### sizeLimit

디스크 캐시의 최대 용량 (bytes)

- 초과 시 LRU 방식으로 정리

### expiration

캐시 만료 정책

- 기본값: 7일
- 접근 시 만료 연장 가능

### usesHashedFileName

캐시 파일 이름을 해시로 저장할지 여부

- 개인정보 보호 (URL 노출 방지)
- 파일 이름 충돌 방지

### cachePathBlock

디스크 캐시 경로를 커스터마이즈하는 1회성 클로저

- 기본: `Caches/com.onevcat.Kingfisher.ImageCache.<name>`
- 테스트 / 특수 환경 대응

## fileManager가 Config에 포함된 이유

정책(expiration, sizeLimit) + 환경(fileManager) 둘 다 “설정”이기 때문에 Config에 포함됨

### 왜 Backend에 직접 안 두었나?

Backend는 **행위(behavior),** Config는 **환경 + 정책** 역할 분리를 명확히 하기 위함
