// 원래 검사의 순서와 단락 평가를 유지한다. untimed 대조도 같은 클로저와 호출 수를 거친다.
@MainActor private enum ObserverWork {
    static let enabled=InputStream.env["MARU_STREAM_OBSERVER_WORK"]=="1"
    static var calls=[UInt64](repeating:0,count:6),cpu=[UInt64](repeating:0,count:6)
    static var events=[[UInt64]](),errors:UInt64=0,depth=0
    static var inputStart=[UInt64](),idleStart=[UInt64](),idleEnd=[UInt64]()
    static func measure<T>(_ part:Int,_ body:() -> T) -> T {
        guard InputStream.phase==2 else { return body() }
        guard (0..<6).contains(part),depth==0 else { errors &+= 1;return body() }
        calls[part] &+= 1
        guard enabled else { return body() }
        depth=1
        let wall=UInt64(CACurrentMediaTime()*1e9),begin=observerThreadCPU()
        defer {
            let end=observerThreadCPU(),wallEnd=UInt64(CACurrentMediaTime()*1e9)
            depth=0
            if begin>0 && end>=begin && wallEnd>wall {
                cpu[part] &+= end-begin
                if events.count<4096 { events.append([UInt64(part),wall,wallEnd,end-begin,calls[part]]) }
                else { errors &+= 1 }
            } else { errors &+= 1 }
        }
        return body()
    }
    static func snapshot() -> [UInt64] {
        [UInt64(CACurrentMediaTime()*1e9),errors,UInt64(events.count)]+(0..<6).flatMap { [calls[$0],cpu[$0]] }
    }
}
