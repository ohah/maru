// main run loop에 관측기만 붙인다. 제품 draw·Timer·레이어 속성은 바꾸지 않는다.
@available(macOS 14.0, *)
@MainActor private final class DisplayTiming: NSObject {
    static let shared=DisplayTiming()
    let enabled=ProcessInfo.processInfo.environment["MARU_DISPLAY_TIMING"]=="1"
    var link: CADisplayLink?
    var flat=[UInt64]()
    var context=[UInt64]()
    var started: UInt64=0,ended: UInt64=0,errors: UInt64=0,overflow: UInt64=0,observations: UInt64=0
    static func ns(_ value: Double) -> UInt64 {
        let scaled=value*1e9
        return scaled.isFinite && scaled>0 && scaled<Double(UInt64.max) ? UInt64(scaled) : 0
    }
    func observe(_ view: MaruMetalTerminalView,_ window: NSWindow,_ hz: UInt32) {
        guard ended==0 else { return }
        guard let screen=window.screen,let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let layer=view.metalLayer else { errors+=1;return }
        let current:[UInt64]=[number.uint64Value,UInt64(screen.maximumFramesPerSecond),UInt64(UInt(bitPattern:Unmanaged.passUnretained(layer).toOpaque())),
            layer.displaySyncEnabled ? 1 : 0,layer.presentsWithTransaction ? 1 : 0,UInt64(layer.maximumDrawableCount),UInt64(hz)]
        observations+=1
        if started != 0 { if context != current { errors+=1 };return }
        context=current;started=Self.ns(CACurrentMediaTime())
        flat.reserveCapacity(4096*5)
        if enabled {
            if #available(macOS 14.0, *) {
                link=screen.displayLink(target:self,selector:#selector(sample(_:)))
                link?.add(to:.main,forMode:.common)
            } else { errors+=1 }
        }
    }
    @objc func sample(_ sender: CADisplayLink) {
        let begin=Self.ns(CACurrentMediaTime())
        guard ended==0,enabled,sender===link else { errors+=1;return }
        guard flat.count<4096*5 else { overflow+=1;return }
        let stamp=Self.ns(sender.timestamp),target=Self.ns(sender.targetTimestamp),duration=Self.ns(sender.duration)
        flat.append(contentsOf:[begin,stamp,target,duration,0])
        flat[flat.count-1]=Self.ns(CACurrentMediaTime())
    }
    func finish() -> [String:Any] {
        link?.invalidate();link=nil;ended=Self.ns(CACurrentMediaTime())
        return ["mode":enabled ? "enabled" : "disabled","started":started,"ended":ended,"errors":errors,"overflow":overflow,
            "observations":observations,"context":context,"rows":stride(from:0,to:flat.count,by:5).map { Array(flat[$0..<$0+5]) }]
    }
}
