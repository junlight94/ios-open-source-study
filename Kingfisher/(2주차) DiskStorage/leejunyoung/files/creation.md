```swift
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
```

## config.directory

디스크 캐시의 “기본 위치(root)”를 직접 지정하는 옵션

- 값이 있으면 **그 디렉토리를 그대로 사용**
- `nil`이면 시스템 기본 캐시 디렉토리 사용

## cachePathBlock

기본 위치 + 캐시 이름을 받아 “최종 캐시 디렉토리 경로”를 만들어주는 클로저

사용자는 서브폴더 구조, 테스트용 경로를 커스텀하게 설정할 수 있음.
