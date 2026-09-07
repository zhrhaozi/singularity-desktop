import Foundation
import CoreGraphics

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
