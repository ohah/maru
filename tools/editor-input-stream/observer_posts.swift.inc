// 생산자는 완료 파일을 atomic으로 한 번 게시한다. 재사용해도 대상/포커스 검사는 계속 돈다.
@MainActor private enum ObserverPosts {
    static var checks:UInt64=0,attempts:UInt64=0,reads:UInt64=0,parses:UInt64=0,hits:UInt64=0,cpu:UInt64=0,errors:UInt64=0
    static var accepted:Data?
    static var inputStart=[UInt64](),idleStart=[UInt64](),idleEnd=[UInt64]()
    static func complete(_ path:String,cache:Bool) -> Bool? {
        let begin=observerThreadCPU()
        defer {
            let end=observerThreadCPU()
            if begin>0 && end>=begin { cpu &+= end-begin } else { errors &+= 1 }
        }
        checks &+= 1
        if cache,accepted != nil { hits &+= 1;return true }
        attempts &+= 1
        guard let data=try? Data(contentsOf:URL(fileURLWithPath:path)) else { return nil }
        reads &+= 1
        guard let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { return nil }
        parses &+= 1
        guard value["error"] is NSNull else { return false }
        if let accepted {
            if accepted != data { errors &+= 1;return false }
        } else { accepted=data }
        return true
    }
    static func snapshot() -> [UInt64] {
        [UInt64(CACurrentMediaTime()*1e9),checks,attempts,reads,parses,hits,cpu,errors]
    }
    static func finish(_ path:String?) {
        // 재사용한 완료 증거를 원본과 묶어 같은 이름의 다른 파일로 바뀐 경우를 거절한다.
        guard let path,let accepted,let final=try? Data(contentsOf:URL(fileURLWithPath:path)),final==accepted else { errors &+= 1;return }
    }
}
