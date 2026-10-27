                case 30:
                    let word=firstSaveCase == "korean" ? "한" : "韓"
                    try addressDocument(word)
                    try paletteIMERequire(!view.hasMarkedText() && paletteIMEWitness(1)==1,"selected_or_saved")
                    paletteIMEState("selected",view:view,window:window)
                    paletteIMEState("filename_ready",view:view,window:window)
                    try firstSaveNativeCapture(window.windowNumber,"filename")
                    try paletteIMEHID(firstSaveCase == "cancel" ? 53 : 36,view:view,window:window)
                    PaletteIMERun.step=31; PaletteIMERun.next=now+0.6
                case 31:
                    try paletteIMERequire(paletteIMEWitness(1)==0,"rename_not_closed")
                    if firstSaveCase == "overwrite" || firstSaveCase == "reject" {
                        try paletteIMERequire(paletteIMEWitness(33)==1 && paletteIMEWitness(30)==1 && paletteIMEWitness(8)==0,"missing_overwrite")
                        paletteIMEState("overwrite_prompt",view:view,window:window)
                        try firstSaveNativeCapture(window.windowNumber,"overwrite")
                        try paletteIMEHID(firstSaveCase == "reject" ? 53 : 36,view:view,window:window)
                    }
                    PaletteIMERun.step=33; PaletteIMERun.deadline=now+10
                case 33:
                    if paletteIMEWitness(8)>0 { try paletteIMERequire(now<PaletteIMERun.deadline,"pending_save");return }
                    let saved=["hanja","korean","overwrite"].contains(firstSaveCase)
                    try paletteIMERequire(paletteIMEWitness(30)==(saved ? 0 : 1) && paletteIMEWitness(32)==(saved ? 0 : 1),"save_state")
                    if firstSaveCase == "write-failure" { try paletteIMERequire(paletteIMEWitness(37)==1,"missing_failure_notice") }
                    paletteIMEState("settled",view:view,window:window)
                    try paletteIMERequire(maru_untitled_model()==1,"history_or_model")
                    try paletteIMECapture("settled",surface:surface)
                    paletteIMEFinish(nil,view:view)
