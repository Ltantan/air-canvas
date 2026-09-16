import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Original vector mark; no third-party assets or fonts.
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colorspace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorSpace: colorspace, colorComponents: [0.025,0.04,0.09,1, 0.09,0.14,0.24,1], locations: [0,1], count: 2)!
ctx.drawLinearGradient(gradient, start: CGPoint(x:0,y:0), end: CGPoint(x:1024,y:1024), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
let colors: [[CGFloat]] = [[0.18,0.85,0.97,1], [1,0.32,0.57,1], [1,0.8,0.25,1]]
ctx.setLineWidth(36); ctx.setLineCap(.round); ctx.setLineJoin(.round)
for i in 0..<3 {
    let shift = CGFloat(i) * 85
    ctx.beginPath()
    ctx.move(to: CGPoint(x:236+shift,y:260))
    ctx.addCurve(to: CGPoint(x:520+shift,y:740), control1: CGPoint(x:40+shift,y:640), control2: CGPoint(x:725+shift,y:875))
    ctx.addCurve(to: CGPoint(x:355+shift,y:335), control1: CGPoint(x:340+shift,y:620), control2: CGPoint(x:610+shift,y:270))
    ctx.setStrokeColor(CGColor(red: colors[i][0], green: colors[i][1], blue: colors[i][2], alpha: 1)); ctx.strokePath()
}
ctx.setFillColor([1,1,1,1]); ctx.fillEllipse(in: CGRect(x:504,y:309,width:54,height:54))
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
