import Foundation
import CoreGraphics
func expect(_ condition:Bool,_ name:String){if !condition{fatalError(name)}}
expect(RGB(hex:"#8a5cff")!.hex=="#8A5CFF","six digit")
expect(RGB(hex:"abc")!.hex=="#AABBCC","short hex")
expect(RGB(hex:"#GG0011")==nil && RGB(hex:"12345")==nil,"reject invalid")
let screen=CGRect(x:-1600,y:50,width:1600,height:1000)
for angle in stride(from:0.0,to:6.28,by:0.4){
 var w=Wander(heading:angle,turnIn:100)
 var p=CGPoint(x:screen.maxX-440,y:screen.maxY-440)
 for _ in 0..<10000 {p=w.advance(origin:p,size:CGSize(width:440,height:440),screen:screen,speed:180,dt:1.0/30)
 expect(p.x>=screen.minX && p.x<=screen.maxX-440 && p.y>=screen.minY && p.y<=screen.maxY-440,"bounds")}
 expect(w.bounceCount>0,"bounce")
}
var w=Wander(heading:0,turnIn:100)
let p=w.advance(origin:CGPoint(x:0,y:0),size:CGSize(width:100,height:100),screen:CGRect(x:0,y:0,width:1000,height:1000),speed:60,dt:0.1)
expect(abs(p.x-6)<0.0001,"points per second")
var r=Wander(heading:0,turnIn:100)
_ = r.advance(origin:CGPoint(x:900,y:900),size:CGSize(width:100,height:100),screen:CGRect(x:0,y:0,width:1000,height:1000),speed:60,dt:0.1,random:{0.5})
expect(cos(r.heading)<0,"right edge folds inward")
print("PASS: color parsing, 160000 boundary steps, random bounce, negative display origin, speed units")
