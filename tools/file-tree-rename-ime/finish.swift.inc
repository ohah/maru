                case 30:
                    let word=firstSaveCase == "korean" ? "base한" : "base韓"
                    try addressDocument(word)
                    try paletteIMERequire(!view.hasMarkedText() && paletteIMEWitness(1)==1,"selected_or_renamed")
                    paletteIMEState("selected",view:view,window:window)
                    paletteIMEState("filename_ready",view:view,window:window)
                    let project=URL(fileURLWithPath:ProcessInfo.processInfo.environment["MARU_UNTITLED_PROJECT"]!)
                    let source=project.appendingPathComponent("base")
                    let beforeBytes=try Data(contentsOf:source)
                    let attributes=try FileManager.default.attributesOfItem(atPath:source.path)
                    let target=project.appendingPathComponent(word)
                    let targetBytes=try? Data(contentsOf:target)
                    func digest(_ value:Data)->String { SHA256.hash(data:value).map { String(format:"%02x",$0) }.joined() }
                    let record:[String:Any] = ["pid":getpid(),"names":try FileManager.default.contentsOfDirectory(atPath:project.path),
                        "source_sha256":digest(beforeBytes),"inode":attributes[.systemFileNumber]!,
                        "destination_sha256":targetBytes.map { digest($0) } as Any? ?? NSNull()]
                    try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]).write(to:paletteIMERoot.appendingPathComponent("before-commit.json"),options:.atomic)
                    try firstSaveNativeCapture(window.windowNumber,"filename")
                    try paletteIMEHID(firstSaveCase == "cancel" ? 53 : 36,view:view,window:window)
                    PaletteIMERun.step=33; PaletteIMERun.deadline=now+12
                case 33:
                    if paletteIMEWitness(8)>0 { try paletteIMERequire(now<PaletteIMERun.deadline,"mutation_pending");return }
                    let changed=firstSaveCase == "hanja" || firstSaveCase == "korean"
                    let name=changed ? (firstSaveCase == "korean" ? "base한" : "base韓") : "base"
                    if paletteIMEWitness(27) != paletteIMEHash(name) { _=maru_untitled_model(); try paletteIMERequire(now<PaletteIMERun.deadline,"tree_selection");return }
                    try paletteIMERequire(paletteIMEWitness(1)==0 && paletteIMEWitness(30)==1 && paletteIMEWitness(32)==1,"unrelated_document_changed")
                    if firstSaveCase == "collision" || firstSaveCase == "write-failure" { try paletteIMERequire(paletteIMEWitness(37)==1,"missing_failure_notice") }
                    paletteIMEState("settled",view:view,window:window)
                    try paletteIMERequire(maru_untitled_model()==1,"model")
                    try paletteIMECapture("settled",surface:surface)
                    paletteIMEFinish(nil,view:view)
