## **convenience** **init**

<aside>
💡

호출자가 에러를 처리할 수 있는 경우에 사용

</aside>

안전한 생성 경로(noThrowConfig)로 객체를 먼저 초기화한 뒤,

그 다음 단계에서 prepareDirectory()를 호출하고,

이때 디렉토리 생성에 실패하면 throw가 발생할 수 있다.

```swift
public convenience init(config: Config) throws {
    self.init(noThrowConfig: config, creatingDirectory: false)
    try prepareDirectory()
}
```

---

## init

<aside>
💡

앱을 죽이지 않기 위한 안전한 생성 경로

</aside>

내부 전용의 throw 하지 않는 생성자를 통해 객체는 항상 생성되고, 디렉토리 생성은 `try?`로 best-effort로 시도한다.

이 과정에서 실패하더라도 에러는 삼켜지며, `storageReady`를 `false`로 표시해 두었다가 실제 `store` / `value` 호출 시점에 런타임에서 사용 가능 여부를 판단한다.

그래서 초기화 단계에서는 앱이 죽지 않고, 사용 단계에서는 명확하게 실패를 알릴 수 있어 안전하다.

```swift
init(noThrowConfig config: Config, creatingDirectory: Bool) {
    var config = config

    let creation = Creation(config)
    self.directoryURL = creation.directoryURL

    // Break any possible retain cycle set by outside.
    config.cachePathBlock = nil
    _config = config

    metaChangingQueue = DispatchQueue(label: creation.cacheName)
    setupCacheChecking()

    if creatingDirectory {
        try? prepareDirectory()
    }
}
```

### creatingDirectory

`creatingDirectory`가 `false`면 생성자 안에서는 디렉토리를 만들지 않고, 객체 생성이 끝난 뒤에 prepareDirectory()를 직접 호출해야 합니다.

그래서 convenience init에 이 init을 호출하고 prepareDirectory를 통해서 디렉토리를 생성하고 있습니다.

### cachePathBlock

디스크 캐시 경로를 계산하기 위한 “초기화용 1회성 클로저”이며, 계산이 끝난 뒤에는 외부 객체를 불필요하게 붙잡지 않도록 즉시 `nil`로 만들어 참조를 끊는다.

### metaChangingQueue

큐를 캐시 이름으로 지정한 이유는 **디버깅 + 동시성 분리 목적이다.**

디버깅 환경에서 어떤 캐시의 작업인지 식별하기 위함.

동시에 서로 다른 DiskStorage 인스턴스들이 메타데이터 갱신 작업에서 서로 블록킹하지 않도록 분리하기 위한 설계
