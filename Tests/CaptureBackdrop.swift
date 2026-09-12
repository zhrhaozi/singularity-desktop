import Cocoa

// A separate process so the capture-under-test does not exclude its generated pixels.
final class BackdropView:NSView {
    var phase=0
    override func draw(_ dirtyRect:NSRect) {
        for y in stride(from:0,to:Int(bounds.height),by:48) {
            for x in stride(from:0,to:Int(bounds.width),by:48) {
                let alternate=(x/48+y/48+phase)%2 == 0
                (alternate ? NSColor.systemCyan:NSColor.systemRed).setFill()
                NSRect(x:x,y:y,width:48,height:48).fill()
            }
        }
    }
}

let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let parent=getppid()
var windows=[NSWindow]()
for screen in NSScreen.screens {
    let window=NSWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
    window.level=NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue-1)
    window.ignoresMouseEvents=true
    window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
    window.contentView=BackdropView(frame:NSRect(origin:.zero,size:screen.frame.size))
    window.orderFrontRegardless()
    windows.append(window)
}
let timer=Timer.scheduledTimer(withTimeInterval:0.4,repeats:true){_ in
    guard getppid()==parent else{exit(0)}
    for window in windows {
        let view=window.contentView as! BackdropView
        view.phase+=1;view.needsDisplay=true
    }
}
app.run()
