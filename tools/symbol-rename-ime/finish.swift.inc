                case 30:
                    let word=firstSaveCase == "korean" ? "base한" : "base韓"
                    try addressDocument(word)
                    try paletteIMERequire(!view.hasMarkedText() && paletteIMEWitness(1)==1 && paletteIMEWitness(40)==0,"candidate_sent_rename")
                    paletteIMEState("selected",view:view,window:window)
                    paletteIMEState("filename_ready",view:view,window:window)
                    try firstSaveNativeCapture(window.windowNumber,"filename")
                    if firstSaveCase == "stale" {
                        try paletteIMERequire(maru_symbol_invalidate()==1,"local_invalidation")
                        paletteIMEState("invalidated",view:view,window:window)
                    }
                    try paletteIMEHID(firstSaveCase == "cancel" ? 53 : 36,view:view,window:window)
                    PaletteIMERun.step=33;PaletteIMERun.deadline=now+15
                case 33:
                    if paletteIMEWitness(8)>0 { try paletteIMERequire(now<PaletteIMERun.deadline,"response_timeout");return }
                    let applied=firstSaveCase == "hanja" || firstSaveCase == "korean"
                    if applied && paletteIMEWitness(41)==0 { try paletteIMERequire(now<PaletteIMERun.deadline,"apply_timeout");return }
                    if firstSaveCase == "server-error" && paletteIMEWitness(42)==0 { try paletteIMERequire(now<PaletteIMERun.deadline,"error_timeout");return }
                    if firstSaveCase == "stale" { try paletteIMERequire(paletteIMEWitness(43)==1 && paletteIMEWitness(40)==0,"stale_sent_request") }
                    if firstSaveCase == "cancel" { try paletteIMERequire(paletteIMEWitness(40)==0,"cancel_sent_request") }
                    try paletteIMERequire(paletteIMEWitness(1)==0,"rename_not_closed")
                    paletteIMEState(applied ? "applied" : "settled",view:view,window:window)
                    try paletteIMERequire(maru_symbol_model(applied ? 0 : 1)==1,"model")
                    try paletteIMECapture(applied ? "applied" : "settled",surface:surface)
                    if applied {
                        try paletteIMERequire(maru_symbol_undo()==1,"workspace_undo")
                        PaletteIMERun.step=34;PaletteIMERun.next=now+0.8
                    } else { paletteIMEFinish(nil,view:view) }
                case 34:
                    try paletteIMERequire(maru_symbol_model(1)==1,"undo_model")
                    paletteIMEState("undone",view:view,window:window)
                    try paletteIMECapture("undone",surface:surface)
                    paletteIMEFinish(nil,view:view)
