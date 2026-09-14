import Foundation
import CoreGraphics

struct PetScreen {
    let frame: CGRect
    let visibleFrame: CGRect
}

enum CaptureCadence {
    static func normalized(_ value:Int)->Int {[10,15,30].contains(value) ? value:10}
    static func rate(preferred:Int,dragging:Bool)->Int {dragging ? 30:normalized(preferred)}
}

struct AdaptiveCaptureCadence {
    private var lastChange:TimeInterval?
    mutating func reset() {lastChange=nil}
    mutating func rate(preferred:Int,dragging:Bool,changed:Bool,now:TimeInterval)->Int {
        if changed || dragging || lastChange==nil {lastChange=now}
        let requested=CaptureCadence.rate(preferred:preferred,dragging:dragging)
        guard requested==10 else{return requested}
        return now-(lastChange ?? now)>=0.75 ? 2:10
    }
}

enum CaptureRegion {
    static func region(for pet: CGRect, on screen: CGRect, retaining current: CGRect? = nil) -> CGRect {
        let required = pet.insetBy(dx: -2, dy: -2).intersection(screen)
        guard !required.isEmpty, !required.isNull else { return screen }
        let guardBand = pet.insetBy(dx: -16, dy: -16).intersection(screen)
        let fresh = pet.insetBy(dx: -64, dy: -64).integral.intersection(screen)
        if let current, screen.contains(current), current.contains(guardBand),
           current.width * current.height <= fresh.width * fresh.height * 1.5 { return current }
        return fresh
    }

    static func sourceRect(_ region: CGRect, on screen: CGRect) -> CGRect {
        CGRect(x: region.minX - screen.minX, y: screen.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    static func globalRect(_ reported: CGRect, on screen: CGRect, displayBounds: CGRect) -> CGRect? {
        guard [reported.minX, reported.minY, reported.width, reported.height].allSatisfy(\.isFinite),
              reported.width > 0, reported.height > 0 else { return nil }
        let converted = CGRect(x: screen.minX + reported.minX - displayBounds.minX,
                               y: screen.maxY - (reported.maxY - displayBounds.minY),
                               width: reported.width, height: reported.height)
        guard screen.insetBy(dx: -1, dy: -1).contains(converted) else { return nil }
        return converted
    }
}

enum PetPlacement {
    static func recoveredOrigin(for pet: CGRect, screens: [PetScreen]) -> CGPoint {
        let center = CGPoint(x: pet.midX, y: pet.midY)
        // Transparent margins may extend offscreen while the black hole stays
        // reachable. Preserve a valid saved origin across Dock/menu changes.
        if screens.contains(where: { $0.frame.contains(center) }) { return pet.origin }

        // A removed or resized display can strand the pet. Recover to the
        // nearest usable edge while leaving a visible drag target.
        var nearest: CGPoint?
        var distance = CGFloat.infinity
        for screen in screens where !screen.frame.isEmpty {
            let visible = screen.visibleFrame.intersection(screen.frame)
            let area = visible.isEmpty ? screen.frame : visible
            let marginX = min(32, area.width / 2)
            let marginY = min(32, area.height / 2)
            let candidate = CGPoint(
                x: min(area.maxX - marginX, max(area.minX + marginX, center.x)),
                y: min(area.maxY - marginY, max(area.minY + marginY, center.y)))
            let delta = hypot(candidate.x - center.x, candidate.y - center.y)
            if delta < distance { nearest = candidate; distance = delta }
        }
        guard let recovered = nearest else { return pet.origin }
        return CGPoint(x: recovered.x - pet.width / 2, y: recovered.y - pet.height / 2)
    }
}

struct RGB: Equatable {
    let r: Double, g: Double, b: Double
    init?(hex: String) {
        var text=hex.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("#") {text.removeFirst()}
        if text.count==3 {text=text.map{String(repeating:String($0),count:2)}.joined()}
        guard text.count==6,text.allSatisfy({$0.isASCII && $0.isHexDigit}),let n=UInt32(text,radix:16) else {return nil}
        r=Double((n>>16)&255)/255;g=Double((n>>8)&255)/255;b=Double(n&255)/255
    }
    var hex:String {String(format:"#%02X%02X%02X",Int((r*255).rounded()),Int((g*255).rounded()),Int((b*255).rounded()))}
}

// A velocity in points/second; bounds constrain the entire transparent pet window.
struct Wander {
    var heading:Double = Double.random(in:0...(2 * .pi))
    var turnIn:Double=4
    var bounceCount=0
    mutating func advance(origin:CGPoint,size:CGSize,screen:CGRect,speed:Double,dt:Double,random:()->Double = {Double.random(in:0...1)})->CGPoint {
        let time=max(0,min(dt,0.1))
        let minX=screen.minX, maxX=max(minX,screen.maxX-size.width)
        let minY=screen.minY, maxY=max(minY,screen.maxY-size.height)
        turnIn -= time
        if turnIn<=0 {heading += (random()-0.5)*0.9;turnIn=3+random()*5}
        var vx=cos(heading),vy=sin(heading)
        var p=CGPoint(x:origin.x+vx*speed*time,y:origin.y+vy*speed*time)
        let hitX=p.x<minX || p.x>maxX, hitY=p.y<minY || p.y>maxY
        if hitX || hitY {
            // Randomize the reflected heading while forcing all collided axes inward.
            if hitX {vx = p.x<minX ? abs(vx):(-abs(vx))}
            if hitY {vy = p.y<minY ? abs(vy):(-abs(vy))}
            let angle=atan2(vy,vx)+(random()-0.5)*1.1
            vx=cos(angle);vy=sin(angle)
            if hitX {vx=(p.x<minX ? 1.0 : -1.0)*max(abs(vx),0.3)}
            if hitY {vy=(p.y<minY ? 1.0 : -1.0)*max(abs(vy),0.3)}
            heading=atan2(vy,vx);bounceCount += 1
            turnIn=2+random()*4
        }
        p.x=min(maxX,max(minX,p.x));p.y=min(maxY,max(minY,p.y))
        return p
    }
}
