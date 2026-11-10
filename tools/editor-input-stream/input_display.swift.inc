// 진단 사본에서만 입력 handler와 관측 handler를 잰다. 제품 예약·검사 순서는 바꾸지 않는다.
@_silgen_name("maru_input_display_cpu") private func inputDisplayCPU() -> UInt64
@_silgen_name("maru_input_display_thread") private func inputDisplayThread() -> UInt64
@_silgen_name("maru_input_display_draws") private func inputDisplayDraws(_ header: UnsafeMutablePointer<UInt64>,_ rows: UnsafeMutablePointer<UInt64>)
@MainActor private enum InputDisplay {
    struct Ticket { let kind:Int,token:UInt64,wall:UInt64,cpu:UInt64,thread:UInt64 }
    static let timed=InputStream.env["MARU_INPUT_DISPLAY_TIMED"]=="1"
    static var started=[UInt64](repeating:0,count:2),completed=[UInt64](repeating:0,count:2)
    static var events=[[UInt64]](),errors:UInt64=0,finishBegin:UInt64=0
    static func begin(_ kind:Int,_ token:UInt64=0) -> Ticket? {
        guard InputStream.phase==2 else { return nil }
        if kind==1 && (token<=0x4D41525500000000 || token>0x4D41525500000024) { return nil }
        started[kind] &+= 1
        guard timed else { return Ticket(kind:kind,token:token,wall:0,cpu:0,thread:0) }
        let wall=UInt64(CACurrentMediaTime()*1e9),cpu=inputDisplayCPU(),thread=inputDisplayThread()
        if kind==0 { finishBegin=wall }
        return Ticket(kind:kind,token:token,wall:wall,cpu:cpu,thread:thread)
    }
    static func end(_ ticket:Ticket?) {
        guard let ticket else { return }
        completed[ticket.kind] &+= 1
        guard timed else { return }
        let cpu=inputDisplayCPU(),wall=UInt64(CACurrentMediaTime()*1e9)
        guard ticket.cpu>0,cpu>=ticket.cpu,wall>ticket.wall,ticket.thread>0,wall-ticket.wall>=cpu-ticket.cpu,events.count<4096 else { errors &+= 1;return }
        events.append([UInt64(ticket.kind),ticket.token,ticket.wall,wall,cpu-ticket.cpu,ticket.thread])
    }
}
